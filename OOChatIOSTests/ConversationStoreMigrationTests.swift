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

    private func makeConversation(title: String) -> Conversation {
        var conversation = Conversation(agentID: "a1", agentAddress: "0xabc")
        conversation.title = title
        return conversation
    }
}
