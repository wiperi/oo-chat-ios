import Combine
import Foundation

enum MessageEnqueueResult {
    case queued
    case rejected(String)
}

@MainActor
final class MessageDeliveryCoordinator: ObservableObject {
    @Published private var processingConversationIDs: Set<String> = []

    var onConnectionStateChange: ((String, ConnectionState) -> Void)?
    var connectionState: ((String) -> ConnectionState)?
    var onDeliveryError: ((String, String) -> Void)?

    private var deliveryTasksByConversationID: [String: Task<Void, Never>] = [:]
    private var activeMessageIDsByConversationID: [String: String] = [:]
    private var pausedConversationIDs: Set<String> = []
    private var isDeliveryEnabled = true

    private let conversationState: ConversationState
    private let interactionCoordinator: InteractionCoordinator
    private let transport: HostedAgentTransport

    init(
        conversationState: ConversationState,
        interactionCoordinator: InteractionCoordinator,
        transport: HostedAgentTransport
    ) {
        self.conversationState = conversationState
        self.interactionCoordinator = interactionCoordinator
        self.transport = transport
    }

    deinit {
        deliveryTasksByConversationID.values.forEach { $0.cancel() }
    }

    func setDeliveryEnabled(_ isEnabled: Bool) {
        isDeliveryEnabled = isEnabled
    }

    func isProcessing(conversationID: String) -> Bool {
        processingConversationIDs.contains(conversationID)
    }

    func task(for conversationID: String?) -> Task<Void, Never>? {
        guard let conversationID else {
            return nil
        }
        return deliveryTasksByConversationID[conversationID]
    }

    func enqueuePrompt(_ text: String) -> MessageEnqueueResult {
        guard var conversation = conversationState.activeConversation,
              let agent = conversationState.agent(for: conversation),
              HostedAgentClient.isHostedAgentAddress(agent.address) else {
            return .rejected("Connect to an agent before sending a message.")
        }

        conversation.agentID = agent.id
        conversation.agentAddress = agent.address
        if conversation.title == Conversation.defaultTitle {
            conversation.title = Self.title(from: text)
        }
        conversation.messages.append(
            ChatMessage(role: .user, content: text, deliveryState: .queued)
        )
        conversationState.clearCompletedUnread(conversationID: conversation.id)
        conversationState.upsert(conversation)
        pausedConversationIDs.remove(conversation.id)

        if isDeliveryEnabled {
            startNextQueuedMessage(in: conversation.id)
        }
        return .queued
    }

    @discardableResult
    func retryMessage(_ message: ChatMessage) -> Bool {
        guard message.role == .user,
              message.deliveryState == .failed || message.deliveryState == .cancelled,
              var conversation = conversationState.conversations.first(where: { candidate in
                  candidate.messages.contains { $0.id == message.id }
              }),
              let index = conversation.messages.firstIndex(where: { $0.id == message.id }) else {
            return false
        }

        conversation.messages[index].deliveryState = .queued
        conversationState.clearCompletedUnread(conversationID: conversation.id)
        conversationState.upsert(conversation)
        pausedConversationIDs.remove(conversation.id)
        if isDeliveryEnabled {
            startNextQueuedMessage(in: conversation.id)
        }
        return true
    }

    func flushQueuedMessages() async {
        guard isDeliveryEnabled else {
            return
        }

        for conversation in conversationState.conversations {
            startNextQueuedMessage(in: conversation.id)
        }

        while isDeliveryEnabled {
            let tasks = Array(deliveryTasksByConversationID.values)
            guard !tasks.isEmpty else {
                break
            }
            for task in tasks {
                await task.value
            }
        }
    }

    func stopActiveResponse() {
        guard let conversationID = conversationState.activeConversationID,
              let task = deliveryTasksByConversationID[conversationID],
              let conversation = conversationState.conversation(withID: conversationID),
              let agent = conversationState.agent(for: conversation) else {
            return
        }

        pausedConversationIDs.insert(conversationID)
        guard interactionCoordinator.cancelInteractions(for: conversationID) else {
            task.cancel()
            return
        }

        let transport = transport
        Task {
            await transport.waitForPendingInteractionResponses(
                agentAddress: agent.address,
                conversationID: conversationID
            )
            task.cancel()
        }
    }

    func cancelDeliveryAndInteractions(for conversationID: String) {
        interactionCoordinator.cancelInteractions(for: conversationID)
        deliveryTasksByConversationID[conversationID]?.cancel()
        pausedConversationIDs.remove(conversationID)
    }

    @discardableResult
    private func startNextQueuedMessage(in conversationID: String) -> Bool {
        guard isDeliveryEnabled,
              !pausedConversationIDs.contains(conversationID),
              deliveryTasksByConversationID[conversationID] == nil,
              let conversation = conversationState.conversation(withID: conversationID),
              let message = conversation.messages.first(where: {
                  $0.role == .user && $0.deliveryState == .queued
              }) else {
            return false
        }

        activeMessageIDsByConversationID[conversationID] = message.id
        processingConversationIDs.insert(conversationID)
        if connectionState?(conversationID) != .connected {
            onConnectionStateChange?(conversationID, .reconnecting)
        }

        guard let deliveryTask = makeDeliveryTask(
            messageID: message.id,
            conversationID: conversationID
        ) else {
            activeMessageIDsByConversationID[conversationID] = nil
            processingConversationIDs.remove(conversationID)
            return false
        }
        deliveryTasksByConversationID[conversationID] = deliveryTask
        return true
    }

