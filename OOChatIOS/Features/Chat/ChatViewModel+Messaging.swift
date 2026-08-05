import Foundation
import SwiftUI
import UIKit

extension ChatViewModel {
    func connectToAgent() async -> AgentConnection? {
        let address = agentAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HostedAgentClient.isHostedAgentAddress(address) else {
            let message = "That doesn't look like an agent address. It should start with 0x followed by 64 characters."
            errorMessage = message
            return nil
        }
        guard !isOffline else {
            let message = "You appear to be offline. Check your connection and try again."
            errorMessage = message
            return nil
        }
        guard !isConnecting else {
            return nil
        }

        isConnecting = true
        errorMessage = nil

        let agent: AgentConnection
        if let activeAgent, activeAgent.address == address {
            agent = activeAgent
        } else {
            agent = agents.first { $0.address == address } ?? AgentConnection(address: address)
        }
        var conversation = conversations(for: agent).first ?? Conversation(agentID: agent.id, agentAddress: address)
        recoveryCoordinator.setConnectionState(.reconnecting, forConversationID: conversation.id)

        do {
            let result = try await client.connect(agentAddress: address, conversation: conversation)
            if let session = result.serverSession {
                conversation.mode = HostedAgentSessionState.mode(from: session, fallback: conversation.mode)
                conversation.serverSession = HostedAgentSessionState.applying(
                    conversation.mode,
                    to: session,
                    conversationID: conversation.id
                )
            }
            let savedAgent = upsertAgent(agent)
            ensureDefaultConversation(for: savedAgent, seed: conversation)
            skillCoordinator.loadSkillsIfNeeded(for: savedAgent, isOffline: isOffline)
            recoveryCoordinator.setConnectionState(.connected, forConversationID: conversation.id)
            isConnecting = false
            return savedAgent
        } catch {
            handleConnectionFailure(error, conversation: conversation)
            return nil
        }
    }

    private func handleConnectionFailure(_ error: Error, conversation: Conversation) {
        let message = error.localizedDescription
        // `conversation` may be a candidate that was never persisted, so drop its state
        // entry entirely rather than leaving a `.disconnected` row behind forever.
        if conversationState.conversation(withID: conversation.id) == nil {
            recoveryCoordinator.removeConnectionState(forConversationID: conversation.id)
        } else {
            recoveryCoordinator.setConnectionState(.disconnected, forConversationID: conversation.id)
        }
        errorMessage = message
        isConnecting = false
    }

    func sendPrompt() {
        stopVoiceInput()
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        let files = pendingFiles
        guard !text.isEmpty || !images.isEmpty || !files.isEmpty else {
            return
        }
        deliveryCoordinator.setDeliveryEnabled(!isOffline)
        switch deliveryCoordinator.enqueuePrompt(text, images: images, files: files) {
        case .queued:
            prompt = ""
            pendingImages = []
            pendingFiles = []
            errorMessage = nil
        case .rejected(let message):
            errorMessage = message
        }
    }

    func toggleVoiceInput() {
        if voiceInputController.isActive {
            stopVoiceInput()
            return
        }
        guard let conversationID = activeConversationID else {
            errorMessage = "Start a conversation before using voice input."
            return
        }

        errorMessage = nil
        voiceInputController.start(
            promptPrefix: prompt,
            conversationID: conversationID,
            transcriptHandler: { [weak self] targetConversationID, text in
                guard self?.activeConversationID == targetConversationID else {
                    return
                }
                self?.prompt = text
            },
            failureHandler: { [weak self] targetConversationID, message in
                guard self?.activeConversationID == targetConversationID else {
                    return
                }
                self?.errorMessage = message
            }
        )
    }

    func stopVoiceInput() {
        voiceInputController.stop()
    }

    func retryMessage(_ message: ChatMessage) {
        deliveryCoordinator.setDeliveryEnabled(!isOffline)
        if deliveryCoordinator.retryMessage(message) {
            errorMessage = nil
        }
    }

    @discardableResult
    func addPendingImage(
        data: Data,
        mimeType: String,
        to conversationID: String? = nil
    ) -> Bool {
        guard let targetConversationID = conversationID ?? activeConversationID,
              conversation(withID: targetConversationID) != nil else {
            errorMessage = "Start a conversation before adding a photo."
            return false
        }
        var images = targetConversationID == activeConversationID
            ? pendingImages
            : imageDraftsByConversationID[targetConversationID] ?? []
        guard images.count < ChatImageAttachment.maximumCount else {
            errorMessage = "You can attach up to \(ChatImageAttachment.maximumCount) photos."
            return false
        }
        guard !data.isEmpty else {
            errorMessage = "That photo could not be loaded."
            return false
        }
        guard data.count <= ChatImageAttachment.maximumByteCount else {
            errorMessage = "That photo is larger than 10 MB."
            return false
        }
        let normalizedMimeType = mimeType.lowercased()
        guard normalizedMimeType.hasPrefix("image/") else {
            errorMessage = "The selected item is not an image."
            return false
        }

        images.append(
            ChatImageAttachment(data: data, mimeType: normalizedMimeType)
        )
        if targetConversationID == activeConversationID {
            pendingImages = images
        } else {
            imageDraftsByConversationID[targetConversationID] = images
        }
        errorMessage = nil
        return true
    }

