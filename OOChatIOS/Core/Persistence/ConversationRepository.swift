import Foundation

struct ConversationRepositoryError: LocalizedError {
    enum Operation: String {
        case load = "load your conversations"
        case saveConversation = "save the conversation"
        case deleteConversation = "delete the conversation"
        case saveAgent = "save the agent"
        case deleteAgent = "delete the agent"
        case search = "search conversations"
    }

    let operation: Operation
    let underlyingError: Error

    var errorDescription: String? {
        "Couldn’t \(operation.rawValue). \(underlyingError.localizedDescription)"
    }
}

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

    /// Result-returning variants let feature code surface persistence failures while the
    /// compatibility methods above keep existing callers source-compatible during migration.
    func loadResult() -> Result<ChatSnapshot, ConversationRepositoryError>
    func upsertConversationResult(_ conversation: Conversation) -> Result<Void, ConversationRepositoryError>
    func deleteConversationResult(id: String) -> Result<Void, ConversationRepositoryError>
    func upsertAgentResult(_ agent: AgentConnection) -> Result<Void, ConversationRepositoryError>
    func deleteAgentResult(id: String) -> Result<Void, ConversationRepositoryError>
    func searchResult(_ query: String) -> Result<[Conversation], ConversationRepositoryError>
}

extension ConversationRepository {
    func loadResult() -> Result<ChatSnapshot, ConversationRepositoryError> {
        .success(load())
    }

    func upsertConversationResult(_ conversation: Conversation) -> Result<Void, ConversationRepositoryError> {
        upsertConversation(conversation)
        return .success(())
    }

    func deleteConversationResult(id: String) -> Result<Void, ConversationRepositoryError> {
        deleteConversation(id: id)
        return .success(())
    }

    func upsertAgentResult(_ agent: AgentConnection) -> Result<Void, ConversationRepositoryError> {
        upsertAgent(agent)
        return .success(())
    }

    func deleteAgentResult(id: String) -> Result<Void, ConversationRepositoryError> {
        deleteAgent(id: id)
        return .success(())
    }

    func searchResult(_ query: String) -> Result<[Conversation], ConversationRepositoryError> {
        .success(search(query))
    }
}
