import XCTest
@testable import OOChatIOS

final class MockNetworkMonitor: NetworkPathMonitoring {
    var onUpdate: (@MainActor (Bool) -> Void)?
    private(set) var started = false
    private(set) var cancelled = false

    func start() {
        started = true
    }

    func cancel() {
        cancelled = true
    }

    @MainActor
    func simulate(online: Bool) {
        onUpdate?(online)
    }
}

final class MockAgentTransport: HostedAgentTransport {
    enum Behavior {
        case succeed(output: String)
        case fail(Error)
    }

    var connectBehavior: Behavior = .succeed(output: "")
    var sendBehavior: Behavior = .succeed(output: "mock reply")
    var streamedEvents: [HostedAgentEvent] = []
    var onSend: (@MainActor () -> Void)?

    private(set) var connectedAddresses: [String] = []
    private(set) var sentPrompts: [String] = []

    func connect(agentAddress: String, conversation: Conversation) async throws -> HostedAgentResult {
        connectedAddresses.append(agentAddress)
        switch connectBehavior {
        case .succeed:
            return HostedAgentResult(
                output: nil,
                endpointLabel: "mock",
                serverSession: ["session_id": .string(conversation.id)]
            )
        case .fail(let error):
            throw error
        }
    }

    func sendPrompt(
        agentAddress: String,
        conversation: Conversation,
        prompt: String,
        onEvent: (@MainActor (HostedAgentEvent) -> Void)?
    ) async throws -> HostedAgentResult {
        sentPrompts.append(prompt)
        switch sendBehavior {
        case .succeed(let output):
            for event in streamedEvents {
                await onEvent?(event)
            }
            if let onSend {
                await MainActor.run { onSend() }
            }
            return HostedAgentResult(output: output, endpointLabel: "mock", serverSession: nil)
        case .fail(let error):
            throw error
        }
    }
}

@MainActor
final class NetworkRecoveryTests: XCTestCase {
    private let address = "0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

    func testMonitorStartsOnInitAndOfflineFlagTracksNetwork() {
        let (viewModel, _, monitor) = makeEnvironment()

        XCTAssertTrue(monitor.started)
        XCTAssertFalse(viewModel.isOffline)

        monitor.simulate(online: false)
        XCTAssertTrue(viewModel.isOffline)
        XCTAssertEqual(viewModel.connectionState, .disconnected)

        monitor.simulate(online: true)
        XCTAssertFalse(viewModel.isOffline)
    }

    func testStayingOnlineDoesNotTriggerRecovery() {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)

        monitor.simulate(online: true)

