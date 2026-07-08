import XCTest
@testable import OOChatIOS

final class ConversationStoreMigrationTests: XCTestCase {
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

    func testMigrationCopiesLegacySnapshotIntoSwiftData() throws {
        let legacy = ConversationStore(defaults: defaults)
        let conversation = makeConversation(title: "carried over")
        legacy.save(ChatSnapshot(agents: [], conversations: [conversation], activeAgentID: nil, activeConversationID: nil))
        let swiftData = try SwiftDataConversationRepository(inMemory: true, defaults: defaults)

        ConversationStoreMigration.migrateIfNeeded(from: legacy, to: swiftData, defaults: defaults)

        XCTAssertEqual(swiftData.load().conversations.map(\.title), ["carried over"])
        XCTAssertTrue(defaults.bool(forKey: ConversationStoreMigration.migratedKey))
    }

    func testMigrationRunsOnlyOnce() throws {
        let legacy = ConversationStore(defaults: defaults)
        legacy.save(ChatSnapshot(agents: [], conversations: [makeConversation(title: "first")], activeAgentID: nil, activeConversationID: nil))
        let swiftData = try SwiftDataConversationRepository(inMemory: true, defaults: defaults)
        ConversationStoreMigration.migrateIfNeeded(from: legacy, to: swiftData, defaults: defaults)

        legacy.save(ChatSnapshot(agents: [], conversations: [makeConversation(title: "second")], activeAgentID: nil, activeConversationID: nil))
        ConversationStoreMigration.migrateIfNeeded(from: legacy, to: swiftData, defaults: defaults)

        XCTAssertEqual(swiftData.load().conversations.map(\.title), ["first"])
    }

    func testMigrationSkippedWhenSwiftDataAlreadyHasData() throws {
        let legacy = ConversationStore(defaults: defaults)
        legacy.save(ChatSnapshot(agents: [], conversations: [makeConversation(title: "legacy")], activeAgentID: nil, activeConversationID: nil))
        let swiftData = try SwiftDataConversationRepository(inMemory: true, defaults: defaults)
        swiftData.save(ChatSnapshot(agents: [], conversations: [makeConversation(title: "existing")], activeAgentID: nil, activeConversationID: nil))

        ConversationStoreMigration.migrateIfNeeded(from: legacy, to: swiftData, defaults: defaults)

        XCTAssertEqual(swiftData.load().conversations.map(\.title), ["existing"])
    }

    func testMigrationMarksDoneEvenWithNoLegacyData() throws {
        let legacy = ConversationStore(defaults: defaults)
        let swiftData = try SwiftDataConversationRepository(inMemory: true, defaults: defaults)

        ConversationStoreMigration.migrateIfNeeded(from: legacy, to: swiftData, defaults: defaults)

        XCTAssertTrue(defaults.bool(forKey: ConversationStoreMigration.migratedKey))
        XCTAssertEqual(swiftData.load(), .empty)
    }

    func testMigrationPreservesAgentsAndMessages() throws {
        let legacy = ConversationStore(defaults: defaults)
        let agent = AgentConnection(id: "a1", address: "0xabc")
        var conversation = makeConversation(title: "with messages")
        conversation.messages = [
            ChatMessage(role: .user, content: "hi"),
            ChatMessage(role: .agent, content: "hello"),
        ]
        legacy.save(ChatSnapshot(agents: [agent], conversations: [conversation], activeAgentID: nil, activeConversationID: nil))
        let swiftData = try SwiftDataConversationRepository(inMemory: true, defaults: defaults)

        ConversationStoreMigration.migrateIfNeeded(from: legacy, to: swiftData, defaults: defaults)
        let loaded = swiftData.load()

        XCTAssertEqual(loaded.agents.map(\.id), ["a1"])
        XCTAssertEqual(loaded.conversations.first?.messages.map(\.content), ["hi", "hello"])
    }

    func testMigrationPreservesActivePointers() throws {
        let legacy = ConversationStore(defaults: defaults)
        let agent = AgentConnection(id: "a1", address: "0xabc")
        let conversation = makeConversation(title: "active")
        legacy.save(ChatSnapshot(agents: [agent], conversations: [conversation], activeAgentID: "a1", activeConversationID: conversation.id))
        let swiftData = try SwiftDataConversationRepository(inMemory: true, defaults: defaults)

        ConversationStoreMigration.migrateIfNeeded(from: legacy, to: swiftData, defaults: defaults)
        let loaded = swiftData.load()

        XCTAssertEqual(loaded.activeAgentID, "a1")
        XCTAssertEqual(loaded.activeConversationID, conversation.id)
    }

    func testMigrationNotMarkedDoneWhenCopyDoesNotPersist() {
        let legacy = ConversationStore(defaults: defaults)
        legacy.save(ChatSnapshot(agents: [], conversations: [makeConversation(title: "data")], activeAgentID: nil, activeConversationID: nil))
        let failing = DroppingRepository()

        ConversationStoreMigration.migrateIfNeeded(from: legacy, to: failing, defaults: defaults)

        XCTAssertFalse(defaults.bool(forKey: ConversationStoreMigration.migratedKey))
    }

    private final class DroppingRepository: ConversationRepository {
        func load() -> ChatSnapshot { .empty }
        func save(_ snapshot: ChatSnapshot) {}
    }

    private func makeConversation(title: String) -> Conversation {
        var conversation = Conversation(agentID: "a1", agentAddress: "0xabc")
        conversation.title = title
        return conversation
    }
}
