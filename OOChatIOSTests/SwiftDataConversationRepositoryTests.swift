import XCTest
@testable import OOChatIOS

@MainActor
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

    func testUpsertsThenLoadRestoresAgentsConversationsAndActiveIDs() throws {
        let repository = try makeRepository()
        let agent = AgentConnection(address: "0xabc", createdAt: seconds(1000), updatedAt: seconds(1000))
        let conversation = makeConversation(agentID: agent.id, address: agent.address, title: "Hello", updatedAt: seconds(1000))

        repository.upsertAgent(agent)
        repository.upsertConversation(conversation)
        repository.saveActive(agentID: agent.id, conversationID: conversation.id)
        let loaded = repository.load()

        XCTAssertEqual(loaded.agents.map(\.id), [agent.id])
        XCTAssertEqual(loaded.conversations.map(\.id), [conversation.id])
        XCTAssertEqual(loaded.conversations.first?.title, "Hello")
        XCTAssertEqual(loaded.conversations.first?.messages.map(\.content), conversation.messages.map(\.content))
        XCTAssertEqual(loaded.activeAgentID, agent.id)
        XCTAssertEqual(loaded.activeConversationID, conversation.id)
    }

    func testUpsertPreservesConversationModeAndServerSession() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(agentID: "a1", address: "0xabc", title: "t", updatedAt: seconds(1000))
        conversation.mode = .ulw
        conversation.serverSession = ["session_id": .string("s1"), "ulw_turns": .number(100)]
        repository.upsertConversation(conversation)

        let loaded = repository.load().conversations.first

        XCTAssertEqual(loaded?.mode, .ulw)
        XCTAssertEqual(loaded?.serverSession?["session_id"]?.stringValue, "s1")
    }

    func testUpsertConversationInsertsThenUpdatesOneRow() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(agentID: "a1", address: "0xaaa", title: "before", updatedAt: seconds(1000))
        repository.upsertConversation(conversation)

        conversation.title = "after"
        repository.upsertConversation(conversation)
        let loaded = repository.load()

        XCTAssertEqual(loaded.conversations.count, 1)
        XCTAssertEqual(loaded.conversations.first?.title, "after")
    }

    func testDeleteConversationRemovesOnlyThatConversation() throws {
        let repository = try makeRepository()
        let keep = makeConversation(agentID: "a1", address: "0xaaa", title: "keep", updatedAt: seconds(2000))
        let drop = makeConversation(agentID: "a1", address: "0xaaa", title: "drop", updatedAt: seconds(1000))
        repository.upsertConversation(keep)
        repository.upsertConversation(drop)

        repository.deleteConversation(id: drop.id)
        let loaded = repository.load()

        XCTAssertEqual(loaded.conversations.map(\.id), [keep.id])
    }

    func testDeleteAgentAlsoRemovesItsConversations() throws {
        let repository = try makeRepository()
        let agent = AgentConnection(address: "0xaaa")
        repository.upsertAgent(agent)
        let conversation = makeConversation(agentID: agent.id, address: agent.address, title: "c", updatedAt: seconds(1000))
        repository.upsertConversation(conversation)

        repository.deleteAgent(id: agent.id)
        let loaded = repository.load()

        XCTAssertTrue(loaded.agents.isEmpty)
        XCTAssertTrue(loaded.conversations.isEmpty)
    }

    func testDeleteAgentKeepsSiblingAgentSharingSameAddress() throws {
        let repository = try makeRepository()
        // Two distinct agents on the same address (different tokens/configs).
        let a = AgentConnection(id: "a1", address: "0xaaa")
        let b = AgentConnection(id: "a2", address: "0xaaa")
        repository.upsertAgent(a)
        repository.upsertAgent(b)
        let convA = makeConversation(agentID: a.id, address: "0xaaa", title: "belongs to a", updatedAt: seconds(1000))
        let convB = makeConversation(agentID: b.id, address: "0xaaa", title: "belongs to b", updatedAt: seconds(2000))
        repository.upsertConversation(convA)
        repository.upsertConversation(convB)

        repository.deleteAgent(id: a.id)
        let loaded = repository.load()

        // Only agent a and its conversation go; the sibling on the same address survives.
        XCTAssertEqual(loaded.agents.map(\.id), [b.id])
        XCTAssertEqual(loaded.conversations.map(\.id), [convB.id])
    }

    func testAgentTokenRoundTrips() throws {
        let repository = try makeRepository()
        let agent = AgentConnection(id: "a1", address: "0xaaa", name: "Primary", token: "secret-token")
        repository.upsertAgent(agent)

        XCTAssertEqual(repository.load().agents.first?.token, "secret-token")
    }

    func testAppendingMessageKeepsExistingMessagesAndAddsOne() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(agentID: "a1", address: "0xaaa", title: "c", updatedAt: seconds(1000))
        let first = ChatMessage(role: .user, content: "one")
        conversation.messages = [first]
        repository.upsertConversation(conversation)

        let second = ChatMessage(role: .agent, content: "two")
        conversation.messages = [first, second]
        repository.upsertConversation(conversation)
        let loaded = repository.load().conversations.first

        XCTAssertEqual(loaded?.messages.map(\.id), [first.id, second.id])
        XCTAssertEqual(loaded?.messages.map(\.content), ["one", "two"])
    }

    func testRemovingMessageDeletesOnlyThatMessage() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(agentID: "a1", address: "0xaaa", title: "c", updatedAt: seconds(1000))
        let keep = ChatMessage(role: .user, content: "keep")
        let thinking = ChatMessage(role: .thinking, content: "...")
        conversation.messages = [keep, thinking]
        repository.upsertConversation(conversation)

        conversation.messages = [keep]
        repository.upsertConversation(conversation)
        let loaded = repository.load().conversations.first

        XCTAssertEqual(loaded?.messages.map(\.id), [keep.id])
    }

    func testSaveActivePersistsPointers() throws {
        let repository = try makeRepository()

        repository.saveActive(agentID: "a1", conversationID: "c1")

        let loaded = repository.load()
        XCTAssertEqual(loaded.activeAgentID, "a1")
        XCTAssertEqual(loaded.activeConversationID, "c1")
    }

    func testSearchMatchesTitleAndMessageContent() throws {
        let repository = try makeRepository()
        var byTitle = makeConversation(agentID: "a1", address: "0xaaa", title: "Groceries", updatedAt: seconds(3000))
        byTitle.messages = [ChatMessage(role: .user, content: "unrelated")]
        var byContent = makeConversation(agentID: "a1", address: "0xaaa", title: "Random", updatedAt: seconds(2000))
        byContent.messages = [ChatMessage(role: .user, content: "buy milk and eggs")]
        let noMatch = makeConversation(agentID: "a1", address: "0xaaa", title: "Nope", updatedAt: seconds(1000))
        [byTitle, byContent, noMatch].forEach(repository.upsertConversation)

        let titleHits = Set(repository.search("grocer").map(\.id))
        let contentHits = Set(repository.search("milk").map(\.id))

        XCTAssertEqual(titleHits, [byTitle.id])
        XCTAssertEqual(contentHits, [byContent.id])
    }

    func testSearchWithEmptyOrWhitespaceQueryReturnsAllConversations() throws {
        let repository = try makeRepository()
        let first = makeConversation(agentID: "a1", address: "0xaaa", title: "one", updatedAt: seconds(2000))
        let second = makeConversation(agentID: "a1", address: "0xaaa", title: "two", updatedAt: seconds(1000))
        [first, second].forEach(repository.upsertConversation)

        XCTAssertEqual(Set(repository.search("").map(\.id)), [first.id, second.id])
        XCTAssertEqual(Set(repository.search("   \n").map(\.id)), [first.id, second.id])
    }

    func testSearchResultsAreSortedByUpdatedAtDescendingAndDeduplicated() throws {
        let repository = try makeRepository()
        // Matches by BOTH title and message content — must appear exactly once.
        var both = makeConversation(agentID: "a1", address: "0xaaa", title: "apple pie", updatedAt: seconds(1000))
        both.messages = [ChatMessage(role: .user, content: "apple crumble recipe")]
        var newer = makeConversation(agentID: "a1", address: "0xaaa", title: "shopping", updatedAt: seconds(3000))
        newer.messages = [ChatMessage(role: .user, content: "buy apples")]
        let middle = makeConversation(agentID: "a1", address: "0xaaa", title: "apple support call", updatedAt: seconds(2000))
        [both, newer, middle].forEach(repository.upsertConversation)

        let hits = repository.search("apple")

        XCTAssertEqual(hits.map(\.id), [newer.id, middle.id, both.id])
    }

    func testSearchIsCaseAndDiacriticInsensitive() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(agentID: "a1", address: "0xaaa", title: "Café notes", updatedAt: seconds(1000))
        conversation.messages = [ChatMessage(role: .user, content: "agenda for the storage design review")]
        repository.upsertConversation(conversation)

        XCTAssertEqual(repository.search("cafe").map(\.id), [conversation.id])
        XCTAssertEqual(repository.search("CAFÉ").map(\.id), [conversation.id])
        XCTAssertEqual(repository.search("Storage Design").map(\.id), [conversation.id])
    }

    func testSaveActiveNilClearsStoredPointers() throws {
        let repository = try makeRepository()
        repository.saveActive(agentID: "a1", conversationID: "c1")

        repository.saveActive(agentID: nil, conversationID: nil)
        let loaded = repository.load()

        XCTAssertNil(loaded.activeAgentID)
        XCTAssertNil(loaded.activeConversationID)
    }

    func testDiskStoreSurvivesRepositoryRelaunch() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let agent = AgentConnection(address: "0xabc")
        var conversation = makeConversation(agentID: agent.id, address: agent.address, title: "persisted", updatedAt: seconds(1000))
        conversation.messages = [ChatMessage(role: .user, content: "survives relaunch")]

        // First "launch": write, then release the repository (and its container).
        do {
            let repository = try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults)
            repository.upsertAgent(agent)
            repository.upsertConversation(conversation)
            repository.saveActive(agentID: agent.id, conversationID: conversation.id)
        }

        // Second "launch": a fresh repository on the same file must read everything back.
        let relaunched = try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults)
        let loaded = relaunched.load()

        XCTAssertEqual(loaded.agents.map(\.id), [agent.id])
        XCTAssertEqual(loaded.conversations.map(\.id), [conversation.id])
        XCTAssertEqual(loaded.conversations.first?.messages.map(\.content), conversation.messages.map(\.content))
        XCTAssertEqual(loaded.activeAgentID, agent.id)
        XCTAssertEqual(loaded.activeConversationID, conversation.id)
        XCTAssertEqual(relaunched.search("relaunch").map(\.id), [conversation.id])
    }

    func testMultipleAgentsRoundTrip() throws {
        let repository = try makeRepository()
        let a = AgentConnection(id: "a1", address: "0xaaa", createdAt: seconds(1000), updatedAt: seconds(1000))
        let b = AgentConnection(id: "a2", address: "0xbbb", createdAt: seconds(2000), updatedAt: seconds(2000))
        repository.upsertAgent(a)
        repository.upsertAgent(b)

        XCTAssertEqual(Set(repository.load().agents.map(\.id)), ["a1", "a2"])
    }

    func testUpsertAgentUpdatesExistingInPlace() throws {
        let repository = try makeRepository()
        var agent = AgentConnection(id: "a1", address: "0xaaa", name: "First", createdAt: seconds(1000), updatedAt: seconds(1000))
        repository.upsertAgent(agent)
        agent.name = "Renamed"
        repository.upsertAgent(agent)

        let loaded = repository.load().agents
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Renamed")
    }

    func testDeletingNonexistentIDsIsANoOp() throws {
        let repository = try makeRepository()
        repository.deleteConversation(id: "missing")
        repository.deleteAgent(id: "missing")

        XCTAssertEqual(repository.load(), .empty)
    }

    func testMessagesAreReturnedInCreatedAtOrder() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(agentID: "a1", address: "0xaaa", title: "c", updatedAt: seconds(1000))
        let later = ChatMessage(role: .user, content: "later", createdAt: seconds(2000))
        let earlier = ChatMessage(role: .agent, content: "earlier", createdAt: seconds(1000))
        conversation.messages = [later, earlier]
        repository.upsertConversation(conversation)

        let loaded = repository.load().conversations.first
        XCTAssertEqual(loaded?.messages.map(\.content), ["earlier", "later"])
    }

    func testNilServerSessionRoundTripsAsNil() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(agentID: "a1", address: "0xaaa", title: "c", updatedAt: seconds(1000))
        conversation.serverSession = nil
        repository.upsertConversation(conversation)

        XCTAssertNil(repository.load().conversations.first?.serverSession)
    }

    func testEmptyMessagesRoundTrip() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(agentID: "a1", address: "0xaaa", title: "c", updatedAt: seconds(1000))
        conversation.messages = []
        repository.upsertConversation(conversation)

        XCTAssertEqual(repository.load().conversations.first?.messages.count, 0)
    }

    func testAllModesRoundTrip() throws {
        let repository = try makeRepository()
        for mode in ChatMode.allCases {
            var conversation = makeConversation(agentID: "a1", address: "0xaaa", title: mode.rawValue, updatedAt: seconds(1000))
            conversation.mode = mode
            repository.upsertConversation(conversation)
            let loaded = repository.load().conversations.first { $0.id == conversation.id }
            XCTAssertEqual(loaded?.mode, mode)
        }
    }

    func testAllRolesRoundTrip() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(agentID: "a1", address: "0xaaa", title: "c", updatedAt: seconds(1000))
        conversation.messages = [
            ChatMessage(role: .user, content: "u", createdAt: seconds(1000)),
            ChatMessage(role: .agent, content: "a", createdAt: seconds(1001)),
            ChatMessage(role: .thinking, content: "t", createdAt: seconds(1002)),
            ChatMessage(role: .error, content: "e", createdAt: seconds(1003)),
        ]
        repository.upsertConversation(conversation)

        XCTAssertEqual(repository.load().conversations.first?.messages.map(\.role), [.user, .agent, .thinking, .error])
    }

    func testToolCallMessageRoundTripsWithInputOutputAndState() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(agentID: "a1", address: "0xaaa", title: "c", updatedAt: seconds(1000))
        let tool = ChatMessage(
            id: "tool-1",
            role: .tool,
            content: "README contents",
            createdAt: seconds(1001),
            toolName: "read_file",
            toolArguments: ["path": .string("README.md")],
            toolState: .completed
        )
        conversation.messages = [tool]
        repository.upsertConversation(conversation)

        let loaded = repository.load().conversations.first?.messages.first

        XCTAssertEqual(loaded, tool)
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
