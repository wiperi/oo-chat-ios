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
