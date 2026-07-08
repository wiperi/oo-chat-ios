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

    func testGranularUpsertAndDeleteThroughDefaultImplementation() {
        let store = ConversationStore(defaults: defaults)
        let keep = makeConversation(agentID: "a1", address: "0xaaa", title: "keep", updatedAt: seconds(2000))
        let drop = makeConversation(agentID: "a1", address: "0xaaa", title: "drop", updatedAt: seconds(1000))
        store.upsertConversation(keep)
        store.upsertConversation(drop)

        store.deleteConversation(id: drop.id)

        XCTAssertEqual(store.load().conversations.map(\.id), [keep.id])
    }

    func testSearchThroughDefaultImplementationMatchesTitleAndContent() {
        let store = ConversationStore(defaults: defaults)
        var byContent = makeConversation(agentID: "a1", address: "0xaaa", title: "Random", updatedAt: seconds(1000))
        byContent.messages = [ChatMessage(role: .user, content: "buy milk")]
        store.upsertConversation(byContent)

        XCTAssertEqual(store.search("milk").map(\.id), [byContent.id])
        XCTAssertTrue(store.search("nothingmatches").isEmpty)
    }

    func testSnapshotWinsWhenBothSnapshotAndLegacyPresent() {
        let store = ConversationStore(defaults: defaults)
        let modern = makeConversation(agentID: "a1", address: "0xmodern", title: "modern", updatedAt: seconds(1000))
        store.save(ChatSnapshot(agents: [], conversations: [modern], activeAgentID: nil, activeConversationID: nil))
        seedLegacy([makeConversation(agentID: nil, address: "0xlegacy", title: "legacy", updatedAt: seconds(1000))], active: nil)

        let loaded = ConversationStore(defaults: defaults).load()

        XCTAssertEqual(loaded.conversations.map(\.title), ["modern"])
    }

    func testLegacyAddressIsTrimmedDuringMigration() {
        seedLegacy([makeConversation(agentID: nil, address: "   0xspaced   ", title: "c", updatedAt: seconds(1000))], active: nil)

        let loaded = ConversationStore(defaults: defaults).load()

        XCTAssertEqual(loaded.agents.map(\.address), ["0xspaced"])
        XCTAssertEqual(loaded.conversations.first?.agentAddress, "0xspaced")
    }

    func testMigratedAgentUpdatedAtIsMaxOfItsConversations() {
        let older = makeConversation(agentID: nil, address: "0xsame", title: "older", updatedAt: seconds(1000))
        let newer = makeConversation(agentID: nil, address: "0xsame", title: "newer", updatedAt: seconds(5000))
        seedLegacy([older, newer], active: nil)

        let loaded = ConversationStore(defaults: defaults).load()

        XCTAssertEqual(loaded.agents.first?.updatedAt, seconds(5000))
    }

    func testCorruptBackupSurvivesSubsequentSave() {
        let corrupt = Data("garbage".utf8)
        defaults.set(corrupt, forKey: snapshotKey)
        let store = ConversationStore(defaults: defaults)
        _ = store.load()

        store.save(ChatSnapshot(agents: [], conversations: [], activeAgentID: nil, activeConversationID: nil))

        XCTAssertEqual(defaults.data(forKey: corruptSnapshotKey), corrupt)
        XCTAssertNotNil(defaults.data(forKey: snapshotKey))
    }

    func testRoundTripPreservesModeRolesAndServerSession() {
        let store = ConversationStore(defaults: defaults)
        var conversation = makeConversation(agentID: "a1", address: "0xaaa", title: "fidelity", updatedAt: seconds(1000))
        conversation.mode = .accept
        conversation.serverSession = ["mode": .string("accept_edits"), "count": .number(3)]
        conversation.messages = [
            ChatMessage(role: .user, content: "u"),
            ChatMessage(role: .agent, content: "a"),
            ChatMessage(role: .thinking, content: "t"),
            ChatMessage(role: .error, content: "e"),
        ]
        store.save(ChatSnapshot(agents: [], conversations: [conversation], activeAgentID: nil, activeConversationID: nil))

        let loaded = store.load().conversations.first

        XCTAssertEqual(loaded?.mode, .accept)
        XCTAssertEqual(loaded?.messages.map(\.role), [.user, .agent, .thinking, .error])
        XCTAssertEqual(loaded?.serverSession?["mode"]?.stringValue, "accept_edits")
    }

    func testDefaultDeleteConversationClearsActivePointer() {
        let store = ConversationStore(defaults: defaults)
        let conversation = makeConversation(agentID: "a1", address: "0xaaa", title: "c", updatedAt: seconds(1000))
        store.save(ChatSnapshot(agents: [], conversations: [conversation], activeAgentID: "a1", activeConversationID: conversation.id))

        store.deleteConversation(id: conversation.id)

        XCTAssertNil(store.load().activeConversationID)
        XCTAssertTrue(store.load().conversations.isEmpty)
    }

    func testDefaultDeleteAgentCascadesConversationsAndClearsActive() {
        let store = ConversationStore(defaults: defaults)
        let agent = AgentConnection(id: "a1", address: "0xaaa")
        let conversation = makeConversation(agentID: "a1", address: "0xaaa", title: "c", updatedAt: seconds(1000))
        store.save(ChatSnapshot(agents: [agent], conversations: [conversation], activeAgentID: "a1", activeConversationID: conversation.id))

        store.deleteAgent(id: "a1")
        let loaded = store.load()

        XCTAssertTrue(loaded.agents.isEmpty)
        XCTAssertTrue(loaded.conversations.isEmpty)
        XCTAssertNil(loaded.activeAgentID)
        XCTAssertNil(loaded.activeConversationID)
    }

    func testDefaultUpsertReplacesInsteadOfDuplicating() {
        let store = ConversationStore(defaults: defaults)
        var conversation = makeConversation(agentID: "a1", address: "0xaaa", title: "before", updatedAt: seconds(1000))
        store.upsertConversation(conversation)
        conversation.title = "after"
        store.upsertConversation(conversation)

        let loaded = store.load().conversations
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "after")
    }

    func testDefaultSaveActiveNilClearsPointers() {
        let store = ConversationStore(defaults: defaults)
        store.save(ChatSnapshot(agents: [], conversations: [], activeAgentID: "a1", activeConversationID: "c1"))

        store.saveActive(agentID: nil, conversationID: nil)
        let loaded = store.load()

        XCTAssertNil(loaded.activeAgentID)
        XCTAssertNil(loaded.activeConversationID)
    }

    func testSearchIsCaseInsensitiveAndTrimsWhitespace() {
        let store = ConversationStore(defaults: defaults)
        let groceries = makeConversation(agentID: "a1", address: "0xaaa", title: "Groceries", updatedAt: seconds(1000))
        store.upsertConversation(groceries)

        XCTAssertEqual(store.search("  GROCER  ").map(\.id), [groceries.id])
    }

    func testSearchWithEmptyQueryReturnsAllConversations() {
        let store = ConversationStore(defaults: defaults)
        let a = makeConversation(agentID: "a1", address: "0xaaa", title: "a", updatedAt: seconds(2000))
        let b = makeConversation(agentID: "a1", address: "0xaaa", title: "b", updatedAt: seconds(1000))
        store.upsertConversation(a)
        store.upsertConversation(b)

        XCTAssertEqual(Set(store.search("   ").map(\.id)), [a.id, b.id])
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
