import Foundation
import Network
import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var identity: StoredIdentity?
    @Published var agents: [AgentConnection]
    @Published var conversations: [Conversation]
    @Published var activeAgentID: String?
    @Published var activeConversationID: String?
    @Published var connectionState: ConnectionState = .disconnected
    @Published var isConnecting = false
    @Published var isProcessing = false
    @Published var errorMessage: String?
    @Published var connectionFailureMessage: String?
    @Published var pendingInteraction: PendingInteraction?
    @Published var agentAddressDraft = ""
    @Published var prompt = ""

    private let store = ConversationStore()
    private let identityStore = IdentityStore()
    private lazy var client = HostedAgentClient(identityStore: identityStore)
    private lazy var runtime = AgentRuntimeManager(client: client)
    private var sessionEventTasks: [SessionKey: Task<Void, Never>] = [:]
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "connectonion.native-ios.network-monitor")
    private var networkMonitorStarted = false

    var activeAgent: AgentConnection? {
        if let activeAgentID, let agent = agent(withID: activeAgentID) {
            return agent
        }
        if let activeConversation, let agent = agent(for: activeConversation) {
            return agent
        }
        return agents.first
    }

    var activeConversation: Conversation? {
        guard let activeConversationID else {
            return nil
        }
        return conversations.first { $0.id == activeConversationID }
    }

    var activeMode: ChatMode {
        activeConversation?.mode ?? .safe
    }

    init() {
        let snapshot = store.load()
        self.agents = snapshot.agents
        self.conversations = snapshot.conversations
        self.activeConversationID = snapshot.activeConversationID
        let activeConversationAgentID = snapshot.activeConversationID.flatMap { activeConversationID in
            snapshot.conversations.first { $0.id == activeConversationID }?.agentID
        }
        self.activeAgentID = snapshot.activeAgentID
            ?? activeConversationAgentID
            ?? snapshot.agents.first?.id
        self.agentAddressDraft = snapshot.agents.first { $0.id == self.activeAgentID }?.address ?? ""
        do {
            self.identity = try identityStore.loadOrCreateIdentity()
        } catch {
            self.errorMessage = error.localizedDescription
        }
        startNetworkMonitoring()
    }

    deinit {
        networkMonitor.cancel()
        for task in sessionEventTasks.values {
            task.cancel()
        }
    }

    func agent(withID id: String) -> AgentConnection? {
        agents.first { $0.id == id }
    }

    func conversation(withID id: String) -> Conversation? {
        conversations.first { $0.id == id }
    }

    func conversations(for agent: AgentConnection) -> [Conversation] {
        conversations
            .filter { conversationBelongsToAgent($0, agent) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func selectAgent(_ agent: AgentConnection) {
        activeAgentID = agent.id
        agentAddressDraft = agent.address
        if let activeConversation, !conversationBelongsToAgent(activeConversation, agent) {
            activeConversationID = conversations(for: agent).first?.id
        } else if activeConversation == nil {
            activeConversationID = conversations(for: agent).first?.id
        }
        clearStalePendingInteraction()
        persist()
    }

    func selectConversation(_ conversation: Conversation) {
        activeConversationID = conversation.id
        if let agent = agent(for: conversation) {
            activeAgentID = agent.id
            agentAddressDraft = agent.address
        }
        clearStalePendingInteraction()
        persist()
    }

    func selectConversation(withID id: String) {
        guard let conversation = conversation(withID: id) else {
            return
        }
        selectConversation(conversation)
    }

    func createConversation(for agent: AgentConnection) -> Conversation {
        var conversation = Conversation(agentID: agent.id, agentAddress: agent.address)
        conversation.title = "New mobile session"
        conversations.insert(conversation, at: 0)
        activeAgentID = agent.id
        activeConversationID = conversation.id
        agentAddressDraft = agent.address
        connectionState = .disconnected
        pendingInteraction = nil
        persist()
        return conversation
    }

    func deleteConversation(_ conversation: Conversation) {
        if let agent = agent(for: conversation) {
            Task {
                await runtime.closeSession(agentAddress: agent.address, conversationID: conversation.id)
            }
        }
        conversations.removeAll { $0.id == conversation.id }
        if activeConversationID == conversation.id {
            if let activeAgent {
                activeConversationID = conversations(for: activeAgent).first?.id
            } else {
                activeConversationID = nil
            }
        }
        if pendingInteraction?.conversationID == conversation.id {
            pendingInteraction = nil
        }
        persist()
    }

    func deleteAgent(_ agent: AgentConnection) {
        let deletedConversationIDs = Set(conversations(for: agent).map(\.id))
        Task {
            await runtime.closeSessions(agentAddress: agent.address)
        }
        agents.removeAll { $0.id == agent.id }
        conversations.removeAll { conversationBelongsToAgent($0, agent) }

        if activeAgentID == agent.id {
            activeAgentID = agents.first?.id
            agentAddressDraft = activeAgent?.address ?? ""
        }
        if let activeConversationID, deletedConversationIDs.contains(activeConversationID) {
            if let activeAgent {
                self.activeConversationID = conversations(for: activeAgent).first?.id
            } else {
                self.activeConversationID = nil
            }
        }
        persist()
    }

    func setMode(_ mode: ChatMode) {
        guard var conversation = activeConversation else {
            return
        }
        conversation.mode = mode
        conversation.serverSession = session(conversation.serverSession, applying: mode, conversationID: conversation.id)
        upsert(conversation)
        if let agent = agent(for: conversation) {
            Task {
                let session = await runtimeSession(for: agent, conversation: conversation)
                await session.updateMode(mode, conversation: conversation)
            }
        }
    }

    func connectToAgent() async -> AgentConnection? {
        let address = agentAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HostedAgentClient.isHostedAgentAddress(address) else {
            let message = "Enter a hosted agent address in 0x-prefixed Ed25519 format."
            errorMessage = message
            connectionFailureMessage = message
            return nil
        }
        guard !isConnecting else {
            return nil
        }

        isConnecting = true
        connectionState = .reconnecting
        errorMessage = nil
        connectionFailureMessage = nil

        let agent = agents.first { $0.address == address } ?? AgentConnection(address: address)
        var conversation = conversations(for: agent).first ?? Conversation(agentID: agent.id, agentAddress: address)

        do {
            let session = await runtimeSession(for: agent, conversation: conversation)
            let result = try await session.connect(conversation: conversation)
            if let session = result.serverSession {
                conversation.serverSession = self.session(session, applying: conversation.mode, conversationID: conversation.id)
            }
            let savedAgent = upsertAgent(agent)
            ensureDefaultConversation(for: savedAgent, seed: conversation)
            connectionState = result.done ? .connected : .waiting
            isConnecting = false
            return savedAgent
        } catch {
            let message = error.localizedDescription
            connectionState = .disconnected
            errorMessage = message
            connectionFailureMessage = "Connection failed. \(message)"
            isConnecting = false
            return nil
        }
    }

    func sendPrompt() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, var conversation = activeConversation, !isProcessing else {
            return
        }
        guard let agent = agent(for: conversation),
              HostedAgentClient.isHostedAgentAddress(agent.address) else {
            errorMessage = "Use a hosted agent address before sending a message."
            return
        }

        if let pendingInteraction, pendingInteraction.conversationID == conversation.id {
            sendInteractionText(text, conversation: conversation, agent: agent, interaction: pendingInteraction)
            return
        }

        prompt = ""
        errorMessage = nil
        isProcessing = true
        connectionState = .reconnecting
        conversation.agentID = agent.id
        conversation.agentAddress = agent.address
        conversation.title = conversation.title == "New mobile session" ? titleFromPrompt(text) : conversation.title
        conversation.messages.append(ChatMessage(role: .user, content: text))
        conversation.messages.append(ChatMessage(role: .thinking, content: "Waiting for hosted agent..."))
        upsert(conversation)

        Task {
            defer {
                self.isProcessing = false
            }
            do {
                let session = await runtimeSession(for: agent, conversation: conversation)
                let result = try await session.sendPrompt(conversation: conversation, prompt: text)
                self.apply(result, toConversationID: conversation.id, fallback: conversation)
            } catch {
                self.apply(error, toConversationID: conversation.id, fallback: conversation)
            }
        }
    }

    func reconnect() async {
        guard let conversation = activeConversation,
              let agent = agent(for: conversation),
              HostedAgentClient.isHostedAgentAddress(agent.address) else {
            return
        }
        errorMessage = nil
        connectionState = .reconnecting
        do {
            let session = await runtimeSession(for: agent, conversation: conversation)
            let result = try await session.reconnect(conversation: conversation)
            apply(result, toConversationID: conversation.id, fallback: conversation)
        } catch {
            connectionState = .disconnected
            errorMessage = error.localizedDescription
        }
    }

    func respondToApproval(approved: Bool, scope: String? = nil) {
        guard let pendingInteraction,
              pendingInteraction.kind == .approval,
              let conversation = activeConversation,
              pendingInteraction.conversationID == conversation.id,
              let agent = agent(for: conversation) else {
            return
        }

        let label = approved ? "Approved" : "Rejected"
        var updated = conversation
        updated.messages.append(ChatMessage(role: .user, content: scope.map { "\(label) (\($0))" } ?? label))
        updated.messages.append(ChatMessage(role: .thinking, content: "Sending approval response..."))
        upsert(updated)
        isProcessing = true
        connectionState = .reconnecting
        self.pendingInteraction = nil

        Task {
            defer {
                self.isProcessing = false
            }
            do {
                var payload: [String: JSONValue] = ["approved": .bool(approved)]
                if let scope {
                    payload["scope"] = .string(scope)
                }
                let session = await runtimeSession(for: agent, conversation: updated)
                let result = try await session.sendInteractionResponse(
                    conversation: updated,
                    type: "APPROVAL_RESPONSE",
                    payload: payload
                )
                self.apply(result, toConversationID: updated.id, fallback: updated)
            } catch {
                self.apply(error, toConversationID: updated.id, fallback: updated)
            }
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            Task {
                await runtime.resumeAll()
            }
        case .background:
            Task {
                await runtime.suspendAll()
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func sendInteractionText(
        _ text: String,
        conversation: Conversation,
        agent: AgentConnection,
        interaction: PendingInteraction
    ) {
        prompt = ""
        errorMessage = nil
        isProcessing = true
        connectionState = .reconnecting
        pendingInteraction = nil

        var updated = conversation
        updated.messages.append(ChatMessage(role: .user, content: text))
        updated.messages.append(ChatMessage(role: .thinking, content: "Sending response..."))
        upsert(updated)

        Task {
            defer {
                self.isProcessing = false
            }
            do {
                let response = interactionResponse(for: interaction, text: text)
                let session = await runtimeSession(for: agent, conversation: updated)
                let result = try await session.sendInteractionResponse(
                    conversation: updated,
                    type: response.type,
                    payload: response.payload
                )
                self.apply(result, toConversationID: updated.id, fallback: updated)
            } catch {
                self.apply(error, toConversationID: updated.id, fallback: updated)
            }
        }
    }

    private func interactionResponse(for interaction: PendingInteraction, text: String) -> (type: String, payload: [String: JSONValue]) {
        switch interaction.kind {
        case .askUser:
            return ("ASK_USER_RESPONSE", ["answer": .string(text)])
        case .planReview:
            return ("PLAN_REVIEW_RESPONSE", ["message": .string(text)])
        case .ulwTurnsReached:
            return ("ULW_RESPONSE", ["action": .string(text)])
        case .onboard:
            return ("ONBOARD_SUBMIT", ["invite_code": .string(text)])
        case .approval:
            return ("APPROVAL_RESPONSE", ["approved": .bool(text.lowercased().contains("approve"))])
        }
    }

    private func apply(_ result: HostedAgentResult, toConversationID conversationID: String, fallback: Conversation) {
        var updated = conversation(withID: conversationID) ?? fallback
        removeTransientThinking(from: &updated)
        if let session = result.serverSession {
            updated.serverSession = self.session(session, applying: updated.mode, conversationID: updated.id)
        }
        if result.done,
           let output = result.output,
           !output.isEmpty,
           !updated.messages.contains(where: { $0.role == .agent && $0.content == output }) {
            updated.messages.append(ChatMessage(role: .agent, content: output))
        }
        updated.updatedAt = Date()
        connectionState = result.done ? .connected : .waiting
        if result.done {
            pendingInteraction = nil
        }
        saveConversation(updated, activate: activeConversationID == conversationID)
    }

    private func apply(_ error: Error, toConversationID conversationID: String, fallback: Conversation) {
        var updated = conversation(withID: conversationID) ?? fallback
        removeTransientThinking(from: &updated)
        updated.messages.append(ChatMessage(role: .error, content: error.localizedDescription))
        updated.updatedAt = Date()
        errorMessage = error.localizedDescription
        connectionState = .disconnected
        saveConversation(updated, activate: activeConversationID == conversationID)
    }

    private func removeTransientThinking(from conversation: inout Conversation) {
        let transientMessages = [
            "Waiting for hosted agent...",
            "Sending response...",
            "Sending approval response...",
        ]
        conversation.messages.removeAll { message in
            message.role == .thinking && transientMessages.contains(message.content)
        }
    }

    private func runtimeSession(for agent: AgentConnection, conversation: Conversation) async -> AgentSessionActor {
        let session = await runtime.session(for: agent, conversation: conversation)
        let key = SessionKey(agentAddress: agent.address, conversationID: conversation.id)
        subscribe(to: session, key: key)
        return session
    }

    private func subscribe(to session: AgentSessionActor, key: SessionKey) {
        guard sessionEventTasks[key] == nil else {
            return
        }
        sessionEventTasks[key] = Task { [weak self] in
            let stream = await session.events()
            for await event in stream {
                await MainActor.run {
                    self?.handle(event)
                }
            }
        }
    }

    private func handle(_ event: AgentSessionEvent) {
        switch event {
        case .stateChanged(let key, let state):
            if key.conversationID == activeConversationID {
                connectionState = state.connectionState
                if state.connectionState != .reconnecting {
                    isConnecting = false
                }
                if state.connectionState == .waiting {
                    isProcessing = false
                }
            }
        case .serverSessionUpdated(let key, let serverSession):
            guard var conversation = conversation(withID: key.conversationID) else {
                return
            }
            conversation.serverSession = session(serverSession, applying: conversation.mode, conversationID: conversation.id)
            saveConversation(conversation, activate: false)
        case .message(let key, let message):
            guard var conversation = conversation(withID: key.conversationID) else {
                return
            }
            if conversation.messages.last?.role == message.role,
               conversation.messages.last?.content == message.content {
                return
            }
            removeTransientThinking(from: &conversation)
            conversation.messages.append(message)
            conversation.updatedAt = Date()
            saveConversation(conversation, activate: false)
        case .pendingInteraction(let key, let interaction):
            if key.conversationID == activeConversationID {
                pendingInteraction = interaction
                if interaction != nil {
                    isProcessing = false
                    connectionState = .waiting
                }
            }
        }
    }

    private func clearStalePendingInteraction() {
        guard let pendingInteraction,
              pendingInteraction.conversationID != activeConversationID else {
            return
        }
        self.pendingInteraction = nil
    }

    private func startNetworkMonitoring() {
        guard !networkMonitorStarted else {
            return
        }
        networkMonitorStarted = true
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else {
                    return
                }
                if path.status == .satisfied {
                    await self.runtime.resumeAll()
                } else {
                    await self.runtime.networkBecameUnavailable()
                    self.connectionState = .disconnected
                }
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    private func upsertAgent(_ agent: AgentConnection) -> AgentConnection {
        var next = agent
        next.name = next.name.isEmpty ? AgentConnection.defaultName(for: next.address) : next.name
        next.updatedAt = Date()
        agents.removeAll { $0.id == next.id }
        agents.insert(next, at: 0)
        activeAgentID = next.id
        agentAddressDraft = next.address
        persist()
        return next
    }

    private func ensureDefaultConversation(for agent: AgentConnection, seed: Conversation) {
        if var existing = conversations(for: agent).first {
            if let session = seed.serverSession {
                existing.serverSession = self.session(session, applying: existing.mode, conversationID: existing.id)
            }
            existing.agentID = agent.id
            existing.agentAddress = agent.address
            activeConversationID = existing.id
            upsert(existing)
            return
        }

        var conversation = seed
        conversation.agentID = agent.id
        conversation.agentAddress = agent.address
        conversations.insert(conversation, at: 0)
        activeConversationID = conversation.id
        persist()
    }

    private func upsert(_ conversation: Conversation) {
        saveConversation(conversation, activate: true)
    }

    private func saveConversation(_ conversation: Conversation, activate: Bool) {
        var next = conversation
        next.updatedAt = Date()
        if let agent = agent(for: next) {
            next.agentID = agent.id
            next.agentAddress = agent.address
            touchAgent(id: agent.id, activate: activate)
        }
        conversations.removeAll { $0.id == next.id }
        conversations.insert(next, at: 0)
        if activate {
            activeConversationID = next.id
        }
        persist()
    }

    private func touchAgent(id: String, activate: Bool = true) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else {
            return
        }
        var agent = agents.remove(at: index)
        agent.updatedAt = Date()
        agents.insert(agent, at: 0)
        if activate {
            activeAgentID = agent.id
            agentAddressDraft = agent.address
        }
    }

    private func agent(for conversation: Conversation) -> AgentConnection? {
        if let agentID = conversation.agentID, let agent = agent(withID: agentID) {
            return agent
        }
        return agents.first { $0.address == conversation.agentAddress }
    }

    private func conversationBelongsToAgent(_ conversation: Conversation, _ agent: AgentConnection) -> Bool {
        conversation.agentID == agent.id || conversation.agentAddress == agent.address
    }

    private func session(_ session: [String: JSONValue]?, applying mode: ChatMode, conversationID: String) -> [String: JSONValue] {
        var next = session ?? [:]
        next["session_id"] = .string(conversationID)
        next["mode"] = .string(mode.rawValue)
        if mode == .ulw {
            if next["ulw_turns"] == nil {
                next["ulw_turns"] = .number(100)
            }
            if next["ulw_turns_used"] == nil {
                next["ulw_turns_used"] = .number(0)
            }
        } else {
            next.removeValue(forKey: "ulw_turns")
            next.removeValue(forKey: "ulw_turns_used")
        }
        return next
    }

    private func persist() {
        store.save(ChatSnapshot(
            agents: agents,
            conversations: conversations,
            activeAgentID: activeAgentID,
            activeConversationID: activeConversationID
        ))
    }

    private func titleFromPrompt(_ text: String) -> String {
        if text.count > 38 {
            return String(text.prefix(35)) + "..."
        }
        return text
    }
}