    func removePendingImage(id: String) {
        pendingImages.removeAll { $0.id == id }
    }

    func reportImageImportFailure(_ error: Error) {
        errorMessage = "Couldn’t load that photo. \(error.localizedDescription)"
    }

    @discardableResult
    func addPendingFile(
        name: String,
        data: Data,
        mimeType: String,
        to conversationID: String? = nil
    ) -> Bool {
        guard let targetConversationID = conversationID ?? activeConversationID,
              conversation(withID: targetConversationID) != nil else {
            errorMessage = "Start a conversation before adding a file."
            return false
        }
        var files = targetConversationID == activeConversationID
            ? pendingFiles
            : fileDraftsByConversationID[targetConversationID] ?? []
        guard files.count < ChatFileAttachment.maximumCount else {
            errorMessage = "You can attach up to \(ChatFileAttachment.maximumCount) files."
            return false
        }
        guard !data.isEmpty else {
            errorMessage = "That file is empty or could not be loaded."
            return false
        }
        guard data.count <= ChatFileAttachment.maximumByteCount else {
            errorMessage = "That file is larger than 10 MB."
            return false
        }
        let safeName = URL(fileURLWithPath: name).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeName.isEmpty else {
            errorMessage = "That file has no valid name."
            return false
        }

        files.append(
            ChatFileAttachment(
                name: safeName,
                data: data,
                mimeType: mimeType.isEmpty ? "application/octet-stream" : mimeType.lowercased()
            )
        )
        if targetConversationID == activeConversationID {
            pendingFiles = files
        } else {
            fileDraftsByConversationID[targetConversationID] = files
        }
        errorMessage = nil
        return true
    }

    func removePendingFile(id: String) {
        pendingFiles.removeAll { $0.id == id }
    }

    func reportFileImportFailure(_ error: Error) {
        errorMessage = "Couldn’t load that file. \(error.localizedDescription)"
    }

    func flushQueuedMessages() async {
        deliveryCoordinator.setDeliveryEnabled(!isOffline)
        await deliveryCoordinator.flushQueuedMessages()
    }

    func stopActiveResponse() {
        deliveryCoordinator.stopActiveResponse()
    }

    func allowPendingApprovalOnce(id: String) {
        resolvePendingApproval(id: id, with: .allowOnce)
    }

    func trustPendingApprovalForSession(id: String) {
        resolvePendingApproval(id: id, with: .allowSession)
    }

    func skipPendingApproval(id: String) {
        resolvePendingApproval(id: id, with: .rejectSoft(feedback: nil))
    }

    func stopPendingApproval(id: String) {
        resolvePendingApproval(id: id, with: .rejectHard(feedback: nil))
    }

    func explainPendingApproval(id: String) {
        resolvePendingApproval(id: id, with: .rejectExplain(feedback: nil))
    }

    func continueUlw(id: String, turns: Int = 100) {
        resolvePendingUlwCheckpoint(id: id, with: .continueWork(turns: turns))
    }

    func switchModeFromUlwCheckpoint(id: String, to mode: ChatMode) {
        guard activePendingUlwCheckpoint?.id == id else {
            return
        }
        setMode(mode)
        resolvePendingUlwCheckpoint(id: id, with: .switchMode(mode))
    }

    func approvePendingPlan(id: String) {
        resolvePendingPlanReview(id: id, with: .approve)
    }

    func requestPlanChanges(id: String, feedback: String?) {
        resolvePendingPlanReview(id: id, with: .requestChanges(feedback: feedback))
    }

    func answerPendingAskUser(id: String, answer: String) {
        interactionCoordinator.resolve(
            id: id,
            conversationID: activeConversationID,
            with: .askUser(.answer(answer))
        )
    }

    private func resolvePendingApproval(id: String, with decision: ApprovalDecision) {
        interactionCoordinator.resolve(
            id: id,
            conversationID: activeConversationID,
            with: .approval(decision)
        )
    }

    private func resolvePendingUlwCheckpoint(id: String, with decision: UlwCheckpointDecision) {
        interactionCoordinator.resolve(
            id: id,
            conversationID: activeConversationID,
            with: .ulwCheckpoint(decision)
        )
    }

