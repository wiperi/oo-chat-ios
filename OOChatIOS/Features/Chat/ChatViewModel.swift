import Foundation
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
    @Published var agentAddressDraft = ""
    @Published var prompt = ""
    @Published private(set) var isOffline = false
    @Published private(set) var isOfflineBannerDismissed = false

    var shouldShowOfflineBanner: Bool {
        isOffline && !isOfflineBannerDismissed
    }

    private(set) var sendTask: Task<Void, Never>?
    private(set) var recoveryTask: Task<Void, Never>?
    private(set) var probeTask: Task<Void, Never>?

    /// Seconds between silent reachability probes while offline. Overridable in tests.
    var probeInterval: TimeInterval = 5

    private let store: ConversationRepository
    private let identityStore: IdentityStore
    private let networkMonitor: NetworkPathMonitoring
    private let injectedClient: HostedAgentTransport?
    private lazy var client: HostedAgentTransport = injectedClient ?? HostedAgentClient(identityStore: identityStore)

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

    init(
        store: ConversationRepository? = nil,
        identityStore: IdentityStore = IdentityStore(),
        client: HostedAgentTransport? = nil,
        networkMonitor: NetworkPathMonitoring? = nil
    ) {
        let store = store ?? ConversationRepositoryFactory.make()
        self.store = store
        self.identityStore = identityStore
        self.injectedClient = client
        self.networkMonitor = networkMonitor ?? NetworkMonitor()
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
        self.networkMonitor.onUpdate = { [weak self] isOnline in
            self?.handleNetworkChange(isOnline: isOnline)
        }
        self.networkMonitor.start()
    }

    deinit {
        networkMonitor.cancel()
        probeTask?.cancel()
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
        persist()
    }

    func selectConversation(_ conversation: Conversation) {
        activeConversationID = conversation.id
        if let agent = agent(for: conversation) {
            activeAgentID = agent.id
            agentAddressDraft = agent.address
        }
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
        store.upsertConversation(conversation)
        persist()
        return conversation
    }

    @discardableResult
    func saveAgent(id: String? = nil, name: String, address: String, token: String) -> AgentConnection? {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        guard HostedAgentClient.isHostedAgentAddress(trimmedAddress) else {
            errorMessage = "That doesn't look like an agent address. It should start with 0x followed by 64 characters."
            return nil
        }
        let existing = id.flatMap(agent(withID:))
        let now = Date()
        let shouldResetSessions = existing.map {
            $0.address != trimmedAddress || $0.token != trimmedToken
        } ?? false
        var next = AgentConnection(
            id: existing?.id ?? UUID().uuidString,
            address: trimmedAddress,
            name: trimmedName.isEmpty ? nil : trimmedName,
            token: trimmedToken,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        next.updatedAt = now

        if let existing {
            for index in conversations.indices where conversationBelongsToAgent(conversations[index], existing) {
                conversations[index].agentID = next.id
                conversations[index].agentAddress = next.address
                if shouldResetSessions {
                    conversations[index].serverSession = nil
                }
                conversations[index].updatedAt = now
                store.upsertConversation(conversations[index])
            }
        }

        agents.removeAll { $0.id == next.id }
        agents.insert(next, at: 0)
        activeAgentID = next.id
        agentAddressDraft = next.address
        errorMessage = nil
        store.upsertAgent(next)
        persist()
        return next
    }

    func switchToAgentForChat(_ agent: AgentConnection) {
        activeAgentID = agent.id
        agentAddressDraft = agent.address
        connectionState = .disconnected
        if let conversation = conversations(for: agent).first {
            activeConversationID = conversation.id
            persist()
        } else {
            _ = createConversation(for: agent)
        }
    }

    func deleteConversation(_ conversation: Conversation) {
        conversations.removeAll { $0.id == conversation.id }
        if activeConversationID == conversation.id {
            if let activeAgent {
                activeConversationID = conversations(for: activeAgent).first?.id
            } else {
                activeConversationID = nil
            }
        }
        store.deleteConversation(id: conversation.id)
        persist()
    }

    func deleteAgent(_ agent: AgentConnection) {
        let deletedConversationIDs = Set(conversations(for: agent).map(\.id))
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
        deletedConversationIDs.forEach { store.deleteConversation(id: $0) }
        store.deleteAgent(id: agent.id)
        persist()
    }

    /// Renames a conversation in place. Empty/whitespace titles and no-op renames are
    /// ignored. A rename is a metadata edit, not activity, so it deliberately does not
    /// reorder the list, bump `updatedAt`, or change the active conversation — only the
    /// title and its persisted row change.
    func renameConversation(_ conversation: Conversation, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == conversation.id }),
              conversations[index].title != trimmed else {
            return
        }
        conversations[index].title = trimmed
        store.upsertConversation(conversations[index])
    }

    /// Filters conversations by title and message content via the store's indexed query,
    /// optionally scoped to a single agent. An empty/whitespace query returns all
    /// conversations (most-recent-first), matching the repository contract.
    func searchConversations(_ query: String, for agent: AgentConnection? = nil) -> [Conversation] {
        let results = store.search(query)
        guard let agent else {
            return results
        }
        return results.filter { conversationBelongsToAgent($0, agent) }
    }

    func setMode(_ mode: ChatMode) {
        guard var conversation = activeConversation else {
            return
        }
        conversation.mode = mode
        conversation.serverSession = session(conversation.serverSession, applying: mode, conversationID: conversation.id)
        upsert(conversation)
    }

    func connectToAgent() async -> AgentConnection? {
        let address = agentAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HostedAgentClient.isHostedAgentAddress(address) else {
            let message = "That doesn't look like an agent address. It should start with 0x followed by 64 characters."
            errorMessage = message
            connectionFailureMessage = message
            return nil
        }
        guard !isOffline else {
            let message = "You appear to be offline. Check your connection and try again."
            errorMessage = message
            connectionFailureMessage = "Connection failed. \(message)"
            return nil
        }
        guard !isConnecting else {
            return nil
        }

        isConnecting = true
        connectionState = .reconnecting
        errorMessage = nil
        connectionFailureMessage = nil

        let agent: AgentConnection
        if let activeAgent, activeAgent.address == address {
            agent = activeAgent
        } else {
            agent = agents.first { $0.address == address } ?? AgentConnection(address: address)
        }
        var conversation = conversations(for: agent).first ?? Conversation(agentID: agent.id, agentAddress: address)

        do {
            let result = try await client.connect(agentAddress: address, conversation: conversation)
            if let session = result.serverSession {
                conversation.serverSession = self.session(session, applying: conversation.mode, conversationID: conversation.id)
            }
            let savedAgent = upsertAgent(agent)
            ensureDefaultConversation(for: savedAgent, seed: conversation)
            connectionState = .connected
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
            errorMessage = "Connect to an agent before sending a message."
            return
        }

        prompt = ""
        errorMessage = nil
        conversation.agentID = agent.id
        conversation.agentAddress = agent.address
        conversation.title = conversation.title == "New mobile session" ? titleFromPrompt(text) : conversation.title
        let message = ChatMessage(role: .user, content: text, deliveryState: .queued)
        conversation.messages.append(message)
        upsert(conversation)

        guard !isOffline else {
            // Stays queued; flushQueuedMessages() sends it when the network returns.
            return
        }

        isProcessing = true
        connectionState = .reconnecting
        sendTask = Task {
            defer {
                self.isProcessing = false
            }
            await self.deliver(messageID: message.id, conversationID: conversation.id)
        }
    }

    func retryMessage(_ message: ChatMessage) {
        guard message.role == .user, message.deliveryState == .failed else {
            return
        }
        guard var conversation = conversations.first(where: { candidate in
            candidate.messages.contains { $0.id == message.id }
        }) else {
            return
        }
        if let index = conversation.messages.firstIndex(where: { $0.id == message.id }) {
            conversation.messages[index].deliveryState = .queued
        }
        errorMessage = nil
        upsert(conversation)

        guard !isOffline, !isProcessing else {
            return
        }
        isProcessing = true
        connectionState = .reconnecting
        sendTask = Task {
            defer {
                self.isProcessing = false
            }
            await self.deliver(messageID: message.id, conversationID: conversation.id)
        }
    }
    
    func flushQueuedMessages() async {
        await sendTask?.value
        guard !isOffline, !isProcessing else {
            return
        }
        let queued = conversations
            .flatMap { conversation in
                conversation.messages
                    .filter { $0.role == .user && $0.deliveryState == .queued }
                    .map { (conversationID: conversation.id, message: $0) }
            }
            .sorted { $0.message.createdAt < $1.message.createdAt }
        guard !queued.isEmpty else {
            return
        }
        isProcessing = true
        defer {
            isProcessing = false
        }
        for item in queued {
            guard !isOffline else {
                break
            }
            await deliver(messageID: item.message.id, conversationID: item.conversationID)
        }
    }

    private func deliver(messageID: String, conversationID: String) async {
        guard let conversation = self.conversation(withID: conversationID),
              let message = conversation.messages.first(where: { $0.id == messageID }),
              message.role == .user,
              let agent = agent(for: conversation),
              HostedAgentClient.isHostedAgentAddress(agent.address) else {
            return
        }
        connectionState = .reconnecting
        var pending = conversation
        pending.messages.append(ChatMessage(role: .thinking, content: "Waiting for hosted agent..."))
        upsert(pending)

        do {
            let result = try await client.sendPrompt(
                agentAddress: agent.address,
                conversation: pending,
                prompt: message.content,
                onEvent: { [weak self] event in
                    self?.apply(event, toConversationID: conversationID)
                }
            )
            var updated = self.conversation(withID: conversationID) ?? pending
            updated.messages.removeAll { $0.role == .thinking }
            if let index = updated.messages.firstIndex(where: { $0.id == messageID }) {
                updated.messages[index].deliveryState = .sent
            }
            if let session = result.serverSession {
                updated.serverSession = self.session(session, applying: updated.mode, conversationID: updated.id)
            }
            updated.messages.append(ChatMessage(role: .agent, content: result.output ?? ""))
            updated.updatedAt = Date()
            connectionState = .connected
            upsert(updated)
        } catch {
            var updated = self.conversation(withID: conversationID) ?? pending
            updated.messages.removeAll { $0.role == .thinking }
            if let index = updated.messages.firstIndex(where: { $0.id == messageID }) {
                updated.messages[index].deliveryState = .failed
            }
            updated.updatedAt = Date()
            errorMessage = error.localizedDescription
            connectionState = .disconnected
            upsert(updated)
        }
    }

    private func handleNetworkChange(isOnline: Bool) {
        let wasOffline = isOffline
        isOffline = !isOnline
        guard isOnline else {
            if !wasOffline {
                // Fresh drop: surface the banner again even if it was dismissed earlier.
                isOfflineBannerDismissed = false
            }
            connectionState = .disconnected
            startRecoveryProbing()
            return
        }
        probeTask?.cancel()
        guard wasOffline else {
            return
        }
        recoveryTask = Task {
            await self.reconnect()
            await self.flushQueuedMessages()
        }
    }

    private func apply(_ event: HostedAgentEvent, toConversationID conversationID: String) {
        guard var conversation = conversation(withID: conversationID) else {
            return
        }

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
        }

        upsert(conversation)
    }

    /// The path monitor can lag well behind the actual network (especially on the
    /// simulator), so while offline we also probe the agent directly on a timer and
    /// recover as soon as a probe gets through — no monitor update or user tap needed.
    private func startRecoveryProbing() {
        probeTask?.cancel()
        probeTask = Task {
            while !Task.isCancelled && self.isOffline {
                try? await Task.sleep(nanoseconds: UInt64(self.probeInterval * 1_000_000_000))
                guard !Task.isCancelled, self.isOffline else {
                    return
                }
                if await self.probeReconnect() {
                    self.isOffline = false
                    self.connectionState = .connected
                    await self.flushQueuedMessages()
                    return
                }
            }
        }
    }

    /// Quiet reachability check. Unlike reconnect(), a failed probe leaves all UI state
    /// untouched so background retries don't flash error banners every few seconds.
    private func probeReconnect() async -> Bool {
        guard let conversation = activeConversation,
              let agent = agent(for: conversation),
              HostedAgentClient.isHostedAgentAddress(agent.address) else {
            return false
        }
        do {
            let result = try await client.connect(agentAddress: agent.address, conversation: conversation)
            if let session = result.serverSession {
                var updated = self.conversation(withID: conversation.id) ?? conversation
                updated.agentID = agent.id
                updated.agentAddress = agent.address
                updated.serverSession = self.session(session, applying: updated.mode, conversationID: updated.id)
                self.upsert(updated)
            }
            return true
        } catch {
            return false
        }
    }

    func dismissOfflineBanner() {
        isOfflineBannerDismissed = true
    }

    /// Manual recovery for when the path monitor is slow to notice the network is back
    /// (common on the simulator): attempt a real reconnect, and if it succeeds treat
    /// the app as online again and flush the queue without waiting for the monitor.
    func retryConnectivity() {
        guard isOffline else {
            return
        }
        recoveryTask = Task {
            await self.reconnect()
            if self.connectionState == .connected {
                self.isOffline = false
                await self.flushQueuedMessages()
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
            let result = try await client.connect(agentAddress: agent.address, conversation: conversation)
            if let session = result.serverSession {
                var updated = self.conversation(withID: conversation.id) ?? conversation
                updated.agentID = agent.id
                updated.agentAddress = agent.address
                updated.serverSession = self.session(session, applying: updated.mode, conversationID: updated.id)
                self.upsert(updated)
            }
            connectionState = .connected
        } catch {
            connectionState = .disconnected
            errorMessage = error.localizedDescription
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    private func upsertAgent(_ agent: AgentConnection) -> AgentConnection {
        var next = agent
        next.name = next.name.isEmpty ? AgentConnection.defaultName(for: next.address) : next.name
        next.updatedAt = Date()
        agents.removeAll { $0.id == next.id }
        agents.insert(next, at: 0)
        activeAgentID = next.id
        agentAddressDraft = next.address
        store.upsertAgent(next)
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
        store.upsertConversation(conversation)
        persist()
    }

    private func upsert(_ conversation: Conversation) {
        var next = conversation
        next.updatedAt = Date()
        if let agent = agent(for: next) {
            next.agentID = agent.id
            next.agentAddress = agent.address
            touchAgent(id: agent.id)
            if let touched = self.agent(withID: agent.id) {
                store.upsertAgent(touched)
            }
        }
        conversations.removeAll { $0.id == next.id }
        conversations.insert(next, at: 0)
        activeConversationID = next.id
        store.upsertConversation(next)
        persist()
    }

    private func touchAgent(id: String) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else {
            return
        }
        var agent = agents.remove(at: index)
        agent.updatedAt = Date()
        agents.insert(agent, at: 0)
        activeAgentID = agent.id
        agentAddressDraft = agent.address
    }

    private func agent(for conversation: Conversation) -> AgentConnection? {
        if let agentID = conversation.agentID, let agent = agent(withID: agentID) {
            return agent
        }
        if conversation.agentID != nil {
            return nil
        }
        return agents.first { $0.address == conversation.agentAddress }
    }

    private func conversationBelongsToAgent(_ conversation: Conversation, _ agent: AgentConnection) -> Bool {
        if let agentID = conversation.agentID {
            return agentID == agent.id
        }
        return conversation.agentAddress == agent.address
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
        store.saveActive(agentID: activeAgentID, conversationID: activeConversationID)
    }

    private func titleFromPrompt(_ text: String) -> String {
        if text.count > 38 {
            return String(text.prefix(35)) + "..."
        }
        return text
    }
}
