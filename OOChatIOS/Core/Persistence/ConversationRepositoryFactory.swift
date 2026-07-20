import Foundation

enum ConversationRepositoryFactory {
    /// The repository to use plus the error, if any, that forced a downgrade away from the
    /// on-disk store. Callers surface the error so the user learns their chats are not being
    /// saved instead of silently losing them.
    struct Outcome {
        let repository: ConversationRepository
        let error: Error?
    }

    @MainActor
    static func make(defaults: UserDefaults = .standard) -> ConversationRepository {
        makeOutcome(defaults: defaults).repository
    }

    /// A store that cannot be opened must never be fatal: crashing here means crashing on
    /// every launch, and the only escape a user has is deleting the app along with all of
    /// their data. Degrade to a memory-backed store for this session instead.
    @MainActor
    static func makeOutcome(defaults: UserDefaults = .standard) -> Outcome {
        do {
            let repository = try SwiftDataConversationRepository(defaults: defaults)
            return Outcome(repository: repository, error: nil)
        } catch {
            if let inMemory = try? SwiftDataConversationRepository(inMemory: true, defaults: defaults) {
                return Outcome(repository: inMemory, error: error)
            }
            return Outcome(repository: EphemeralConversationRepository(), error: error)
        }
    }
}

/// Last-resort repository for when even an in-memory SwiftData container cannot be built.
/// Keeps the app usable for the current session; nothing it holds survives relaunch.
@MainActor
final class EphemeralConversationRepository: ConversationRepository {
    private var agents: [AgentConnection] = []
    private var conversations: [Conversation] = []
    private var activeAgentID: String?
    private var activeConversationID: String?

    func load() -> ChatSnapshot {
        ChatSnapshot(
            agents: agents,
            conversations: conversations,
            activeAgentID: activeAgentID,
            activeConversationID: activeConversationID
        )
    }

    func upsertConversation(_ conversation: Conversation) {
        conversations.removeAll { $0.id == conversation.id }
        conversations.insert(conversation, at: 0)
    }

    func deleteConversation(id: String) {
        conversations.removeAll { $0.id == id }
    }

    func upsertAgent(_ agent: AgentConnection) {
        agents.removeAll { $0.id == agent.id }
        agents.insert(agent, at: 0)
    }

    func deleteAgent(id: String) {
        agents.removeAll { $0.id == id }
        conversations.removeAll { $0.agentID == id }
    }

    func saveActive(agentID: String?, conversationID: String?) {
        activeAgentID = agentID
        activeConversationID = conversationID
    }

    func search(_ query: String) -> [Conversation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return conversations
        }
        return conversations.filter { conversation in
            conversation.title.localizedStandardContains(needle)
                || conversation.messages.contains { $0.content.localizedStandardContains(needle) }
        }
    }
}
