import XCTest
@testable import OOChatIOS

actor PromptGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

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
        case wait(gate: PromptGate, output: String)
        case waitUntilCancelled
    }

    var connectBehavior: Behavior = .succeed(output: "")
    var sendBehavior: Behavior = .succeed(output: "mock reply")
    var onConnectionStateChange: (@MainActor (String, ConnectionState) -> Void)?
    var sendBehaviorsByPrompt: [String: Behavior] = [:]
    var streamedEvents: [HostedAgentEvent] = []
    var approvalRequests: [ToolApprovalRequest] = []
    var planReviews: [PlanReviewRequest] = []
    var askUserRequests: [AskUserRequest] = []
    var availableSkills: [AgentSkill] = []
    var skillsByAddress: [String: [AgentSkill]] = [:]
    var skillFetchError: Error?
    var onSend: (@MainActor () -> Void)?
    var waitAfterInteractionsUntilCancelled = false

    private(set) var connectedAddresses: [String] = []
    private(set) var sentPrompts: [String] = []
    private(set) var approvalDecisions: [ApprovalDecision] = []
    private(set) var planReviewDecisions: [PlanReviewDecision] = []
    private(set) var askUserAnswers: [String] = []
    private(set) var fetchedSkillAddresses: [String] = []
    private(set) var interactionResponseWaits: [(agentAddress: String, conversationID: String)] = []

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
        case .wait(let gate, _):
            await gate.wait()
            return HostedAgentResult(
                output: nil,
                endpointLabel: "mock",
                serverSession: ["session_id": .string(conversation.id)]
            )
        case .waitUntilCancelled:
            while true {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    func fetchSkills(agentAddress: String) async throws -> [AgentSkill] {
        fetchedSkillAddresses.append(agentAddress)
        if let skillFetchError {
            throw skillFetchError
        }
        return skillsByAddress[agentAddress] ?? availableSkills
    }

    func sendPrompt(
        agentAddress: String,
        conversation: Conversation,
        prompt: String,
        onEvent: (@MainActor (HostedAgentEvent) -> Void)?,
        onApprovalRequest: (@MainActor (ToolApprovalRequest) async -> ApprovalDecision)?,
        onPlanReview: (@MainActor (PlanReviewRequest) async -> PlanReviewDecision)?,
        onAskUser: (@MainActor (AskUserRequest) async -> String)?
    ) async throws -> HostedAgentResult {
        sentPrompts.append(prompt)
        let behavior = sendBehaviorsByPrompt[prompt] ?? sendBehavior
        let output: String
        switch behavior {
        case .succeed(let value):
            output = value
        case .fail(let error):
            throw error
        case .wait(let gate, let value):
            await gate.wait()
            try Task.checkCancellation()
            output = value
        case .waitUntilCancelled:
            while true {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        for request in approvalRequests {
            guard let onApprovalRequest else {
                throw HostedAgentClientError.badFrame
            }
            approvalDecisions.append(await onApprovalRequest(request))
        }
        for review in planReviews {
            guard let onPlanReview else {
                throw HostedAgentClientError.badFrame
            }
            planReviewDecisions.append(await onPlanReview(review))
        }
        for request in askUserRequests {
            guard let onAskUser else {
                throw HostedAgentClientError.badFrame
            }
            askUserAnswers.append(await onAskUser(request))
        }
        if waitAfterInteractionsUntilCancelled {
            while true {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        for event in streamedEvents {
            await onEvent?(event)
        }
        if let onSend {
            await MainActor.run { onSend() }
        }
        return HostedAgentResult(output: output, endpointLabel: "mock", serverSession: nil)
    }

    func waitForPendingInteractionResponses(agentAddress: String, conversationID: String) async {
        interactionResponseWaits.append((agentAddress, conversationID))
        for _ in 0..<100 where approvalDecisions.isEmpty && planReviewDecisions.isEmpty {
            await Task.yield()
        }
    }

    @MainActor
    func simulateConnectionState(_ state: ConnectionState, conversationID: String) {
        onConnectionStateChange?(conversationID, state)
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

    func testOnlineCountTracksBackgroundConnectionLiveness() {
        let (viewModel, transport, _) = makeEnvironment()
        let firstAgent = setUpAgentAndConversation(viewModel)
        let firstConversation = viewModel.activeConversation!
        let secondAddress = "0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
        let secondAgent = viewModel.saveAgent(name: "Second", address: secondAddress, token: "")!
        _ = viewModel.createConversation(for: secondAgent)

        transport.simulateConnectionState(.connected, conversationID: firstConversation.id)

        XCTAssertEqual(viewModel.activeAgentID, secondAgent.id)
        XCTAssertTrue(viewModel.isAgentOnline(firstAgent))
        XCTAssertFalse(viewModel.isAgentOnline(secondAgent))
        XCTAssertEqual(viewModel.onlineAgentCount, 1)

        transport.simulateConnectionState(.disconnected, conversationID: firstConversation.id)

        XCTAssertFalse(viewModel.isAgentOnline(firstAgent))
        XCTAssertEqual(viewModel.onlineAgentCount, 0)
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

    func testSecondMessageQueuesBehindActiveResponseInSameConversation() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        let firstGate = PromptGate()
        transport.sendBehaviorsByPrompt["first"] = .wait(gate: firstGate, output: "first reply")

        viewModel.prompt = "first"
        viewModel.sendPrompt()
        await waitForSentPrompt("first", transport: transport)

        viewModel.prompt = "second"
        viewModel.sendPrompt()

        XCTAssertEqual(transport.sentPrompts, ["first"])
        XCTAssertTrue(viewModel.isProcessing)
        XCTAssertEqual(
            viewModel.activeConversation?.messages.filter {
                $0.role == .user && $0.deliveryState == .queued
            }.map(\.content),
            ["first", "second"]
        )

        await firstGate.open()
        await viewModel.flushQueuedMessages()

        XCTAssertEqual(transport.sentPrompts, ["first", "second"])
        XCTAssertFalse(viewModel.isProcessing)
        let replies = viewModel.activeConversation?.messages.filter { $0.role == .agent }.map(\.content) ?? []
        XCTAssertEqual(Array(replies.suffix(2)), ["first reply", "mock reply"])
    }

    func testDifferentConversationsCanRunWithoutStealingFocus() async {
        let (viewModel, transport, _) = makeEnvironment()
        let agent = setUpAgentAndConversation(viewModel)
        let firstConversation = viewModel.activeConversation!
        let firstGate = PromptGate()
        let secondGate = PromptGate()
        transport.sendBehaviorsByPrompt = [
            "first": .wait(gate: firstGate, output: "first reply"),
            "second": .wait(gate: secondGate, output: "second reply"),
        ]

        viewModel.prompt = "first"
        viewModel.sendPrompt()
        await waitForSentPrompt("first", transport: transport)

        let secondConversation = viewModel.createConversation(for: agent)
        viewModel.prompt = "second"
        viewModel.sendPrompt()
        await waitForSentPrompt("second", transport: transport)

        XCTAssertTrue(viewModel.isProcessing(conversationID: firstConversation.id))
        XCTAssertTrue(viewModel.isProcessing(conversationID: secondConversation.id))
        XCTAssertEqual(viewModel.activeConversationID, secondConversation.id)

        await firstGate.open()
        await waitUntilIdle(firstConversation.id, on: viewModel)

        XCTAssertEqual(viewModel.activeConversationID, secondConversation.id)
        XCTAssertTrue(viewModel.isProcessing)
        XCTAssertTrue(
            viewModel.conversation(withID: firstConversation.id)?.messages.contains {
                $0.role == .agent && $0.content == "first reply"
            } ?? false
        )

        await secondGate.open()
        await waitUntilIdle(secondConversation.id, on: viewModel)
        XCTAssertFalse(viewModel.isProcessing)
    }

    func testStopMarksActiveMessageCancelledAndRetryResendsIt() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.sendBehavior = .waitUntilCancelled

        viewModel.prompt = "long task"
        viewModel.sendPrompt()
        await waitForSentPrompt("long task", transport: transport)
        let task = viewModel.sendTask

        viewModel.stopActiveResponse()
        await task?.value

        let cancelled = viewModel.activeConversation?.messages.first {
            $0.role == .user && $0.content == "long task"
        }
        XCTAssertEqual(cancelled?.deliveryState, .cancelled)
        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertFalse(viewModel.activeConversation?.messages.contains { $0.role == .thinking } ?? true)

        transport.sendBehavior = .succeed(output: "retried")
        viewModel.retryMessage(cancelled!)
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.sentPrompts, ["long task", "long task"])
        XCTAssertEqual(
            viewModel.activeConversation?.messages.first { $0.id == cancelled?.id }?.deliveryState,
            .sent
        )
    }

    func testStoppingLeavesQueuedFollowUpPausedUntilTheUserSendsAgain() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.sendBehaviorsByPrompt["long task"] = .waitUntilCancelled

        viewModel.prompt = "long task"
        viewModel.sendPrompt()
        await waitForSentPrompt("long task", transport: transport)
        let task = viewModel.sendTask

        viewModel.prompt = "follow up"
        viewModel.sendPrompt()
        viewModel.prompt = "draft"
        viewModel.stopActiveResponse()
        await task?.value
        await viewModel.flushQueuedMessages()

        XCTAssertEqual(transport.sentPrompts, ["long task"])
        let userMessages = viewModel.activeConversation?.messages.filter { $0.role == .user } ?? []
        XCTAssertEqual(userMessages.first { $0.content == "long task" }?.deliveryState, .cancelled)
        XCTAssertEqual(userMessages.first { $0.content == "follow up" }?.deliveryState, .queued)
        XCTAssertEqual(viewModel.prompt, "draft")
        XCTAssertFalse(viewModel.isProcessing)

        viewModel.sendPrompt()
        await viewModel.flushQueuedMessages()

        XCTAssertEqual(transport.sentPrompts, ["long task", "follow up", "draft"])
        XCTAssertTrue(
            viewModel.activeConversation?.messages.filter { $0.role == .user }.allSatisfy {
                $0.deliveryState != .queued
            } ?? false
        )
    }

    func testStoppingActiveConversationLeavesBackgroundDeliveryRunning() async {
        let (viewModel, transport, _) = makeEnvironment()
        let agent = setUpAgentAndConversation(viewModel)
        let backgroundConversation = viewModel.activeConversation!
        let backgroundGate = PromptGate()
        transport.sendBehaviorsByPrompt = [
            "background": .wait(gate: backgroundGate, output: "background reply"),
            "active": .waitUntilCancelled,
        ]

        viewModel.prompt = "background"
        viewModel.sendPrompt()
        await waitForSentPrompt("background", transport: transport)

        let activeConversation = viewModel.createConversation(for: agent)
        viewModel.prompt = "active"
        viewModel.sendPrompt()
        await waitForSentPrompt("active", transport: transport)
        let activeTask = viewModel.sendTask

        viewModel.stopActiveResponse()
        await activeTask?.value

        XCTAssertFalse(viewModel.isProcessing(conversationID: activeConversation.id))
        XCTAssertTrue(viewModel.isProcessing(conversationID: backgroundConversation.id))

        await backgroundGate.open()
        await waitUntilIdle(backgroundConversation.id, on: viewModel)
        XCTAssertTrue(
            viewModel.conversation(withID: backgroundConversation.id)?.messages.contains {
                $0.role == .agent && $0.content == "background reply"
            } ?? false
        )
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

    func testCancelledDeliveryStateRoundTripsThroughRepository() throws {
        let defaults = makeDefaults()
        let store = try SwiftDataConversationRepository(inMemory: true, defaults: defaults)
        var conversation = Conversation(agentID: "agent-1", agentAddress: address)
        conversation.messages.append(
            ChatMessage(role: .user, content: "stopped", deliveryState: .cancelled)
        )
        store.upsertConversation(conversation)

        let loaded = store.load().conversations.first { $0.id == conversation.id }
        let cancelled = loaded?.messages.first { $0.content == "stopped" }
        XCTAssertEqual(cancelled?.deliveryState, .cancelled)
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

    func testSafeModeWaitsForAllowOnce() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.approvalRequests = [approvalRequest(tool: "write")]

        viewModel.prompt = "Create the prompt"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)

        XCTAssertEqual(viewModel.pendingApproval?.request.tool, "write")
        XCTAssertTrue(viewModel.isProcessing)

        viewModel.allowPendingApprovalOnce(id: viewModel.pendingApproval!.id)
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.approvalDecisions, [.allowOnce])
        XCTAssertNil(viewModel.pendingApproval)
        XCTAssertFalse(viewModel.isProcessing)
    }

    func testSafeModeCanTrustToolForSession() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.approvalRequests = [approvalRequest(tool: "bash")]

        viewModel.prompt = "Run the checks"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)
        viewModel.trustPendingApprovalForSession(id: viewModel.pendingApproval!.id)
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.approvalDecisions, [.allowSession])
        XCTAssertNil(viewModel.pendingApproval)
    }

    func testSafeModeRejectsToolAndContinues() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.approvalRequests = [approvalRequest(tool: "bash")]

        viewModel.prompt = "Run a command"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)
        viewModel.rejectPendingApproval(id: viewModel.pendingApproval!.id)
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.approvalDecisions, [.rejectSoft(feedback: nil)])
        XCTAssertTrue(viewModel.activeConversation?.messages.contains {
            $0.role == .agent && $0.content == "mock reply"
        } ?? false)
    }

    func testPendingApprovalCanOnlyResolveOnce() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.approvalRequests = [approvalRequest(tool: "write")]

        viewModel.prompt = "Create a file"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)
        let approvalID = viewModel.pendingApproval!.id
        viewModel.allowPendingApprovalOnce(id: approvalID)
        viewModel.rejectPendingApproval(id: approvalID)
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.approvalDecisions, [.allowOnce])
    }

    func testStoppingPendingApprovalWaitsForRejectionBeforeCancelling() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.approvalRequests = [approvalRequest(tool: "write")]
        transport.waitAfterInteractionsUntilCancelled = true

        viewModel.prompt = "Create a file"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)
        let conversationID = viewModel.activeConversation!.id
        let task = viewModel.sendTask

        viewModel.stopActiveResponse()
        await task?.value

        XCTAssertEqual(
            transport.approvalDecisions,
            [.rejectHard(feedback: "Approval cancelled.")]
        )
        XCTAssertEqual(transport.interactionResponseWaits.count, 1)
        XCTAssertEqual(transport.interactionResponseWaits.first?.conversationID, conversationID)
        XCTAssertFalse(viewModel.isProcessing)
    }

    func testBackgroundApprovalDoesNotBlockSendingOrStealFocus() async {
        let (viewModel, transport, _) = makeEnvironment()
        let agent = setUpAgentAndConversation(viewModel)
        let approvalConversation = viewModel.activeConversation!
        transport.approvalRequests = [approvalRequest(tool: "write")]

        viewModel.prompt = "Create a file"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)
        let approvalID = viewModel.pendingApproval!.id

        transport.approvalRequests = []
        let secondConversation = viewModel.createConversation(for: agent)
        viewModel.prompt = "Answer here"
        viewModel.sendPrompt()
        await viewModel.sendTask?.value

        XCTAssertEqual(viewModel.activeConversationID, secondConversation.id)
        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertTrue(viewModel.isProcessing(conversationID: approvalConversation.id))
        XCTAssertTrue(viewModel.hasPendingInteraction(forConversationID: approvalConversation.id))
        XCTAssertNil(viewModel.activePendingApproval)
        XCTAssertNil(viewModel.pendingApproval)
        XCTAssertNil(viewModel.pendingPlanReview)
        XCTAssertNil(viewModel.sendTask)
        XCTAssertTrue(viewModel.hasBackgroundPendingInteraction)
        XCTAssertTrue(
            viewModel.conversation(withID: secondConversation.id)?.messages.contains {
                $0.role == .agent && $0.content == "mock reply"
            } ?? false
        )

        viewModel.selectConversation(approvalConversation)
        XCTAssertEqual(viewModel.pendingApproval?.id, approvalID)
        XCTAssertNotNil(viewModel.sendTask)
        viewModel.allowPendingApprovalOnce(id: approvalID)
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.approvalDecisions, [.allowOnce])
        XCTAssertFalse(viewModel.hasPendingInteraction(forConversationID: approvalConversation.id))
        XCTAssertFalse(viewModel.hasBackgroundPendingInteraction)
    }

    func testSameApprovalIDCanWaitInTwoConversationsIndependently() async {
        let (viewModel, transport, _) = makeEnvironment()
        let agent = setUpAgentAndConversation(viewModel)
        let firstConversation = viewModel.activeConversation!
        let sharedRequest = approvalRequest(tool: "write")
        transport.approvalRequests = [sharedRequest]

        viewModel.prompt = "First approval"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)

        let secondConversation = viewModel.createConversation(for: agent)
        viewModel.prompt = "Second approval"
        viewModel.sendPrompt()
        await waitForActivePendingApproval(on: viewModel)

        XCTAssertTrue(viewModel.hasPendingInteraction(forConversationID: firstConversation.id))
        XCTAssertTrue(viewModel.hasPendingInteraction(forConversationID: secondConversation.id))
        XCTAssertEqual(viewModel.activePendingApproval?.id, sharedRequest.id)

        viewModel.allowPendingApprovalOnce(id: sharedRequest.id)
        await viewModel.sendTask?.value
        XCTAssertFalse(viewModel.hasPendingInteraction(forConversationID: secondConversation.id))
        XCTAssertTrue(viewModel.hasPendingInteraction(forConversationID: firstConversation.id))

        viewModel.selectConversation(firstConversation)
        viewModel.rejectPendingApproval(id: sharedRequest.id)
        await viewModel.sendTask?.value

        XCTAssertEqual(
            transport.approvalDecisions,
            [.allowOnce, .rejectSoft(feedback: nil)]
        )
        XCTAssertFalse(viewModel.hasPendingInteraction(forConversationID: firstConversation.id))
    }

    func testPendingApprovalIsScopedToItsConversation() async {
        let (viewModel, transport, _) = makeEnvironment()
        let agent = setUpAgentAndConversation(viewModel)
        let approvalConversation = viewModel.activeConversation!
        transport.approvalRequests = [approvalRequest(tool: "write")]

        viewModel.prompt = "Create a file"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)
        let approvalID = viewModel.pendingApproval!.id

        _ = viewModel.createConversation(for: agent)
        XCTAssertNil(viewModel.activePendingApproval)
        XCTAssertNil(viewModel.pendingApproval)
        XCTAssertNil(viewModel.sendTask)

        viewModel.allowPendingApprovalOnce(id: approvalID)
        XCTAssertTrue(transport.approvalDecisions.isEmpty)
        XCTAssertTrue(viewModel.hasPendingInteraction(forConversationID: approvalConversation.id))

        viewModel.selectConversation(approvalConversation)
        XCTAssertEqual(viewModel.activePendingApproval?.id, approvalID)
        viewModel.allowPendingApprovalOnce(id: approvalID)
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.approvalDecisions, [.allowOnce])
    }

    func testAskUserAnswerResumesTheActiveAgentTurn() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.askUserRequests = [
            AskUserRequest(
                id: "question-1",
                question: "Which environment?",
                options: ["Staging", "Production"]
            ),
        ]

        viewModel.prompt = "Deploy the app"
        viewModel.sendPrompt()
        await waitForPendingAskUser(on: viewModel)

        XCTAssertTrue(viewModel.isProcessing)
        XCTAssertEqual(viewModel.activePendingAskUser?.request.question, "Which environment?")

        viewModel.answerPendingAskUser(id: "question-1", answer: "Staging")
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.askUserAnswers, ["Staging"])
        XCTAssertNil(viewModel.pendingAskUser)
        XCTAssertFalse(viewModel.isProcessing)
    }

    func testPendingAskUserIsScopedToItsConversation() async {
        let (viewModel, transport, _) = makeEnvironment()
        let agent = setUpAgentAndConversation(viewModel)
        let questionConversation = viewModel.activeConversation!
        transport.askUserRequests = [
            AskUserRequest(id: "question-1", question: "Continue?", options: ["Yes", "No"]),
        ]

        viewModel.prompt = "Start task"
        viewModel.sendPrompt()
        await waitForPendingAskUser(on: viewModel)

        _ = viewModel.createConversation(for: agent)
        XCTAssertNil(viewModel.activePendingAskUser)

        viewModel.answerPendingAskUser(id: "question-1", answer: "Yes")
        XCTAssertTrue(transport.askUserAnswers.isEmpty)
        XCTAssertNil(viewModel.pendingAskUser)
        XCTAssertTrue(viewModel.hasPendingInteraction(forConversationID: questionConversation.id))
        XCTAssertTrue(viewModel.hasBackgroundPendingInteraction)

        viewModel.selectConversation(questionConversation)
        viewModel.answerPendingAskUser(id: "question-1", answer: "Yes")
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.askUserAnswers, ["Yes"])
        XCTAssertNil(viewModel.pendingAskUser)
    }

    func testApprovalGateRegistersBeforePresentation() async {
        let gate = ContinuationGate<ApprovalDecision>(
            cancellationDecision: .rejectHard(feedback: "cancelled"),
            unavailableDecision: .rejectHard(feedback: "unavailable")
        )
        var dismissed = false

        let decision = await gate.wait(for: "approval") {
            XCTAssertTrue(gate.resolve(id: "approval", with: .allowOnce))
            return true
        } dismiss: {
            dismissed = true
        }

        XCTAssertEqual(decision, .allowOnce)
        XCTAssertTrue(dismissed)
    }

    func testDeletingConversationCancelsPendingApproval() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.approvalRequests = [approvalRequest(tool: "write")]

        viewModel.prompt = "Create a file"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)
        let conversation = viewModel.activeConversation!
        let task = viewModel.sendTask
        viewModel.deleteConversation(conversation)
        await task?.value

        XCTAssertNil(viewModel.pendingApproval)
        XCTAssertNil(viewModel.conversation(withID: conversation.id))
        XCTAssertEqual(
            transport.approvalDecisions,
            [.rejectHard(feedback: "Approval cancelled.")]
        )
    }

    func testEveryModeWaitsForUserApproval() async {
        for mode in ChatMode.allCases {
            let (viewModel, transport, _) = makeEnvironment()
            setUpAgentAndConversation(viewModel)
            viewModel.setMode(mode)
            transport.approvalRequests = [approvalRequest(tool: "credit_card_charge")]

            viewModel.prompt = "Charge the card"
            viewModel.sendPrompt()
            await waitForPendingApproval(on: viewModel)

            XCTAssertEqual(viewModel.pendingApproval?.request.tool, "credit_card_charge")
            XCTAssertTrue(transport.approvalDecisions.isEmpty, "\(mode.label) resolved approval automatically")

            viewModel.rejectPendingApproval(id: viewModel.pendingApproval!.id)
            await viewModel.sendTask?.value
            XCTAssertEqual(transport.approvalDecisions, [.rejectSoft(feedback: nil)])
        }
    }

    func testApprovalSupportsStopAndExplain() async {
        for expected in [
            ApprovalDecision.rejectHard(feedback: "Approval cancelled."),
            ApprovalDecision.rejectExplain(feedback: nil),
        ] {
            let (viewModel, transport, _) = makeEnvironment()
            setUpAgentAndConversation(viewModel)
            transport.approvalRequests = [approvalRequest(tool: "bash")]

            viewModel.prompt = "Run a command"
            viewModel.sendPrompt()
            await waitForPendingApproval(on: viewModel)
            let id = viewModel.pendingApproval!.id
            if expected == .rejectHard(feedback: "Approval cancelled.") {
                viewModel.stopPendingApproval(id: id)
            } else {
                viewModel.explainPendingApproval(id: id)
            }
            await viewModel.sendTask?.value

            XCTAssertEqual(transport.approvalDecisions, [expected])
        }
    }

    func testPlanReviewWaitsForApproval() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        viewModel.setMode(.plan)
        transport.planReviews = [PlanReviewRequest(planContent: "# Plan")]

        viewModel.prompt = "Plan the change"
        viewModel.sendPrompt()
        await waitForPlanReview(on: viewModel)
        XCTAssertTrue(transport.planReviewDecisions.isEmpty)

        viewModel.approvePendingPlan(id: viewModel.pendingPlanReview!.id)
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.planReviewDecisions, [.approve])
    }

    func testPlanReviewSendsRevisionFeedback() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.planReviews = [PlanReviewRequest(planContent: "# Plan")]

        viewModel.prompt = "Plan the change"
        viewModel.sendPrompt()
        await waitForPlanReview(on: viewModel)
        viewModel.requestPlanChanges(
            id: viewModel.pendingPlanReview!.id,
            feedback: "Use smaller commits"
        )
        await viewModel.sendTask?.value

        XCTAssertEqual(
            transport.planReviewDecisions,
            [.requestChanges(feedback: "Use smaller commits")]
        )
    }

    func testStoppingPendingPlanReviewWaitsForResponseBeforeCancelling() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.planReviews = [PlanReviewRequest(planContent: "# Plan")]
        transport.waitAfterInteractionsUntilCancelled = true

        viewModel.prompt = "Plan the change"
        viewModel.sendPrompt()
        await waitForPlanReview(on: viewModel)
        let conversationID = viewModel.activeConversation!.id
        let task = viewModel.sendTask

        viewModel.stopActiveResponse()
        await task?.value

        XCTAssertEqual(
            transport.planReviewDecisions,
            [.requestChanges(feedback: "Plan review cancelled.")]
        )
        XCTAssertEqual(transport.interactionResponseWaits.count, 1)
        XCTAssertEqual(transport.interactionResponseWaits.first?.conversationID, conversationID)
        XCTAssertFalse(viewModel.isProcessing)
    }

    func testPendingPlanReviewIsScopedToItsConversation() async {
        let (viewModel, transport, _) = makeEnvironment()
        let agent = setUpAgentAndConversation(viewModel)
        let reviewConversation = viewModel.activeConversation!
        transport.planReviews = [PlanReviewRequest(planContent: "# Plan")]

        viewModel.prompt = "Plan the change"
        viewModel.sendPrompt()
        await waitForPlanReview(on: viewModel)
        let reviewID = viewModel.pendingPlanReview!.id

        _ = viewModel.createConversation(for: agent)
        XCTAssertNil(viewModel.activePendingPlanReview)
        XCTAssertNil(viewModel.pendingPlanReview)
        XCTAssertNil(viewModel.sendTask)

        viewModel.approvePendingPlan(id: reviewID)
        XCTAssertTrue(transport.planReviewDecisions.isEmpty)
        XCTAssertTrue(viewModel.hasPendingInteraction(forConversationID: reviewConversation.id))

        viewModel.selectConversation(reviewConversation)
        XCTAssertEqual(viewModel.activePendingPlanReview?.id, reviewID)
        viewModel.approvePendingPlan(id: reviewID)
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.planReviewDecisions, [.approve])
    }

    func testDeletingConversationCancelsPlanReview() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.planReviews = [PlanReviewRequest(planContent: "# Plan")]

        viewModel.prompt = "Plan the change"
        viewModel.sendPrompt()
        await waitForPlanReview(on: viewModel)
        let conversation = viewModel.activeConversation!
        let task = viewModel.sendTask
        viewModel.deleteConversation(conversation)
        await task?.value

        XCTAssertNil(viewModel.pendingPlanReview)
        XCTAssertEqual(
            transport.planReviewDecisions,
            [.requestChanges(feedback: "Plan review cancelled.")]
        )
    }

    func testDeletingAgentCancelsPendingApproval() async {
        let (viewModel, transport, _) = makeEnvironment()
        let agent = setUpAgentAndConversation(viewModel)
        transport.approvalRequests = [approvalRequest(tool: "write")]

        viewModel.prompt = "Create a file"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)
        let task = viewModel.sendTask
        viewModel.deleteAgent(agent)
        await task?.value

        XCTAssertNil(viewModel.pendingApproval)
        XCTAssertEqual(
            transport.approvalDecisions,
            [.rejectHard(feedback: "Approval cancelled.")]
        )
    }

    func testCancellingSendTaskCancelsPendingApproval() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.approvalRequests = [approvalRequest(tool: "write")]

        viewModel.prompt = "Create a file"
        viewModel.sendPrompt()
        await waitForPendingApproval(on: viewModel)
        viewModel.sendTask?.cancel()
        await viewModel.sendTask?.value

        XCTAssertNil(viewModel.pendingApproval)
        XCTAssertEqual(
            transport.approvalDecisions,
            [.rejectHard(feedback: "Approval cancelled.")]
        )
    }

    func testViewModelTeardownCancelsPendingApproval() async {
        let store = try! SwiftDataConversationRepository(inMemory: true, defaults: makeDefaults())
        let transport = MockAgentTransport()
        let monitor = MockNetworkMonitor()
        var viewModel: ChatViewModel? = ChatViewModel(store: store, client: transport, networkMonitor: monitor)
        weak let releasedViewModel = viewModel
        setUpAgentAndConversation(viewModel!)
        transport.approvalRequests = [approvalRequest(tool: "write")]

        viewModel?.prompt = "Create a file"
        viewModel?.sendPrompt()
        await waitForPendingApproval(on: viewModel!)
        viewModel = nil
        for _ in 0..<100 where releasedViewModel != nil {
            await Task.yield()
        }
        for _ in 0..<100 where transport.approvalDecisions.isEmpty {
            await Task.yield()
        }

        XCTAssertNil(releasedViewModel)
        XCTAssertEqual(
            transport.approvalDecisions,
            [.rejectHard(feedback: "Approval cancelled.")]
        )
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

    func testSlashPickerLoadsSortsAndFiltersServerSkills() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.availableSkills = [
            AgentSkill(name: "Review", description: "Review current changes"),
            AgentSkill(name: "commit", description: "Create a commit"),
            AgentSkill(name: "release", description: "Prepare a release"),
        ]

        viewModel.prompt = "/"
        viewModel.promptDidChange()
        await waitForSkillFetch(on: viewModel, transport: transport)

        XCTAssertEqual(viewModel.slashSkillSuggestions.map(\.name), ["commit", "release", "Review"])
        XCTAssertTrue(viewModel.shouldShowSlashSkillPicker)

        viewModel.prompt = "/RE"
        viewModel.promptDidChange()
        XCTAssertEqual(viewModel.slashSkillSuggestions.map(\.name), ["release", "Review"])

        viewModel.prompt = "/review details"
        viewModel.promptDidChange()
        XCTAssertTrue(viewModel.slashSkillSuggestions.isEmpty)
        XCTAssertFalse(viewModel.shouldShowSlashSkillPicker)
        XCTAssertEqual(transport.fetchedSkillAddresses.count, 1)
    }

    func testSelectingSlashSkillInsertsCommandWithArgumentSpace() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.availableSkills = [AgentSkill(name: "commit", description: "Create a commit")]
        viewModel.prompt = "/"
        viewModel.promptDidChange()
        await waitForSkillFetch(on: viewModel, transport: transport)

        viewModel.selectSlashSkill(viewModel.slashSkillSuggestions[0])

        XCTAssertEqual(viewModel.prompt, "/commit ")
        XCTAssertFalse(viewModel.shouldShowSlashSkillPicker)
    }

    func testSlashDiscoveryFailureKeepsRawCommandSendable() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.skillFetchError = HostedAgentClientError.server("metadata unavailable")
        viewModel.prompt = "/unknown"
        viewModel.promptDidChange()
        await waitForSkillFetchAttempt(transport: transport)

        XCTAssertFalse(viewModel.shouldShowSlashSkillPicker)
        XCTAssertNil(viewModel.errorMessage)

        viewModel.sendPrompt()
        await waitForSentPrompt(transport: transport)
        XCTAssertEqual(transport.sentPrompts, ["/unknown"])
    }

    func testSlashSuggestionsFollowActiveAgentWithoutStaleResults() async {
        let (viewModel, transport, _) = makeEnvironment()
        let first = setUpAgentAndConversation(viewModel)
        let secondAddress = "0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
        let second = viewModel.saveAgent(name: "Second", address: secondAddress, token: "")!
        _ = viewModel.createConversation(for: second)
        transport.skillsByAddress = [
            first.address: [AgentSkill(name: "first")],
            second.address: [AgentSkill(name: "second")],
        ]

        viewModel.prompt = "/"
        viewModel.promptDidChange()
        await waitForSkillFetch(on: viewModel, transport: transport)
        XCTAssertEqual(viewModel.slashSkillSuggestions.map(\.name), ["second"])

        viewModel.selectAgent(first)
        await waitForSkillFetch(on: viewModel, transport: transport, address: first.address)
        XCTAssertEqual(viewModel.slashSkillSuggestions.map(\.name), ["first"])
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "OOChatIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func approvalRequest(tool: String) -> ToolApprovalRequest {
        ToolApprovalRequest(
            id: "approval-\(tool)",
            tool: tool,
            arguments: ["path": .string("prompt.md")]
        )
    }

    private func waitForPendingApproval(on viewModel: ChatViewModel) async {
        for _ in 0..<100 where viewModel.pendingApproval == nil {
            await Task.yield()
        }
        XCTAssertNotNil(viewModel.pendingApproval)
    }

    private func waitForActivePendingApproval(on viewModel: ChatViewModel) async {
        for _ in 0..<100 where viewModel.activePendingApproval == nil {
            await Task.yield()
        }
        XCTAssertNotNil(viewModel.activePendingApproval)
    }

    private func waitForPendingAskUser(on viewModel: ChatViewModel) async {
        for _ in 0..<100 where viewModel.pendingAskUser == nil {
            await Task.yield()
        }
        XCTAssertNotNil(viewModel.pendingAskUser)
    }

    private func waitForPlanReview(on viewModel: ChatViewModel) async {
        for _ in 0..<100 where viewModel.pendingPlanReview == nil {
            await Task.yield()
        }
        XCTAssertNotNil(viewModel.pendingPlanReview)
    }

    private func waitForSkillFetch(
        on viewModel: ChatViewModel,
        transport: MockAgentTransport,
        address: String? = nil
    ) async {
        for _ in 0..<100 {
            if let address {
                if transport.fetchedSkillAddresses.contains(address), !viewModel.slashSkillSuggestions.isEmpty {
                    return
                }
            } else if !transport.fetchedSkillAddresses.isEmpty, !viewModel.slashSkillSuggestions.isEmpty {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for slash skills")
    }

    private func waitForSkillFetchAttempt(transport: MockAgentTransport) async {
        for _ in 0..<100 where transport.fetchedSkillAddresses.isEmpty {
            await Task.yield()
        }
        XCTAssertFalse(transport.fetchedSkillAddresses.isEmpty)
    }

    private func waitForSentPrompt(transport: MockAgentTransport) async {
        for _ in 0..<100 where transport.sentPrompts.isEmpty {
            await Task.yield()
        }
        XCTAssertFalse(transport.sentPrompts.isEmpty)
    }

    private func waitForSentPrompt(_ prompt: String, transport: MockAgentTransport) async {
        for _ in 0..<100 where !transport.sentPrompts.contains(prompt) {
            await Task.yield()
        }
        XCTAssertTrue(transport.sentPrompts.contains(prompt))
    }

    private func waitUntilIdle(_ conversationID: String, on viewModel: ChatViewModel) async {
        for _ in 0..<100 where viewModel.isProcessing(conversationID: conversationID) {
            await Task.yield()
        }
        XCTAssertFalse(viewModel.isProcessing(conversationID: conversationID))
    }

    @discardableResult
    private func setUpAgentAndConversation(_ viewModel: ChatViewModel) -> AgentConnection {
        let agent = viewModel.saveAgent(name: "Recovery Agent", address: address, token: "")!
        _ = viewModel.createConversation(for: agent)
        return agent
    }
}
