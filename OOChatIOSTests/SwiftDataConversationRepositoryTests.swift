import XCTest
@testable import OOChatIOS

final class SwiftDataConversationRepositoryTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeRepository() throws -> SwiftDataConversationRepository {
        try SwiftDataConversationRepository(inMemory: true, defaults: defaults)
    }

    func testLoadReturnsEmptyWhenNothingStored() throws {
        let repository = try makeRepository()

        XCTAssertEqual(repository.load(), .empty)
    }

    func testSaveThenLoadRestoresAgentsConversationsAndActiveIDs() throws {
        let repository = try makeRepository()
        let agent = AgentConnection(address: "0xabc", createdAt: seconds(1000), updatedAt: seconds(1000))
        let conversation = makeConversation(agentID: agent.id, address: agent.address, title: "Hello", updatedAt: seconds(1000))
        let snapshot = ChatSnapshot(
            agents: [agent],
            conversations: [conversation],
            activeAgentID: agent.id,
            activeConversationID: conversation.id
        )

        repository.save(snapshot)
        let loaded = repository.load()

        XCTAssertEqual(loaded.agents.map(\.id), [agent.id])
        XCTAssertEqual(loaded.conversations.map(\.id), [conversation.id])
        XCTAssertEqual(loaded.conversations.first?.title, "Hello")
        XCTAssertEqual(loaded.conversations.first?.messages.map(\.content), conversation.messages.map(\.content))
        XCTAssertEqual(loaded.activeAgentID, agent.id)
        XCTAssertEqual(loaded.activeConversationID, conversation.id)
    }

    func testSavePreservesConversationModeAndServerSession() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(agentID: "a1", address: "0xabc", title: "t", updatedAt: seconds(1000))
        conversation.mode = .ulw
        conversation.serverSession = ["session_id": .string("s1"), "ulw_turns": .number(100)]
        repository.save(ChatSnapshot(agents: [], conversations: [conversation], activeAgentID: nil, activeConversationID: nil))

        let loaded = repository.load().conversations.first

        XCTAssertEqual(loaded?.mode, .ulw)
        XCTAssertEqual(loaded?.serverSession?["session_id"]?.stringValue, "s1")
    }

    func testSaveRemovesDeletedConversations() throws {
        let repository = try makeRepository()
        let keep = makeConversation(agentID: "a1", address: "0xaaa", title: "keep", updatedAt: seconds(2000))
        let drop = makeConversation(agentID: "a1", address: "0xaaa", title: "drop", updatedAt: seconds(1000))
        repository.save(ChatSnapshot(agents: [], conversations: [keep, drop], activeAgentID: nil, activeConversationID: nil))

        repository.save(ChatSnapshot(agents: [], conversations: [keep], activeAgentID: nil, activeConversationID: nil))
        let loaded = repository.load()

        XCTAssertEqual(loaded.conversations.map(\.id), [keep.id])
    }

    func testSaveUpdatesExistingConversationInPlace() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(agentID: "a1", address: "0xaaa", title: "before", updatedAt: seconds(1000))
        repository.save(ChatSnapshot(agents: [], conversations: [conversation], activeAgentID: nil, activeConversationID: nil))

        conversation.title = "after"
        conversation.messages.append(ChatMessage(role: .user, content: "hi"))
        repository.save(ChatSnapshot(agents: [], conversations: [conversation], activeAgentID: nil, activeConversationID: nil))
        let loaded = repository.load()

        XCTAssertEqual(loaded.conversations.count, 1)
        XCTAssertEqual(loaded.conversations.first?.title, "after")
        XCTAssertEqual(loaded.conversations.first?.messages.last?.content, "hi")
    }

    private func seconds(_ value: TimeInterval) -> Date {
        Date(timeIntervalSince1970: value)
    }

    private func makeConversation(agentID: String?, address: String, title: String, updatedAt: Date) -> Conversation {
        var conversation = Conversation(agentID: agentID, agentAddress: address)
        conversation.title = title
        conversation.createdAt = updatedAt
        conversation.updatedAt = updatedAt
        return conversation
    }
}
