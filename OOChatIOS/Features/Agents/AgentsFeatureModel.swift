import Combine

/// The agent-management UI only depends on this feature surface. `ChatViewModel` remains
/// the single state owner, but unrelated chat delivery and interaction details stay hidden.
@MainActor
protocol AgentsFeatureModel: ObservableObject {
    var agents: [AgentConnection] { get }
    var isConnecting: Bool { get }
    var errorMessage: String? { get }

    func agent(withID id: String) -> AgentConnection?
    func conversations(for agent: AgentConnection) -> [Conversation]
    func searchConversations(_ query: String, for agent: AgentConnection?) -> [Conversation]
    func selectAgent(_ agent: AgentConnection)
    func selectConversation(_ conversation: Conversation)
    func createConversation(for agent: AgentConnection) -> Conversation
    func renameConversation(_ conversation: Conversation, to title: String)
    func deleteConversation(_ conversation: Conversation)
    func deleteAgent(_ agent: AgentConnection)
    func saveAgent(id: String?, name: String, address: String, token: String) -> AgentConnection?
    func connectToAgent() async -> AgentConnection?
    func dismissError()
}

extension ChatViewModel: AgentsFeatureModel {}
