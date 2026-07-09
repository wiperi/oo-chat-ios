import Foundation

/// Persistence boundary for chat state. Reads hydrate the in-memory model once at launch
/// (`load`); every mutation is a granular, single-row write. `search` runs as an indexed
/// query against the store rather than filtering the in-memory list.
///
/// `@MainActor`-isolated: the sole caller is the main-actor `ChatViewModel`, and the
/// implementation keeps a single non-thread-safe `ModelContext`, so isolation is enforced
/// at compile time rather than left as a "happens to be safe" assumption.
@MainActor
protocol ConversationRepository {
    func load() -> ChatSnapshot

    func upsertConversation(_ conversation: Conversation)
    func deleteConversation(id: String)
    func upsertAgent(_ agent: AgentConnection)
    func deleteAgent(id: String)
    func saveActive(agentID: String?, conversationID: String?)
    func search(_ query: String) -> [Conversation]
}
