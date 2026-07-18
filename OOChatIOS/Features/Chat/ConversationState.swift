import Combine
import Foundation

enum ConversationPersistence {
    case full
    case message(id: String)
    case metadata
}

@MainActor
final class ConversationState: ObservableObject {
    @Published private(set) var agents: [AgentConnection]
    @Published private(set) var conversations: [Conversation]
    @Published private(set) var activeAgentID: String?
    @Published private(set) var activeConversationID: String?
    @Published private(set) var persistenceError: ConversationRepositoryError?

    private var draftsByConversationID: [String: String] = [:]
    private let store: ConversationRepository

    init(store: ConversationRepository) {
        self.store = store

        let snapshotResult = store.loadResult()
        let snapshot = (try? snapshotResult.get()) ?? .empty
        agents = snapshot.agents
        conversations = snapshot.conversations
        activeConversationID = snapshot.activeConversationID

        let activeConversationAgentID = snapshot.activeConversationID.flatMap { activeConversationID in
            snapshot.conversations.first { $0.id == activeConversationID }?.agentID
        }
        activeAgentID = snapshot.activeAgentID
            ?? activeConversationAgentID
            ?? snapshot.agents.first?.id

        if case .failure(let error) = snapshotResult {
            persistenceError = error
        }
    }

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
        return conversation(withID: activeConversationID)
    }

    var activeDraft: String {
        guard let activeConversationID else {
            return ""
        }
        return draftsByConversationID[activeConversationID] ?? ""
    }

    func updateActiveDraft(_ draft: String) {
        guard let activeConversationID else {
            return
        }
        draftsByConversationID[activeConversationID] = draft
    }

    func agent(withID id: String) -> AgentConnection? {
        agents.first { $0.id == id }
    }

    func conversation(withID id: String) -> Conversation? {
        conversations.first { $0.id == id }
    }

    func replaceConversations(_ conversations: [Conversation]) {
        self.conversations = conversations
    }

    func conversations(for agent: AgentConnection) -> [Conversation] {
        conversations
            .filter { conversationBelongsToAgent($0, agent) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func selectAgent(_ agent: AgentConnection, currentDraft: String) {
        updateActiveDraft(currentDraft)
        activeAgentID = agent.id

        if let activeConversation, !conversationBelongsToAgent(activeConversation, agent) {
            activeConversationID = conversations(for: agent).first?.id
        } else if activeConversation == nil {
            activeConversationID = conversations(for: agent).first?.id
        }
        persistSelection()
    }

    func selectConversation(_ conversation: Conversation, currentDraft: String) {
        updateActiveDraft(currentDraft)
        activeConversationID = conversation.id
        if let agent = agent(for: conversation) {
            activeAgentID = agent.id
        }
        persistSelection()
    }

    func createConversation(for agent: AgentConnection, currentDraft: String) -> Conversation {
        updateActiveDraft(currentDraft)
        var conversation = Conversation(agentID: agent.id, agentAddress: agent.address)
        conversation.title = "New mobile session"
        conversations.insert(conversation, at: 0)
        activeAgentID = agent.id
        activeConversationID = conversation.id
        recordPersistence(store.upsertConversationResult(conversation))
        persistSelection()
        return conversation
    }

    func saveAgent(
        id: String?,
        name: String,
        address: String,
        token: String
    ) -> AgentConnection {
        let existing = id.flatMap(agent(withID:))
        let now = Date()
        let shouldResetSessions = existing.map {
            $0.address != address || $0.token != token
        } ?? false
        var next = AgentConnection(
            id: existing?.id ?? UUID().uuidString,
            address: address,
            name: name.isEmpty ? nil : name,
            token: token,
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
                recordPersistence(store.upsertConversationResult(conversations[index]))
            }
        }

        agents.removeAll { $0.id == next.id }
        agents.insert(next, at: 0)
        activeAgentID = next.id
        recordPersistence(store.upsertAgentResult(next))
        persistSelection()
        return next
    }

    func deleteConversation(_ conversation: Conversation, currentDraft: String) {
        updateActiveDraft(currentDraft)
        conversations.removeAll { $0.id == conversation.id }
        if activeConversationID == conversation.id {
            if let activeAgent {
                activeConversationID = conversations(for: activeAgent).first?.id
            } else {
                activeConversationID = nil
            }
        }
        draftsByConversationID[conversation.id] = nil
        recordPersistence(store.deleteConversationResult(id: conversation.id))
        persistSelection()
    }

    func deleteAgent(_ agent: AgentConnection, currentDraft: String) {
        updateActiveDraft(currentDraft)
        let deletedConversationIDs = Set(conversations(for: agent).map(\.id))
        agents.removeAll { $0.id == agent.id }
        conversations.removeAll { conversationBelongsToAgent($0, agent) }

        if activeAgentID == agent.id {
            activeAgentID = agents.first?.id
        }
        if let activeConversationID, deletedConversationIDs.contains(activeConversationID) {
            if let activeAgent {
                self.activeConversationID = conversations(for: activeAgent).first?.id
            } else {
                self.activeConversationID = nil
            }
        }

        for conversationID in deletedConversationIDs {
            draftsByConversationID[conversationID] = nil
            recordPersistence(store.deleteConversationResult(id: conversationID))
        }
        recordPersistence(store.deleteAgentResult(id: agent.id))
        persistSelection()
    }

    func renameConversation(_ conversation: Conversation, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == conversation.id }),
              conversations[index].title != trimmed else {
            return
        }
        conversations[index].title = trimmed
        recordPersistence(store.upsertConversationResult(conversations[index]))
    }

    func searchConversations(_ query: String, for agent: AgentConnection? = nil) -> [Conversation] {
        let results: [Conversation]
        switch store.searchResult(query) {
        case .success(let conversations):
            results = conversations
        case .failure(let error):
            persistenceError = error
            results = []
        }
        guard let agent else {
            return results
        }
        return results.filter { conversationBelongsToAgent($0, agent) }
    }

    func upsertAgent(_ agent: AgentConnection) -> AgentConnection {
        var next = agent
        next.name = next.name.isEmpty ? AgentConnection.defaultName(for: next.address) : next.name
        next.updatedAt = Date()
        agents.removeAll { $0.id == next.id }
        agents.insert(next, at: 0)
        activeAgentID = next.id
        recordPersistence(store.upsertAgentResult(next))
        persistSelection()
        return next
    }

    func ensureDefaultConversation(
        for agent: AgentConnection,
        seed: Conversation,
        currentDraft: String
    ) {
        updateActiveDraft(currentDraft)
        if var existing = conversations(for: agent).first {
            if let session = seed.serverSession {
                existing.serverSession = session
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
        recordPersistence(store.upsertConversationResult(conversation))
        persistSelection()
    }

    func upsert(
        _ conversation: Conversation,
        persistence: ConversationPersistence = .full
    ) {
        var next = conversation
        next.updatedAt = Date()
        if let agent = agent(for: next) {
            next.agentID = agent.id
            next.agentAddress = agent.address
            touchAgent(id: agent.id)
            if let touched = self.agent(withID: agent.id) {
                recordPersistence(store.upsertAgentResult(touched))
            }
        }
        conversations.removeAll { $0.id == next.id }
        conversations.insert(next, at: 0)

        switch persistence {
        case .full:
            recordPersistence(store.upsertConversationResult(next))
        case .message(let id):
            guard let message = next.messages.first(where: { $0.id == id }) else {
                recordPersistence(store.upsertConversationResult(next))
                persistSelection()
                return
            }
            recordPersistence(store.upsertMessageResult(message, in: next))
        case .metadata:
            recordPersistence(store.updateConversationMetadataResult(next))
        }
        persistSelection()
    }

    func agent(for conversation: Conversation) -> AgentConnection? {
        if let agentID = conversation.agentID, let agent = agent(withID: agentID) {
            return agent
        }
        if conversation.agentID != nil {
            return nil
        }
        return agents.first { $0.address == conversation.agentAddress }
    }

    func conversationBelongsToAgent(_ conversation: Conversation, _ agent: AgentConnection) -> Bool {
        if let agentID = conversation.agentID {
            return agentID == agent.id
        }
        return conversation.agentAddress == agent.address
    }

    private func touchAgent(id: String) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else {
            return
        }
        var agent = agents.remove(at: index)
        agent.updatedAt = Date()
        agents.insert(agent, at: 0)
    }

    private func persistSelection() {
        store.saveActive(agentID: activeAgentID, conversationID: activeConversationID)
    }

    private func recordPersistence(_ result: Result<Void, ConversationRepositoryError>) {
        if case .failure(let error) = result {
            persistenceError = error
        }
    }
}
