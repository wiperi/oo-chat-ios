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

    private let store: ConversationRepository
    private let identityStore = IdentityStore()
    private lazy var client = HostedAgentClient(identityStore: identityStore)

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

    init(store: ConversationRepository = ConversationStore()) {
        self.store = store
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
        persist()
        return conversation
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
        persist()
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
            errorMessage = "Use a hosted agent address before sending a message."
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
                let result = try await client.sendPrompt(agentAddress: agent.address, conversation: conversation, prompt: text)
                var updated = self.conversation(withID: conversation.id) ?? conversation
                updated.messages.removeAll { $0.role == .thinking }
                if let session = result.serverSession {
                    updated.serverSession = self.session(session, applying: updated.mode, conversationID: updated.id)
                }
                updated.messages.append(ChatMessage(role: .agent, content: result.output ?? ""))
                updated.updatedAt = Date()
                self.connectionState = .connected
                self.upsert(updated)
            } catch {
                var updated = self.conversation(withID: conversation.id) ?? conversation
                updated.messages.removeAll { $0.role == .thinking }
                updated.messages.append(ChatMessage(role: .error, content: error.localizedDescription))
                updated.updatedAt = Date()
                self.errorMessage = error.localizedDescription
                self.connectionState = .disconnected
                self.upsert(updated)
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
        var next = conversation
        next.updatedAt = Date()
        if let agent = agent(for: next) {
            next.agentID = agent.id
            next.agentAddress = agent.address
            touchAgent(id: agent.id)
        }
        conversations.removeAll { $0.id == next.id }
        conversations.insert(next, at: 0)
        activeConversationID = next.id
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
