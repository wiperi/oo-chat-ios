import XCTest
@testable import OOChatIOS

@MainActor
final class AgentsFeatureTests: XCTestCase {
    // Make sure ViewModel can read agents from repo.
    func testLoadAgentsActiveSelectionFromRepo() {
        let first = makeAgent(id: "agent1", address: "0xaaa", updatedAt: seconds(1000))
        let second = makeAgent(id: "agent2", address: "0xbbb", updatedAt: seconds(2000))
        let repo = SpyConversationRepository(
            snapshot: ChatSnapshot(
                agents: [second, first],
                conversations: [],
                activeAgentID: first.id,
                activeConversationID: nil
            )
        )

        let view = ChatViewModel(store: repo)

        XCTAssertEqual(view.agents.map(\.id), [second.id, first.id])
        XCTAssertEqual(view.activeAgentID, first.id)
        XCTAssertEqual(view.agentAddressDraft, first.address)
    }

    // Mock user choose second agent and test switch conversation.
    func testSelectAgentActivatesItsMostRecentCon() {
        let first = makeAgent(id: "agent1", address: "0xaaa", updatedAt: seconds(1000))
        let second = makeAgent(id: "agent2", address: "0xbbb", updatedAt: seconds(2000))
        let firstCon = makeConversation(
            id: "con1",
            agent: first,
            updatedAt: seconds(1000)
        )
        let oldSecondCon = makeConversation(
            id: "con2",
            agent: second,
            updatedAt: seconds(2000)
        )
        let newSecondCon = makeConversation(
            id: "con3",
            agent: second,
            updatedAt: seconds(3000)
        )
        let repo = SpyConversationRepository(
            snapshot: ChatSnapshot(
                agents: [first, second],
                conversations: [
                    firstCon,
                    oldSecondCon,
                    newSecondCon,
                ],
                activeAgentID: first.id,
                activeConversationID: firstCon.id
            )
        )
        let view = ChatViewModel(store: repo)

        view.selectAgent(second)

        XCTAssertEqual(view.activeAgentID, second.id)
        XCTAssertEqual(view.activeConversationID, newSecondCon.id)
        XCTAssertEqual(view.agentAddressDraft, second.address)
        XCTAssertEqual(
            repo.savedActiveCalls.last,
            SavedActive(agentID: second.id, conversationID: newSecondCon.id)
        )
    }

    // Make sure conversation list order is right.
    func testConForAgentFiltersAndSortsNewestFirst() {
        let first = makeAgent(id: "agent1", address: "0xaaa", updatedAt: seconds(1000))
        let second = makeAgent(id: "agent2", address: "0xbbb", updatedAt: seconds(2000))
        let old = makeConversation(id: "old", agent: first, updatedAt: seconds(1000))
        let new = makeConversation(id: "new", agent: first, updatedAt: seconds(3000))
        let hhh = makeConversation(id: "hhh", agent: second, updatedAt: seconds(4000))
        let repo = SpyConversationRepository(
            snapshot: ChatSnapshot(
                agents: [first, second],
                conversations: [old, hhh, new],
                activeAgentID: first.id,
                activeConversationID: old.id
            )
        )
        let view = ChatViewModel(store: repo)

        let conversations = view.conversations(for: first)

        XCTAssertEqual(conversations.map(\.id), [new.id, old.id])
    }

    // Make sure click new chat will open a new chat view.
    func testCreateConMakesAgentAndConActive() {
        let agent = makeAgent(id: "agent1", address: "0xaaa", updatedAt: seconds(1000))
        let repo = SpyConversationRepository(
            snapshot: ChatSnapshot(
                agents: [agent],
                conversations: [],
                activeAgentID: agent.id,
                activeConversationID: nil
            )
        )
        let view = ChatViewModel(store: repo)

        let conversation = view.createConversation(for: agent)

        XCTAssertEqual(conversation.agentID, agent.id)
        XCTAssertEqual(conversation.agentAddress, agent.address)
        XCTAssertEqual(conversation.title, "New mobile session")
        XCTAssertEqual(view.activeAgentID, agent.id)
        XCTAssertEqual(view.activeConversationID, conversation.id)
        XCTAssertEqual(repo.upsertedConversations.last?.id, conversation.id)
        XCTAssertEqual(
            repo.savedActiveCalls.last,
            SavedActive(agentID: agent.id, conversationID: conversation.id)
        )
    }

