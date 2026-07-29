import Combine
import Foundation
import SwiftUI
import UIKit

enum ConversationActivityState: Hashable {
    case actionRequired
    case working
    case completedUnread
    case failedDelivery
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var identity: StoredIdentity?
    @Published var isConnecting = false
    @Published var errorMessage: String?
    @Published var agentAddressDraft = ""
    @Published var prompt = "" {
        didSet {
            conversationState.updateActiveDraft(prompt)
        }
    }
    @Published private(set) var pendingImages: [ChatImageAttachment] = [] {
        didSet {
            guard let activeConversationID else {
                return
            }
            imageDraftsByConversationID[activeConversationID] = pendingImages
        }
    }
    @Published private(set) var pendingFiles: [ChatFileAttachment] = [] {
        didSet {
            guard let activeConversationID else {
                return
            }
            fileDraftsByConversationID[activeConversationID] = pendingFiles
        }
    }

    var isOffline: Bool {
        recoveryCoordinator.isOffline
    }

    var isOfflineBannerDismissed: Bool {
        recoveryCoordinator.isOfflineBannerDismissed
    }

    var shouldShowOfflineBanner: Bool {
        recoveryCoordinator.shouldShowOfflineBanner
    }

    var recoveryTask: Task<Void, Never>? {
        recoveryCoordinator.recoveryTask
    }

    var probeTask: Task<Void, Never>? {
        recoveryCoordinator.probeTask
    }

    var disconnectTask: Task<Void, Never>? {
        recoveryCoordinator.disconnectTask
    }

    private let interactionCoordinator: InteractionCoordinator
    private let deliveryCoordinator: MessageDeliveryCoordinator
    private let recoveryCoordinator: ConnectionRecoveryCoordinator
    private let skillCoordinator: SkillLoadingCoordinator
    private var interactionChangeCancellable: AnyCancellable?
    private var deliveryChangeCancellable: AnyCancellable?
    private var recoveryChangeCancellable: AnyCancellable?
    private var skillChangeCancellable: AnyCancellable?
    private var conversationStateChangeCancellable: AnyCancellable?
    private var persistenceErrorCancellable: AnyCancellable?
    private var offlineStateCancellable: AnyCancellable?
    /// Text of the banner currently raised by a connectivity failure, so going offline can
    /// retract it. Nothing else is retracted: a banner about a photo or the store is still
    /// news once the network drops.
    private var connectivityErrorMessage: String?
    private var voiceInputChangeCancellable: AnyCancellable?
    private var imageDraftsByConversationID: [String: [ChatImageAttachment]] = [:]
    private var fileDraftsByConversationID: [String: [ChatFileAttachment]] = [:]
    private let voiceInputController: VoiceInputController
    private var backgroundDeliveryTaskID: UIBackgroundTaskIdentifier = .invalid

    var probeInterval: TimeInterval {
        get {
            recoveryCoordinator.probeInterval
        }
        set {
            recoveryCoordinator.probeInterval = newValue
        }
    }

    private let conversationState: ConversationState
    private var client: HostedAgentTransport

    var agents: [AgentConnection] {
        conversationState.agents
    }

    var conversations: [Conversation] {
        conversationState.conversations
    }

    var activeAgentID: String? {
        conversationState.activeAgentID
    }

    var activeConversationID: String? {
        conversationState.activeConversationID
    }

    var activeAgent: AgentConnection? {
        conversationState.activeAgent
    }

    var activeConversation: Conversation? {
        conversationState.activeConversation
    }

    var activeMode: ChatMode {
        activeConversation?.mode ?? .safe
    }

    var connectionState: ConnectionState {
        guard let activeConversationID else {
            return .disconnected
        }
        return recoveryCoordinator.connectionState(forConversationID: activeConversationID)
    }

    var isProcessing: Bool {
        guard let activeConversationID else {
            return false
        }
        return deliveryCoordinator.isProcessing(conversationID: activeConversationID)
    }

    var voiceInputState: VoiceInputState {
        voiceInputController.state
    }

    var isVoiceInputActive: Bool {
        voiceInputController.isActive
    }