    private func makeDeliveryTask(
        messageID: String,
        conversationID: String
    ) -> Task<Void, Never>? {
        guard let conversation = conversationState.conversation(withID: conversationID),
              let message = conversation.messages.first(where: { $0.id == messageID }),
              message.role == .user,
              let agent = conversationState.agent(for: conversation),
              HostedAgentClient.isHostedAgentAddress(agent.address) else {
            return nil
        }
        var pending = conversation
        pending.messages.append(ChatMessage(role: .thinking, content: "Waiting for hosted agent…"))
        conversationState.upsert(pending)

        let transport = transport
        let interactionCoordinator = interactionCoordinator
        let conversationState = conversationState
        return Task { [weak self, transport, interactionCoordinator, conversationState] in
            defer {
                self?.deliveryDidFinish(
                    messageID: messageID,
                    conversationID: conversationID
                )
            }
            do {
                let result = try await transport.sendPrompt(
                    agentAddress: agent.address,
                    conversation: pending,
                    prompt: message.content,
                    onEvent: { [weak self] event in
                        self?.apply(event, toConversationID: conversationID)
                    },
                    onInteraction: { [interactionCoordinator, conversationState] interaction in
                        await interactionCoordinator.handle(
                            interaction,
                            conversationID: conversationID
                        ) {
                            conversationState.conversation(withID: conversationID) != nil
                        }
                    }
                )
                try Task.checkCancellation()
                self?.completeDelivery(
                    result,
                    messageID: messageID,
                    conversationID: conversationID
                )
            } catch is CancellationError {
                self?.cancelDelivery(messageID: messageID, conversationID: conversationID)
            } catch {
                self?.failDelivery(
                    error,
                    messageID: messageID,
                    conversationID: conversationID
                )
            }
        }
    }

    private func deliveryDidFinish(messageID: String, conversationID: String) {
        guard activeMessageIDsByConversationID[conversationID] == messageID else {
            return
        }
        deliveryTasksByConversationID[conversationID] = nil
        activeMessageIDsByConversationID[conversationID] = nil
        processingConversationIDs.remove(conversationID)
        if isDeliveryEnabled, !pausedConversationIDs.contains(conversationID) {
            startNextQueuedMessage(in: conversationID)
        }
    }

    private func completeDelivery(
        _ result: HostedAgentResult,
        messageID: String,
        conversationID: String
    ) {
        guard var updated = conversationState.conversation(withID: conversationID) else {
            return
        }
        updated.messages.removeAll { $0.role == .thinking }
        if let index = updated.messages.firstIndex(where: { $0.id == messageID }) {
            updated.messages[index].deliveryState = .sent
        }
        if let session = result.serverSession {
            updated.mode = HostedAgentSessionState.mode(from: session, fallback: updated.mode)
            updated.serverSession = HostedAgentSessionState.applying(
                updated.mode,
                to: session,
                conversationID: updated.id
            )
        }
        // An empty output would otherwise render as a blank bubble.
        if let output = result.output, !output.isEmpty {
            updated.messages.append(ChatMessage(role: .agent, content: output))
        }
        onConnectionStateChange?(conversationID, .connected)
        conversationState.upsert(updated)
        conversationState.markCompletedUnread(conversationID: conversationID)
    }

    private func failDelivery(
        _ error: Error,
        messageID: String,
        conversationID: String
    ) {
        guard var updated = conversationState.conversation(withID: conversationID) else {
            return
        }
        updated.messages.removeAll { $0.role == .thinking }
        if let index = updated.messages.firstIndex(where: { $0.id == messageID }) {
            updated.messages[index].deliveryState = .failed
        }
        conversationState.clearCompletedUnread(conversationID: conversationID)
        onDeliveryError?(conversationID, error.localizedDescription)
        onConnectionStateChange?(conversationID, .disconnected)
        conversationState.upsert(updated)
    }

    private func cancelDelivery(messageID: String, conversationID: String) {
        guard var updated = conversationState.conversation(withID: conversationID) else {
            return
        }
        updated.messages.removeAll { $0.role == .thinking }
        if let index = updated.messages.firstIndex(where: { $0.id == messageID }) {
            updated.messages[index].deliveryState = .cancelled
        }
        conversationState.clearCompletedUnread(conversationID: conversationID)
        onConnectionStateChange?(conversationID, .disconnected)
        conversationState.upsert(updated)
    }

    private func apply(_ event: HostedAgentEvent, toConversationID conversationID: String) {
        guard var conversation = conversationState.conversation(withID: conversationID) else {
            return
        }

        let persistence: ConversationPersistence
        switch event {
        case .toolCall(let id, let name, let arguments):
            guard !conversation.messages.contains(where: { $0.id == id }) else {
                return
            }
            conversation.messages.append(
                ChatMessage(
                    id: id,
                    role: .tool,
                    content: "",
                    toolName: name,
                    toolArguments: arguments,
                    toolState: .running
                )
            )
            persistence = .message(id: id)
        case .toolResult(let id, let name, let output, let state):
            if let index = conversation.messages.firstIndex(where: { $0.id == id && $0.role == .tool }) {
                conversation.messages[index].toolName = name ?? conversation.messages[index].toolName
                conversation.messages[index].content = output
                conversation.messages[index].toolState = state
            } else {
                conversation.messages.append(
                    ChatMessage(
                        id: id,
                        role: .tool,
                        content: output,
                        toolName: name ?? "tool",
                        toolState: state
                    )
                )
            }
            persistence = .message(id: id)
        case .modeChanged(let mode):
            conversation.mode = mode
            conversation.serverSession = HostedAgentSessionState.applying(
                mode,
                to: conversation.serverSession,
                conversationID: conversationID
            )
            persistence = .metadata
        }

        conversationState.upsert(conversation, persistence: persistence)
    }

    private static func title(from text: String) -> String {
        if text.count > 38 {
            return String(text.prefix(35)) + "..."
        }
        return text
    }
}