    // Mock delete current conversation delete, the chat also deletes.
    func testDeleteActiveAgentRemovesConAndSelectRemainAgent() {
        let deletedAgent = makeAgent(id: "agent1", address: "0xaaa", updatedAt: seconds(2000))
        let remainingAgent = makeAgent(id: "agent2", address: "0xbbb", updatedAt: seconds(1000))
        let deletedConversation = makeConversation(
            id: "conversation1",
            agent: deletedAgent,
            updatedAt: seconds(2000)
        )
        let remainingConversation = makeConversation(
            id: "conversation2",
            agent: remainingAgent,
            updatedAt: seconds(1000)
        )
        let repo = SpyConversationRepository(
            snapshot: ChatSnapshot(
                agents: [deletedAgent, remainingAgent],
                conversations: [deletedConversation, remainingConversation],
                activeAgentID: deletedAgent.id,
                activeConversationID: deletedConversation.id
            )
        )
        let view = ChatViewModel(store: repo)

        view.deleteAgent(deletedAgent)

        XCTAssertEqual(view.agents.map(\.id), [remainingAgent.id])
        XCTAssertEqual(view.conversations.map(\.id), [remainingConversation.id])
        XCTAssertEqual(view.activeAgentID, remainingAgent.id)
        XCTAssertEqual(view.activeConversationID, remainingConversation.id)
        XCTAssertEqual(view.agentAddressDraft, remainingAgent.address)
        XCTAssertEqual(repo.deletedAgentIDs, [deletedAgent.id])
        XCTAssertEqual(repo.deletedConversationIDs, [deletedConversation.id])
    }

    // Test invalid agent address is failed to connect.
    func testInvalidAgentAddressFailedConnect() async {
        let repo = SpyConversationRepository(snapshot: .empty)
        let view = ChatViewModel(store: repo)
        view.agentAddressDraft = "not-an-agent-address"

        let result = await view.connectToAgent()

        XCTAssertNil(result)
        XCTAssertFalse(view.isConnecting)
        XCTAssertNotNil(view.errorMessage)
        XCTAssertNotNil(view.connectionFailureMessage)
        XCTAssertTrue(repo.upsertedAgents.isEmpty)
    }

    private func makeAgent(id: String, address: String, updatedAt: Date) -> AgentConnection {
        AgentConnection(
            id: id,
            address: address,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }

    private func makeConversation(
        id: String,
        agent: AgentConnection,
        updatedAt: Date
    ) -> Conversation {
        Conversation(
            id: id,
            title: id,
            agentID: agent.id,
            agentAddress: agent.address,
            mode: .safe,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            messages: [],
            serverSession: nil
        )
    }

    private func seconds(_ value: TimeInterval) -> Date {
        Date(timeIntervalSince1970: value)
    }
}

private struct SavedActive: Equatable {
    let agentID: String?
    let conversationID: String?
}

@MainActor
private final class SpyConversationRepository: ConversationRepository {
    let snapshot: ChatSnapshot
    private(set) var upsertedConversations: [Conversation] = []
    private(set) var deletedConversationIDs: [String] = []
    private(set) var upsertedAgents: [AgentConnection] = []
    private(set) var deletedAgentIDs: [String] = []
    private(set) var savedActiveCalls: [SavedActive] = []

    init(snapshot: ChatSnapshot) {
        self.snapshot = snapshot
    }

    func load() -> ChatSnapshot {
        snapshot
    }

    func upsertConversation(_ conversation: Conversation) {
        upsertedConversations.append(conversation)
    }

    func deleteConversation(id: String) {
        deletedConversationIDs.append(id)
    }

    func upsertAgent(_ agent: AgentConnection) {
        upsertedAgents.append(agent)
    }

    func deleteAgent(id: String) {
        deletedAgentIDs.append(id)
    }

    func saveActive(agentID: String?, conversationID: String?) {
        savedActiveCalls.append(
            SavedActive(agentID: agentID, conversationID: conversationID)
        )
    }

    func search(_ query: String) -> [Conversation] {
        []
    }
}