    var sendTask: Task<Void, Never>? {
        deliveryCoordinator.task(for: activeConversationID)
    }

    var activePendingApproval: PendingApproval? {
        interactionCoordinator.pendingApproval(for: activeConversationID)
    }

    var activePendingUlwCheckpoint: PendingUlwCheckpoint? {
        interactionCoordinator.pendingUlwCheckpoint(for: activeConversationID)
    }

    var activePendingPlanReview: PendingPlanReview? {
        interactionCoordinator.pendingPlanReview(for: activeConversationID)
    }

    var activePendingAskUser: PendingAskUser? {
        interactionCoordinator.pendingAskUser(for: activeConversationID)
    }

    var pendingInteractionID: String? {
        interactionCoordinator.pendingInteractionID(for: activeConversationID)
    }

    func isProcessing(conversationID: String) -> Bool {
        deliveryCoordinator.isProcessing(conversationID: conversationID)
    }

    func hasPendingInteraction(forConversationID conversationID: String) -> Bool {
        interactionCoordinator.hasPendingInteraction(for: conversationID)
    }

    func activityState(forConversationID conversationID: String) -> ConversationActivityState? {
        if interactionCoordinator.hasPendingInteraction(for: conversationID) {
            return .actionRequired
        }
        if deliveryCoordinator.isProcessing(conversationID: conversationID) {
            return .working
        }
        if conversationState.failedDeliveryConversationIDs.contains(conversationID) {
            return .failedDelivery
        }
        if conversationState.completedUnreadConversationIDs.contains(conversationID) {
            return .completedUnread
        }
        return nil
    }

    var backgroundActivityState: ConversationActivityState? {
        let backgroundConversationIDs = conversations.lazy
            .map(\.id)
            .filter { $0 != self.activeConversationID }
        let states = backgroundConversationIDs.compactMap(activityState(forConversationID:))

        if states.contains(.actionRequired) {
            return .actionRequired
        }
        if states.contains(.failedDelivery) {
            return .failedDelivery
        }
        if states.contains(.completedUnread) {
            return .completedUnread
        }
        return nil
    }

    var hasBackgroundPendingInteraction: Bool {
        interactionCoordinator.hasPendingInteraction(excluding: activeConversationID)
    }

    func hasFailedDelivery(forConversationID conversationID: String) -> Bool {
        conversationState.failedDeliveryConversationIDs.contains(conversationID)
    }

    /// A send that fails in a background conversation only raises the error banner when that
    /// conversation happens to be active, so surface it on the sidebar affordance too.
    var hasBackgroundDeliveryFailure: Bool {
        conversationState.failedDeliveryConversationIDs.contains { $0 != activeConversationID }
    }

    var needsBackgroundAttention: Bool {
        backgroundActivityState != nil
    }

    /// True when a running tool message duplicates the approval card already on screen, so the
    /// chat can hide the bubble and show only the card. The agent may name the tool differently
    /// in the two frames, hence the fallback to comparing rendered action summaries.
    func isToolCallCoveredByPendingApproval(_ message: ChatMessage, in conversationID: String) -> Bool {
        guard let approval = activePendingApproval,
              approval.conversationID == conversationID,
              message.role == .tool,
              message.toolState == .running,
              message.content.isEmpty else {
            return false
        }

        let messageArguments = message.toolArguments ?? [:]
        guard messageArguments == approval.request.arguments else {
            return false
        }

        if message.toolName == approval.request.tool {
            return true
        }

        return ToolActionSummary.requested(
            toolName: message.toolName ?? "tool",
            arguments: messageArguments
        ) == ToolActionSummary.requested(
            toolName: approval.request.tool,
            arguments: approval.request.arguments
        )
    }

    var onlineAgentCount: Int {
        agents.filter(isAgentOnline).count
    }

    func isAgentOnline(_ agent: AgentConnection) -> Bool {
        conversations(for: agent).contains { conversation in
            recoveryCoordinator.connectionState(forConversationID: conversation.id) == .connected
        }
    }

    var slashSkillSuggestions: [AgentSkill] {
        skillCoordinator.suggestions(
            prompt: prompt,
            agentAddress: activeAgent?.address
        )
    }