        XCTAssertNil(viewModel.recoveryTask)
        XCTAssertTrue(transport.connectedAddresses.isEmpty)
    }

    // queueing while offline
    func testSendWhileOfflineQueuesMessageWithoutNetworkCall() {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        monitor.simulate(online: false)

        viewModel.prompt = "queued while offline"
        viewModel.sendPrompt()

        let messages = viewModel.activeConversation?.messages ?? []
        let userMessage = messages.last { $0.role == .user }
        XCTAssertEqual(userMessage?.deliveryState, .queued)
        XCTAssertEqual(userMessage?.content, "queued while offline")
        XCTAssertFalse(messages.contains { $0.role == .thinking })
        XCTAssertTrue(transport.sentPrompts.isEmpty)
        XCTAssertFalse(viewModel.isProcessing)
    }

    func testMultipleOfflineSendsQueueInOrder() {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        monitor.simulate(online: false)

        viewModel.prompt = "first"
        viewModel.sendPrompt()
        viewModel.prompt = "second"
        viewModel.sendPrompt()

        let queued = (viewModel.activeConversation?.messages ?? [])
            .filter { $0.role == .user && $0.deliveryState == .queued }
        XCTAssertEqual(queued.map(\.content), ["first", "second"])
        XCTAssertTrue(transport.sentPrompts.isEmpty)
    }

    // automatic reconnection and flush
    func testReconnectionFlushesQueuedMessagesInOrder() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        monitor.simulate(online: false)
        viewModel.prompt = "first"
        viewModel.sendPrompt()
        viewModel.prompt = "second"
        viewModel.sendPrompt()

        monitor.simulate(online: true)
        await viewModel.recoveryTask?.value

        XCTAssertEqual(transport.connectedAddresses, [address], "reconnection should happen automatically")
        XCTAssertEqual(transport.sentPrompts, ["first", "second"])
        let messages = viewModel.activeConversation?.messages ?? []
        let userMessages = messages.filter { $0.role == .user }
        XCTAssertTrue(userMessages.allSatisfy { $0.deliveryState == .sent })
        XCTAssertEqual(messages.filter { $0.role == .agent && $0.content == "mock reply" }.count, 2)
        XCTAssertFalse(messages.contains { $0.role == .thinking })
        XCTAssertEqual(viewModel.connectionState, .connected)
    }

    func testReconnectionWithNothingQueuedStillReconnects() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        monitor.simulate(online: false)

        monitor.simulate(online: true)
        await viewModel.recoveryTask?.value

        XCTAssertEqual(transport.connectedAddresses, [address])
        XCTAssertTrue(transport.sentPrompts.isEmpty)
    }

    func testFlushStopsWhenNetworkDropsAgain() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        monitor.simulate(online: false)
        viewModel.prompt = "first"
        viewModel.sendPrompt()
        viewModel.prompt = "second"
        viewModel.sendPrompt()
        transport.onSend = {
            monitor.simulate(online: false)
        }

        monitor.simulate(online: true)
        await viewModel.recoveryTask?.value

        XCTAssertEqual(transport.sentPrompts, ["first"], "flush should stop once offline again")
        let queued = (viewModel.activeConversation?.messages ?? [])
            .filter { $0.role == .user && $0.deliveryState == .queued }
        XCTAssertEqual(queued.map(\.content), ["second"])
    }

    func testInterruptedDeliveryMarksMessageFailed() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.sendBehavior = .fail(HostedAgentClientError.timeout)

        viewModel.prompt = "will fail"
        viewModel.sendPrompt()
        await viewModel.sendTask?.value

        let messages = viewModel.activeConversation?.messages ?? []
        let userMessage = messages.last { $0.role == .user }
        XCTAssertEqual(userMessage?.deliveryState, .failed)
        XCTAssertFalse(messages.contains { $0.role == .thinking })
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.connectionState, .disconnected)
        XCTAssertFalse(viewModel.isProcessing)
    }

    func testRetryResendsFailedMessage() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.sendBehavior = .fail(HostedAgentClientError.timeout)
        viewModel.prompt = "flaky"
        viewModel.sendPrompt()
        await viewModel.sendTask?.value
        let failed = (viewModel.activeConversation?.messages ?? []).last { $0.role == .user }!
        XCTAssertEqual(failed.deliveryState, .failed)

        transport.sendBehavior = .succeed(output: "recovered")
        viewModel.retryMessage(failed)
        await viewModel.sendTask?.value

        let messages = viewModel.activeConversation?.messages ?? []
        let userMessage = messages.first { $0.id == failed.id }
        XCTAssertEqual(userMessage?.deliveryState, .sent)
        XCTAssertTrue(messages.contains { $0.role == .agent && $0.content == "recovered" })
        XCTAssertEqual(transport.sentPrompts, ["flaky", "flaky"])
        XCTAssertNil(viewModel.errorMessage)
    }

    func testRetryWhileOfflineRequeuesForLaterFlush() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.sendBehavior = .fail(HostedAgentClientError.timeout)
        viewModel.prompt = "flaky"
        viewModel.sendPrompt()
        await viewModel.sendTask?.value
        let failed = (viewModel.activeConversation?.messages ?? []).last { $0.role == .user }!

        monitor.simulate(online: false)
        transport.sendBehavior = .succeed(output: "after reconnect")
        viewModel.retryMessage(failed)

        var requeued = (viewModel.activeConversation?.messages ?? []).first { $0.id == failed.id }
        XCTAssertEqual(requeued?.deliveryState, .queued)
        XCTAssertEqual(transport.sentPrompts, ["flaky"], "no send while offline")

        monitor.simulate(online: true)
        await viewModel.recoveryTask?.value

        requeued = (viewModel.activeConversation?.messages ?? []).first { $0.id == failed.id }
        XCTAssertEqual(requeued?.deliveryState, .sent)
        XCTAssertEqual(transport.sentPrompts, ["flaky", "flaky"])
    }

    func testRetryIgnoresMessagesThatDidNotFail() {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        let sentMessage = ChatMessage(role: .user, content: "already sent", deliveryState: .sent)

        viewModel.retryMessage(sentMessage)

        XCTAssertTrue(transport.sentPrompts.isEmpty)
        XCTAssertNil(viewModel.sendTask)
    }

    // connecting while offline
    func testConnectToAgentWhileOfflineFailsFast() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        monitor.simulate(online: false)
        viewModel.agentAddressDraft = address

        let agent = await viewModel.connectToAgent()

        XCTAssertNil(agent)
        XCTAssertTrue(transport.connectedAddresses.isEmpty)
        XCTAssertEqual(viewModel.connectionState, .disconnected)
        XCTAssertTrue(viewModel.connectionFailureMessage?.contains("offline") ?? false)
    }

    // persistence
    func testDeliveryStateRoundTripsThroughRepository() throws {
        let defaults = makeDefaults()
        let store = try SwiftDataConversationRepository(inMemory: true, defaults: defaults)
        var conversation = Conversation(agentID: "agent-1", agentAddress: address)
        conversation.messages.append(ChatMessage(role: .user, content: "pending", deliveryState: .queued))
        store.upsertConversation(conversation)

        let loaded = store.load().conversations.first { $0.id == conversation.id }
        let message = loaded?.messages.first { $0.content == "pending" }

        XCTAssertEqual(message?.deliveryState, .queued)
    }

    func testRepositoryUpdatesDeliveryStateOfExistingMessage() throws {
        let defaults = makeDefaults()
        let store = try SwiftDataConversationRepository(inMemory: true, defaults: defaults)
        var conversation = Conversation(agentID: "agent-1", agentAddress: address)
        conversation.messages.append(ChatMessage(role: .user, content: "pending", deliveryState: .queued))
        store.upsertConversation(conversation)

        let index = conversation.messages.firstIndex { $0.content == "pending" }!
        conversation.messages[index].deliveryState = .failed
        store.upsertConversation(conversation)

        let loaded = store.load().conversations.first { $0.id == conversation.id }
        let message = loaded?.messages.first { $0.content == "pending" }
        XCTAssertEqual(message?.deliveryState, .failed)
    }

    func testChatMessageDecodingDefaultsDeliveryStateToSent() throws {
        let json = """
        {
          "id": "message-1",
          "role": "user",
          "content": "legacy",
          "createdAt": "2026-07-09T01:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let message = try decoder.decode(ChatMessage.self, from: Data(json.utf8))

        XCTAssertEqual(message.deliveryState, .sent)
    }

    func testChatMessageDecodesLegacyPayloadWithoutToolFields() throws {
        let json = """
        {
          "id": "message-1",
          "role": "agent",
          "content": "legacy response",
          "createdAt": "2026-07-09T01:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let message = try decoder.decode(ChatMessage.self, from: Data(json.utf8))

        XCTAssertNil(message.toolName)
        XCTAssertNil(message.toolArguments)
        XCTAssertNil(message.toolState)
    }

    func testStreamingToolCallIsUpdatedInPlaceAndPersistsWithResponse() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.streamedEvents = [
            .toolCall(
                id: "tool-read-1",
                name: "read_file",
                arguments: ["path": .string("README.md")]
            ),
            .toolResult(
                id: "tool-read-1",
                name: "read_file",
                output: "# Project notes",
                state: .completed
            ),
        ]
        transport.sendBehavior = .succeed(output: "I found the project notes.")

        viewModel.prompt = "Read the project notes"
        viewModel.sendPrompt()
        await viewModel.sendTask?.value

        let messages = viewModel.activeConversation?.messages ?? []
        let toolMessages = messages.filter { $0.role == .tool }
        XCTAssertEqual(toolMessages.count, 1)
        XCTAssertEqual(toolMessages.first?.id, "tool-read-1")
        XCTAssertEqual(toolMessages.first?.toolName, "read_file")
        XCTAssertEqual(toolMessages.first?.toolArguments, ["path": .string("README.md")])
        XCTAssertEqual(toolMessages.first?.toolState, .completed)
        XCTAssertEqual(toolMessages.first?.content, "# Project notes")
        XCTAssertEqual(messages.last?.role, .agent)
        XCTAssertEqual(messages.last?.content, "I found the project notes.")
    }

    // offline banner dismissal and manual retry
    func testOfflineBannerDismissalResetsOnNextDrop() {
        let (viewModel, _, monitor) = makeEnvironment()

        monitor.simulate(online: false)
        XCTAssertTrue(viewModel.shouldShowOfflineBanner)

        viewModel.dismissOfflineBanner()
        XCTAssertFalse(viewModel.shouldShowOfflineBanner)
        XCTAssertTrue(viewModel.isOffline, "dismissing the banner must not clear the offline state")

        monitor.simulate(online: true)
        monitor.simulate(online: false)
        XCTAssertTrue(viewModel.shouldShowOfflineBanner, "a fresh drop should show the banner again")
    }

    func testRetryConnectivityRecoversWithoutMonitorUpdate() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        monitor.simulate(online: false)
        viewModel.prompt = "stuck in queue"
        viewModel.sendPrompt()

        viewModel.retryConnectivity()
        await viewModel.recoveryTask?.value

        XCTAssertFalse(viewModel.isOffline, "successful reconnect should clear offline even if the monitor is stale")
        XCTAssertEqual(transport.connectedAddresses, [address])
        XCTAssertEqual(transport.sentPrompts, ["stuck in queue"])
        XCTAssertEqual(viewModel.connectionState, .connected)
    }

    func testRetryConnectivityStaysOfflineWhenReconnectFails() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.connectBehavior = .fail(HostedAgentClientError.timeout)
        monitor.simulate(online: false)
        viewModel.prompt = "still stuck"
        viewModel.sendPrompt()

        viewModel.retryConnectivity()
        await viewModel.recoveryTask?.value

        XCTAssertTrue(viewModel.isOffline)
        XCTAssertTrue(viewModel.shouldShowOfflineBanner)
        XCTAssertTrue(transport.sentPrompts.isEmpty, "queue must not flush when reconnect fails")
    }

    func testRetryConnectivityIgnoredWhenOnline() {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)

        viewModel.retryConnectivity()

        XCTAssertNil(viewModel.recoveryTask)
        XCTAssertTrue(transport.connectedAddresses.isEmpty)
    }

    // background probing while offline
    func testProbeAutoSendsQueueWithoutMonitorOrManualRetry() async {
        let (viewModel, transport, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        viewModel.probeInterval = 0.01
        transport.connectBehavior = .fail(HostedAgentClientError.timeout)
        monitor.simulate(online: false)
        viewModel.prompt = "auto delivered"
        viewModel.sendPrompt()

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(viewModel.isOffline, "failing probes must not flip the app online")
        XCTAssertNil(viewModel.errorMessage, "failing probes must stay silent")
        XCTAssertTrue(transport.sentPrompts.isEmpty)

        transport.connectBehavior = .succeed(output: "")
        await viewModel.probeTask?.value

        XCTAssertFalse(viewModel.isOffline)
        XCTAssertEqual(viewModel.connectionState, .connected)
        XCTAssertEqual(transport.sentPrompts, ["auto delivered"])
        let userMessage = (viewModel.activeConversation?.messages ?? []).last { $0.role == .user }
        XCTAssertEqual(userMessage?.deliveryState, .sent)
    }

    func testProbingStopsWhenMonitorReportsOnline() {
        let (viewModel, _, monitor) = makeEnvironment()
        setUpAgentAndConversation(viewModel)

        monitor.simulate(online: false)
        XCTAssertNotNil(viewModel.probeTask)

        monitor.simulate(online: true)
        XCTAssertTrue(viewModel.probeTask?.isCancelled ?? false)
    }

    private func makeEnvironment() -> (ChatViewModel, MockAgentTransport, MockNetworkMonitor) {
        let store = try! SwiftDataConversationRepository(inMemory: true, defaults: makeDefaults())
        let transport = MockAgentTransport()
        let monitor = MockNetworkMonitor()
        let viewModel = ChatViewModel(store: store, client: transport, networkMonitor: monitor)
        return (viewModel, transport, monitor)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "OOChatIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @discardableResult
    private func setUpAgentAndConversation(_ viewModel: ChatViewModel) -> AgentConnection {
        let agent = viewModel.saveAgent(name: "Recovery Agent", address: address, token: "")!
        _ = viewModel.createConversation(for: agent)
        return agent
    }
}
