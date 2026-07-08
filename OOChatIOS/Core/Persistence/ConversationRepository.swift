import Foundation

protocol ConversationRepository {
    func load() -> ChatSnapshot
    func save(_ snapshot: ChatSnapshot)

    func upsertConversation(_ conversation: Conversation)
    func deleteConversation(id: String)
    func upsertAgent(_ agent: AgentConnection)
    func deleteAgent(id: String)
    func saveActive(agentID: String?, conversationID: String?)
    func search(_ query: String) -> [Conversation]
}

extension ConversationRepository {
    func upsertConversation(_ conversation: Conversation) {
        var snapshot = load()
        snapshot.conversations.removeAll { $0.id == conversation.id }
        snapshot.conversations.insert(conversation, at: 0)
        save(snapshot)
    }

    func deleteConversation(id: String) {
        var snapshot = load()
        snapshot.conversations.removeAll { $0.id == id }
        if snapshot.activeConversationID == id {
            snapshot.activeConversationID = nil
        }
        save(snapshot)
    }

    func upsertAgent(_ agent: AgentConnection) {
        var snapshot = load()
        snapshot.agents.removeAll { $0.id == agent.id }
        snapshot.agents.insert(agent, at: 0)
        save(snapshot)
    }

    func deleteAgent(id: String) {
        var snapshot = load()
        let removedConversationIDs = Set(snapshot.conversations.filter { $0.agentID == id }.map(\.id))
        snapshot.agents.removeAll { $0.id == id }
        snapshot.conversations.removeAll { $0.agentID == id }
        if snapshot.activeAgentID == id {
            snapshot.activeAgentID = nil
        }
        if let active = snapshot.activeConversationID, removedConversationIDs.contains(active) {
            snapshot.activeConversationID = nil
        }
        save(snapshot)
    }

    func saveActive(agentID: String?, conversationID: String?) {
        var snapshot = load()
        snapshot.activeAgentID = agentID
        snapshot.activeConversationID = conversationID
        save(snapshot)
    }

    func search(_ query: String) -> [Conversation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let conversations = load().conversations
        guard !needle.isEmpty else { return conversations }
        return conversations.filter { conversation in
            conversation.title.lowercased().contains(needle)
                || conversation.messages.contains { $0.content.lowercased().contains(needle) }
        }
    }
}