    var shouldShowSlashSkillPicker: Bool {
        skillCoordinator.shouldShowSuggestions(
            prompt: prompt,
            agentAddress: activeAgent?.address
        )
    }

    init(
        store: ConversationRepository? = nil,
        identityStore: IdentityStore = IdentityStore(),
        client: HostedAgentTransport? = nil,
        networkMonitor: NetworkPathMonitoring? = nil,
        voiceInputController: VoiceInputController? = nil
    ) {
        let resolvedStore: ConversationRepository
        let storeError: Error?
        if let store {
            resolvedStore = store
            storeError = nil
        } else {
            let outcome = ConversationRepositoryFactory.makeOutcome()
            resolvedStore = outcome.repository
            storeError = outcome.error
        }
        let store = resolvedStore
        let conversationState = ConversationState(store: store)
        let interactionCoordinator = InteractionCoordinator()
        let transport = client ?? HostedAgentClient(identityStore: identityStore)
        let deliveryCoordinator = MessageDeliveryCoordinator(
            conversationState: conversationState,
            interactionCoordinator: interactionCoordinator,
            transport: transport
        )
        let skillCoordinator = SkillLoadingCoordinator(transport: transport)
        let recoveryCoordinator = ConnectionRecoveryCoordinator(
            conversationState: conversationState,
            deliveryCoordinator: deliveryCoordinator,
            networkMonitor: networkMonitor ?? NetworkMonitor(),
            transport: transport
        )
        self.conversationState = conversationState
        self.interactionCoordinator = interactionCoordinator
        self.deliveryCoordinator = deliveryCoordinator
        self.recoveryCoordinator = recoveryCoordinator
        self.skillCoordinator = skillCoordinator
        self.client = transport
        self.voiceInputController = voiceInputController ?? VoiceInputController()
        self.agentAddressDraft = conversationState.activeAgent?.address ?? ""
        do {
            self.identity = try identityStore.loadOrCreateIdentity()
        } catch {
            self.errorMessage = error.localizedDescription
        }
        if let error = conversationState.persistenceError {
            self.errorMessage = error.localizedDescription
        }
        // Assigned last so it outranks the others: the app is running without a durable
        // store, which the user needs to know before they type anything they care about.
        if let storeError {
            self.errorMessage = "Couldn’t open your saved conversations, so this session won’t be saved. \(storeError.localizedDescription)"
        }
        observeCoordinators()
        recoveryCoordinator.start()
    }

    /// Everything the coordinators call back into, wired once the stored properties exist.
    private func observeCoordinators() {
        recoveryCoordinator.onRecoveryError = { [weak self] conversationID, error in
            self?.presentConnectionError(error, forConversationID: conversationID)
        }
        recoveryCoordinator.onReconnect = { [weak self] agent in
            self?.skillCoordinator.refreshSkills(for: agent)
        }
        deliveryCoordinator.onDeliveryError = { [weak self] conversationID, error in
            self?.presentConnectionError(error, forConversationID: conversationID)
        }
        deliveryCoordinator.onDeliveriesIdle = { [weak self] in
            self?.endBackgroundDeliveryHold()
        }
        offlineStateCancellable = recoveryCoordinator.$isOffline
            .removeDuplicates()
            .sink { [weak self] isOffline in
                guard isOffline else {
                    return
                }
                self?.retractConnectivityError()
            }
        persistenceErrorCancellable = conversationState.$persistenceError
            .compactMap { $0 }
            .sink { [weak self] error in
                self?.errorMessage = error.localizedDescription
            }
        forwardChangesFromCoordinators()
    }

    /// The coordinators own the state the views read through this view model, so their
    /// changes have to reach SwiftUI as changes to this object.
    private func forwardChangesFromCoordinators() {
        interactionChangeCancellable = forwardingChanges(from: interactionCoordinator.objectWillChange)
        deliveryChangeCancellable = forwardingChanges(from: deliveryCoordinator.objectWillChange)
        recoveryChangeCancellable = forwardingChanges(from: recoveryCoordinator.objectWillChange)
        skillChangeCancellable = forwardingChanges(from: skillCoordinator.objectWillChange)
        conversationStateChangeCancellable = forwardingChanges(from: conversationState.objectWillChange)
        voiceInputChangeCancellable = forwardingChanges(from: voiceInputController.objectWillChange)
    }