    private func resolvePendingPlanReview(id: String, with decision: PlanReviewDecision) {
        interactionCoordinator.resolve(
            id: id,
            conversationID: activeConversationID,
            with: .planReview(decision)
        )
    }

    func cancelPendingInteractions(forConversationID conversationID: String) {
        deliveryCoordinator.cancelDeliveryAndInteractions(for: conversationID)
    }

    func dismissOfflineBanner() {
        recoveryCoordinator.dismissOfflineBanner()
    }

    /// Manual recovery for when the path monitor is slow to notice the network is back
    /// (common on the simulator): attempt a real reconnect, and if it succeeds treat
    /// the app as online again and flush the queue without waiting for the monitor.
    func retryConnectivity() {
        recoveryCoordinator.retryConnectivity()
    }

    func reconnect() async {
        errorMessage = nil
        await recoveryCoordinator.reconnectActiveConversation()
    }

    func dismissError() {
        errorMessage = nil
        connectivityErrorMessage = nil
    }

    // create banner for failed delivery or reconnect
    func presentConnectionError(_ error: Error, forConversationID conversationID: String) {
        guard activeConversationID == conversationID else {
            return
        }
        let message = error.localizedDescription
        guard HostedAgentClientError.isConnectivityFailure(error) else {
            errorMessage = message
            return
        }
        guard !isOffline else {
            return
        }
        errorMessage = message
        // Recorded so a later drop can retract this banner, whose message it would only repeat.
        connectivityErrorMessage = message
    }

    /// The socket dying and the path monitor noticing race, so suppressing at presentation time
    /// only covers one order. When the monitor is the one that arrives second, take the banner
    /// its message supersedes back down.
    func retractConnectivityError() {
        guard errorMessage != nil, errorMessage == connectivityErrorMessage else {
            return
        }
        errorMessage = nil
    }

    /// Keeps an in-flight round-trip alive across app suspension: entering the background
    /// buys extended execution time while a delivery is running, and returning to the
    /// foreground refreshes the transport's liveness clock so the suspended interval is
    /// not mistaken for a dead connection.
    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            beginBackgroundDeliveryHold()
        case .active:
            client.applicationDidBecomeActive()
            endBackgroundDeliveryHold()
        default:
            break
        }
    }

    func beginBackgroundDeliveryHold() {
        guard backgroundDeliveryTaskID == .invalid,
              deliveryCoordinator.hasActiveDeliveries else {
            return
        }
        backgroundDeliveryTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "HostedAgentDelivery"
        ) { [weak self] in
            self?.endBackgroundDeliveryHold()
        }
    }

    func endBackgroundDeliveryHold() {
        guard backgroundDeliveryTaskID != .invalid else {
            return
        }
        UIApplication.shared.endBackgroundTask(backgroundDeliveryTaskID)
        backgroundDeliveryTaskID = .invalid
    }

    func upsertAgent(_ agent: AgentConnection) -> AgentConnection {
        let next = conversationState.upsertAgent(agent)
        agentAddressDraft = next.address
        return next
    }

    func ensureDefaultConversation(for agent: AgentConnection, seed: Conversation) {
        var normalizedSeed = seed
        if let existing = conversations(for: agent).first,
           let session = seed.serverSession {
            normalizedSeed.serverSession = HostedAgentSessionState.applying(
                existing.mode,
                to: session,
                conversationID: existing.id
            )
        }
        conversationState.ensureDefaultConversation(
            for: agent,
            seed: normalizedSeed,
            currentDraft: prompt
        )
        prompt = conversationState.activeDraft
        restorePendingAttachmentDrafts()
    }

    func restorePendingAttachmentDrafts() {
        guard let activeConversationID else {
            pendingImages = []
            pendingFiles = []
            return
        }
        pendingImages = imageDraftsByConversationID[activeConversationID] ?? []
        pendingFiles = fileDraftsByConversationID[activeConversationID] ?? []
    }

#if DEBUG
    /// Test-only seam for planting conversation state that normally arrives from the server.
    /// It goes through the persisting `upsert` on purpose — the previous settable
    /// `conversations` property let callers mutate the in-memory array without ever
    /// reaching the store, which is the classic bug in this layer.
    func upsertForTesting(_ conversation: Conversation) {
        upsert(conversation)
    }
#endif

    func upsert(
        _ conversation: Conversation,
        persistence: ConversationPersistence = .full
    ) {
        conversationState.upsert(conversation, persistence: persistence)
    }

    func agent(for conversation: Conversation) -> AgentConnection? {
        conversationState.agent(for: conversation)
    }

    private func conversationBelongsToAgent(_ conversation: Conversation, _ agent: AgentConnection) -> Bool {
        conversationState.conversationBelongsToAgent(conversation, agent)
    }

}
