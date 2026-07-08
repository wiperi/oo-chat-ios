import XCTest
@testable import OOChatIOS

final class ConversationStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    private let snapshotKey = "connectonion.native-ios.chatSnapshot.v2"
    private let corruptSnapshotKey = "connectonion.native-ios.chatSnapshot.v2.corrupt"
    private let legacyConversationsKey = "connectonion.native-ios.conversations"
    private let legacyActiveConversationKey = "connectonion.native-ios.activeConversation"

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

    func testLoadReturnsEmptyWhenNothingStored() {
        let store = ConversationStore(defaults: defaults)

        XCTAssertEqual(store.load(), .empty)
    }

    func testSaveThenLoadRestoresAgentsConversationsAndActiveIDs() {
        let store = ConversationStore(defaults: defaults)
        let agent = makeAgent(address: "0xabc", updatedAt: seconds(1000))
        let conversation = makeConversation(agentID: agent.id, address: agent.address, title: "Hello", updatedAt: seconds(1000))
        let snapshot = ChatSnapshot(
            agents: [agent],
            conversations: [conversation],
            activeAgentID: agent.id,
            activeConversationID: conversation.id
        )

        store.save(snapshot)
        let loaded = store.load()

        XCTAssertEqual(loaded.agents.map(\.id), [agent.id])
        XCTAssertEqual(loaded.conversations.map(\.id), [conversation.id])
        XCTAssertEqual(loaded.conversations.first?.title, "Hello")
        XCTAssertEqual(loaded.activeAgentID, agent.id)
        XCTAssertEqual(loaded.activeConversationID, conversation.id)
    }

    func testLoadSortsAgentsAndConversationsByUpdatedAtDescending() {
        let store = ConversationStore(defaults: defaults)
        let older = makeAgent(address: "0xold", updatedAt: seconds(1000))
        let newer = makeAgent(address: "0xnew", updatedAt: seconds(2000))
        let olderConversation = makeConversation(agentID: older.id, address: older.address, title: "old", updatedAt: seconds(1000))
        let newerConversation = makeConversation(agentID: newer.id, address: newer.address, title: "new", updatedAt: seconds(2000))
        let snapshot = ChatSnapshot(
            agents: [older, newer],
            conversations: [olderConversation, newerConversation],
            activeAgentID: nil,
            activeConversationID: nil
        )

        store.save(snapshot)
        let loaded = store.load()

        XCTAssertEqual(loaded.agents.map(\.id), [newer.id, older.id])
        XCTAssertEqual(loaded.conversations.map(\.id), [newerConversation.id, olderConversation.id])
    }

    func testLegacyConversationsWithSameAddressGroupUnderOneAgent() {
        let first = makeConversation(agentID: nil, address: "0xshared", title: "first", updatedAt: seconds(1000))
        let second = makeConversation(agentID: nil, address: "0xshared", title: "second", updatedAt: seconds(2000))
        seedLegacy([first, second], active: nil)
        let store = ConversationStore(defaults: defaults)

        let loaded = store.load()

        XCTAssertEqual(loaded.agents.count, 1)
        XCTAssertEqual(loaded.agents.first?.address, "0xshared")
        let agentID = loaded.agents.first?.id
        XCTAssertEqual(Set(loaded.conversations.map(\.agentID)), [agentID])
    }

    func testLegacyConversationsWithDistinctAddressesProduceDistinctAgents() {
        let a = makeConversation(agentID: nil, address: "0xaaa", title: "a", updatedAt: seconds(1000))
        let b = makeConversation(agentID: nil, address: "0xbbb", title: "b", updatedAt: seconds(1000))
        seedLegacy([a, b], active: nil)
        let store = ConversationStore(defaults: defaults)

        let loaded = store.load()

        XCTAssertEqual(Set(loaded.agents.map(\.address)), ["0xaaa", "0xbbb"])
        XCTAssertEqual(loaded.conversations.count, 2)
    }

    func testLegacyActiveConversationIsClearedWhenItsConversationIsSkipped() {
        let valid = makeConversation(agentID: nil, address: "0xvalid", title: "valid", updatedAt: seconds(1000))
        let orphan = makeConversation(agentID: nil, address: "   ", title: "orphan", updatedAt: seconds(1000))
        seedLegacy([valid, orphan], active: orphan.id)
        let store = ConversationStore(defaults: defaults)

        let loaded = store.load()

        XCTAssertNil(loaded.activeConversationID)
    }

    func testLegacyConversationWithEmptyAddressIsSkipped() {
        let valid = makeConversation(agentID: nil, address: "0xvalid", title: "valid", updatedAt: seconds(1000))
        let orphan = makeConversation(agentID: nil, address: "   ", title: "orphan", updatedAt: seconds(1000))
        seedLegacy([valid, orphan], active: nil)
        let store = ConversationStore(defaults: defaults)

        let loaded = store.load()

        XCTAssertEqual(loaded.agents.count, 1)
        XCTAssertEqual(loaded.conversations.map(\.id), [valid.id])
    }

    func testLegacyMigrationIsPersistedAndStableAcrossLoads() {
        let conversation = makeConversation(agentID: nil, address: "0xabc", title: "legacy", updatedAt: seconds(1000))
        seedLegacy([conversation], active: conversation.id)

        let firstLaunch = ConversationStore(defaults: defaults).load()
        let secondLaunch = ConversationStore(defaults: defaults).load()

        XCTAssertEqual(firstLaunch.agents.map(\.id), secondLaunch.agents.map(\.id))
        XCTAssertNil(defaults.data(forKey: legacyConversationsKey))
        XCTAssertNil(defaults.string(forKey: legacyActiveConversationKey))
        XCTAssertNotNil(defaults.data(forKey: snapshotKey))
    }

    func testCorruptSnapshotIsBackedUpInsteadOfSilentlyLost() {
        let corrupt = Data("not valid json".utf8)
        defaults.set(corrupt, forKey: snapshotKey)
        let store = ConversationStore(defaults: defaults)

        let loaded = store.load()

        XCTAssertEqual(loaded, .empty)
        XCTAssertEqual(defaults.data(forKey: corruptSnapshotKey), corrupt)
    }

    private func seconds(_ value: TimeInterval) -> Date {
        Date(timeIntervalSince1970: value)
    }

    private func makeAgent(address: String, updatedAt: Date) -> AgentConnection {
        AgentConnection(address: address, createdAt: updatedAt, updatedAt: updatedAt)
    }

    private func makeConversation(agentID: String?, address: String, title: String, updatedAt: Date) -> Conversation {
        var conversation = Conversation(agentID: agentID, agentAddress: address)
        conversation.title = title
        conversation.createdAt = updatedAt
        conversation.updatedAt = updatedAt
        return conversation
    }

    private func seedLegacy(_ conversations: [Conversation], active: String?) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try! encoder.encode(conversations), forKey: legacyConversationsKey)
        if let active {
            defaults.set(active, forKey: legacyActiveConversationKey)
        }
    }
}