    private func forwardingChanges(from publisher: ObservableObjectPublisher) -> AnyCancellable {
        publisher.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func agent(withID id: String) -> AgentConnection? {
        conversationState.agent(withID: id)
    }

    func conversation(withID id: String) -> Conversation? {
        conversationState.conversation(withID: id)
    }

    func conversations(for agent: AgentConnection) -> [Conversation] {
        conversationState.conversations(for: agent)
    }

    func selectAgent(_ agent: AgentConnection) {
        conversationState.selectAgent(agent, currentDraft: prompt)
        prompt = conversationState.activeDraft
        restorePendingAttachmentDrafts()
        agentAddressDraft = agent.address
        skillCoordinator.loadSkillsIfNeeded(for: agent, isOffline: isOffline)
    }

    func selectConversation(_ conversation: Conversation) {
        conversationState.selectConversation(conversation, currentDraft: prompt)
        prompt = conversationState.activeDraft
        restorePendingAttachmentDrafts()
        if let agent = agent(for: conversation) {
            agentAddressDraft = agent.address
            skillCoordinator.loadSkillsIfNeeded(for: agent, isOffline: isOffline)
        }
    }

    func selectConversation(withID id: String) {
        guard let conversation = conversation(withID: id) else {
            return
        }
        selectConversation(conversation)
    }

    func createConversation(for agent: AgentConnection) -> Conversation {
        let conversation = conversationState.createConversation(for: agent, currentDraft: prompt)
        prompt = conversationState.activeDraft
        restorePendingAttachmentDrafts()
        recoveryCoordinator.setConnectionState(.disconnected, forConversationID: conversation.id)
        agentAddressDraft = agent.address
        return conversation
    }

    @discardableResult
    func saveAgent(id: String? = nil, name: String, address: String) -> AgentConnection? {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard HostedAgentClient.isHostedAgentAddress(trimmedAddress) else {
            errorMessage = "That doesn't look like an agent address. It should start with 0x followed by 64 characters."
            return nil
        }
        errorMessage = nil
        let next = conversationState.saveAgent(
            id: id,
            name: trimmedName,
            address: trimmedAddress
        )
        agentAddressDraft = next.address
        return next
    }

    func fetchAgentName(for address: String) async -> String? {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HostedAgentClient.isHostedAgentAddress(trimmedAddress) else {
            return nil
        }
        return try? await client.fetchAgentName(agentAddress: trimmedAddress)
    }

    func switchToAgentForChat(_ agent: AgentConnection) {
        agentAddressDraft = agent.address
        if let conversation = conversations(for: agent).first {
            conversationState.selectConversation(conversation, currentDraft: prompt)
            prompt = conversationState.activeDraft
        } else {
            _ = createConversation(for: agent)
        }
        restorePendingAttachmentDrafts()
        skillCoordinator.loadSkillsIfNeeded(for: agent, isOffline: isOffline)
    }

    func promptDidChange() {
        guard skillCoordinator.isSlashQuery(prompt), let activeAgent else {
            return
        }
        skillCoordinator.loadSkillsIfNeeded(for: activeAgent, isOffline: isOffline)
    }

    func prefetchActiveAgentSkills() {
        guard let activeAgent else {
            return
        }
        skillCoordinator.loadSkillsIfNeeded(for: activeAgent, isOffline: isOffline)
    }

    func selectSlashSkill(_ skill: AgentSkill) {
        prompt = "/\(skill.name) "
    }

    func deleteConversation(_ conversation: Conversation) {
        cancelPendingInteractions(forConversationID: conversation.id)
        recoveryCoordinator.removeConnectionState(forConversationID: conversation.id)
        conversationState.deleteConversation(conversation, currentDraft: prompt)
        imageDraftsByConversationID[conversation.id] = nil
        fileDraftsByConversationID[conversation.id] = nil
        prompt = conversationState.activeDraft
        restorePendingAttachmentDrafts()
    }

    func deleteAgent(_ agent: AgentConnection) {
        let deletedConversationIDs = Set(conversations(for: agent).map(\.id))
        for conversationID in deletedConversationIDs {
            cancelPendingInteractions(forConversationID: conversationID)
            recoveryCoordinator.removeConnectionState(forConversationID: conversationID)
        }
        conversationState.deleteAgent(agent, currentDraft: prompt)
        for conversationID in deletedConversationIDs {
            imageDraftsByConversationID[conversationID] = nil
            fileDraftsByConversationID[conversationID] = nil
        }
        prompt = conversationState.activeDraft
        restorePendingAttachmentDrafts()
        agentAddressDraft = activeAgent?.address ?? ""
    }

    /// Renames a conversation in place. Empty/whitespace titles and no-op renames are
    /// ignored. A rename is a metadata edit, not activity, so it deliberately does not
    /// reorder the list, bump `updatedAt`, or change the active conversation — only the
    /// title and its persisted row change.
    func renameConversation(_ conversation: Conversation, to title: String) {
        conversationState.renameConversation(conversation, to: title)
    }

    /// Filters conversations by title and message content via the store's indexed query,
    /// optionally scoped to a single agent. An empty/whitespace query returns all
    /// conversations (most-recent-first), matching the repository contract.
    func searchConversations(_ query: String, for agent: AgentConnection? = nil) -> [Conversation] {
        conversationState.searchConversations(query, for: agent)
    }

    func setMode(_ mode: ChatMode) {
        guard var conversation = activeConversation else {
            return
        }
        guard conversation.mode != mode else {
            return
        }
        conversation.mode = mode
        conversation.serverSession = HostedAgentSessionState.applying(
            mode,
            to: conversation.serverSession,
            conversationID: conversation.id
        )
        // Integral seconds only: this session feeds `session_sha256`, and CanonicalJSON
        // serializes non-integral doubles via Swift's own formatting, which is not
        // guaranteed to match the Python/TS reference implementations byte for byte.
        conversation.serverSession?["updated"] = .number(Date().timeIntervalSince1970.rounded(.down))
        upsert(conversation)
    }

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
            return nil
        }
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

    private func cancelPendingInteractions(forConversationID conversationID: String) {
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

    // Raises a banner for a failed delivery or reconnect
    private func presentConnectionError(_ error: Error, forConversationID conversationID: String) {
        guard activeConversationID == conversationID else {
            return
        }
        let message = error.localizedDescription
        guard HostedAgentClientError.isConnectivityFailure(error) else {
            errorMessage = message
            return
        }
        // Recorded even while suppressed so a later drop can retract an identical banner.
        connectivityErrorMessage = message
        guard !isOffline else {
            return
        }
        errorMessage = message
    }

    /// The socket dying and the path monitor noticing race, so suppressing at presentation time
    /// only covers one order. When the monitor is the one that arrives second, take the banner
    /// its message supersedes back down.
    private func retractConnectivityError() {
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

    private func beginBackgroundDeliveryHold() {
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

    private func endBackgroundDeliveryHold() {
        guard backgroundDeliveryTaskID != .invalid else {
            return
        }
        UIApplication.shared.endBackgroundTask(backgroundDeliveryTaskID)
        backgroundDeliveryTaskID = .invalid
    }

    private func upsertAgent(_ agent: AgentConnection) -> AgentConnection {
        let next = conversationState.upsertAgent(agent)
        agentAddressDraft = next.address
        return next
    }

    private func ensureDefaultConversation(for agent: AgentConnection, seed: Conversation) {
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

    private func restorePendingAttachmentDrafts() {
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

    private func upsert(
        _ conversation: Conversation,
        persistence: ConversationPersistence = .full
    ) {
        conversationState.upsert(conversation, persistence: persistence)
    }

    private func agent(for conversation: Conversation) -> AgentConnection? {
        conversationState.agent(for: conversation)
    }

    private func conversationBelongsToAgent(_ conversation: Conversation, _ agent: AgentConnection) -> Bool {
        conversationState.conversationBelongsToAgent(conversation, agent)
    }

}
