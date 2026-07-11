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
    var approvalRequests: [ToolApprovalRequest] = []
    var ulwCheckpoints: [UlwCheckpointRequest] = []
    var planReviews: [PlanReviewRequest] = []
    var onSend: (@MainActor () -> Void)?

    private(set) var connectedAddresses: [String] = []
    private(set) var sentPrompts: [String] = []
    private(set) var approvalDecisions: [ApprovalDecision] = []
    private(set) var ulwDecisions: [UlwCheckpointDecision] = []
    private(set) var planReviewDecisions: [PlanReviewDecision] = []

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
        onEvent: (@MainActor (HostedAgentEvent) -> Void)?,
        onApprovalRequest: (@MainActor (ToolApprovalRequest) async -> ApprovalDecision)?,
        onUlwCheckpoint: (@MainActor (UlwCheckpointRequest) async -> UlwCheckpointDecision)?,
        onPlanReview: (@MainActor (PlanReviewRequest) async -> PlanReviewDecision)?
    ) async throws -> HostedAgentResult {
        sentPrompts.append(prompt)
        switch sendBehavior {
        case .succeed(let output):
            for request in approvalRequests {
                guard let onApprovalRequest else {
                    throw HostedAgentClientError.badFrame
                }
                approvalDecisions.append(await onApprovalRequest(request))
            }
            for checkpoint in ulwCheckpoints {
                guard let onUlwCheckpoint else {
                    throw HostedAgentClientError.badFrame
                }
                ulwDecisions.append(await onUlwCheckpoint(checkpoint))
            }
            for review in planReviews {
                guard let onPlanReview else {
                    throw HostedAgentClientError.badFrame
                }
                planReviewDecisions.append(await onPlanReview(review))
            }
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
        viewModel.deleteConversation(conversation)
        await viewModel.sendTask?.value

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

    func testSelectingUlwMarksSessionAsNewerAndPendingPropagation() {
        let (viewModel, _, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        let selectedAt = Date().timeIntervalSince1970

        viewModel.setMode(.ulw)

        let session = viewModel.activeConversation?.serverSession
        XCTAssertEqual(session?["mode"], .string("ulw"))
        XCTAssertEqual(session?["skip_tool_approval"], .bool(true))
        XCTAssertEqual(session?["ulw_turns"], .number(100))
        XCTAssertEqual(session?["ulw_turns_used"], .number(0))
        XCTAssertEqual(
            session?[ClientSessionMetadata.pendingModeChange],
            .string("ulw")
        )
        XCTAssertGreaterThanOrEqual(session?["updated"]?.numberValue ?? 0, selectedAt)
    }

    func testLeavingUlwClearsAutonomousSessionState() {
        let (viewModel, _, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        viewModel.setMode(.ulw)
        var conversation = viewModel.activeConversation!
        conversation.serverSession?["skip_tool_approval"] = .bool(true)
        viewModel.conversations[viewModel.conversations.firstIndex(where: { $0.id == conversation.id })!] = conversation

        viewModel.setMode(.safe)

        let session = viewModel.activeConversation?.serverSession
        XCTAssertEqual(session?["mode"], .string("safe"))
        XCTAssertEqual(
            session?[ClientSessionMetadata.pendingModeChange],
            .string("safe")
        )
        XCTAssertNil(session?["ulw_turns"])
        XCTAssertNil(session?["ulw_turns_used"])
        XCTAssertNil(session?["skip_tool_approval"])
    }

    func testPendingModeChangeIsSentOnlyToRunningSession() {
        let (viewModel, _, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        viewModel.setMode(.ulw)
        let conversation = viewModel.activeConversation!

        XCTAssertNil(
            HostedAgentClient.pendingModeChangeFrame(
                for: conversation,
                connectionStatus: "connected"
            )
        )
        XCTAssertEqual(
            HostedAgentClient.pendingModeChangeFrame(
                for: conversation,
                connectionStatus: "running"
            ),
            [
                "type": .string("mode_change"),
                "mode": .string("ulw"),
                "turns": .number(100),
            ]
        )
    }

    func testApprovalSupportsStopAndExplain() async {
        for expected in [
            ApprovalDecision.rejectHard(feedback: nil),
            ApprovalDecision.rejectExplain(feedback: nil),
        ] {
            let (viewModel, transport, _) = makeEnvironment()
            setUpAgentAndConversation(viewModel)
            transport.approvalRequests = [approvalRequest(tool: "bash")]

            viewModel.prompt = "Run a command"
            viewModel.sendPrompt()
            await waitForPendingApproval(on: viewModel)
            let id = viewModel.pendingApproval!.id
            if expected == .rejectHard(feedback: nil) {
                viewModel.stopPendingApproval(id: id)
            } else {
                viewModel.explainPendingApproval(id: id)
            }
            await viewModel.sendTask?.value

            XCTAssertEqual(transport.approvalDecisions, [expected])
        }
    }

    func testUlwCheckpointWaitsForContinueDecision() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        viewModel.setMode(.ulw)
        transport.ulwCheckpoints = [UlwCheckpointRequest(turnsUsed: 100, maxTurns: 100)]

        viewModel.prompt = "Keep working"
        viewModel.sendPrompt()
        await waitForUlwCheckpoint(on: viewModel)
        XCTAssertTrue(transport.ulwDecisions.isEmpty)

        viewModel.continueUlw(id: viewModel.pendingUlwCheckpoint!.id)
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.ulwDecisions, [.continueWork(turns: 100)])
        XCTAssertEqual(viewModel.activeMode, .ulw)
    }

    func testUlwCheckpointCanSwitchToAcceptEdits() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        viewModel.setMode(.ulw)
        transport.ulwCheckpoints = [UlwCheckpointRequest(turnsUsed: 100, maxTurns: 100)]

        viewModel.prompt = "Keep working"
        viewModel.sendPrompt()
        await waitForUlwCheckpoint(on: viewModel)
        viewModel.switchModeFromUlwCheckpoint(id: viewModel.pendingUlwCheckpoint!.id, to: .accept)
        await viewModel.sendTask?.value

        XCTAssertEqual(transport.ulwDecisions, [.switchMode(.accept)])
        XCTAssertEqual(viewModel.activeMode, .accept)
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

    func testDeletingConversationCancelsUlwCheckpoint() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.ulwCheckpoints = [UlwCheckpointRequest(turnsUsed: 100, maxTurns: 100)]

        viewModel.prompt = "Keep working"
        viewModel.sendPrompt()
        await waitForUlwCheckpoint(on: viewModel)
        let conversation = viewModel.activeConversation!
        viewModel.deleteConversation(conversation)
        await viewModel.sendTask?.value

        XCTAssertNil(viewModel.pendingUlwCheckpoint)
        XCTAssertEqual(transport.ulwDecisions, [.switchMode(.safe)])
    }

    func testDeletingConversationCancelsPlanReview() async {
        let (viewModel, transport, _) = makeEnvironment()
        setUpAgentAndConversation(viewModel)
        transport.planReviews = [PlanReviewRequest(planContent: "# Plan")]

        viewModel.prompt = "Plan the change"
        viewModel.sendPrompt()
        await waitForPlanReview(on: viewModel)
        let conversation = viewModel.activeConversation!
        viewModel.deleteConversation(conversation)
        await viewModel.sendTask?.value

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
        viewModel.deleteAgent(agent)
        await viewModel.sendTask?.value

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

    private func waitForUlwCheckpoint(on viewModel: ChatViewModel) async {
        for _ in 0..<100 where viewModel.pendingUlwCheckpoint == nil {
            await Task.yield()
        }
        XCTAssertNotNil(viewModel.pendingUlwCheckpoint)
    }

    private func waitForPlanReview(on viewModel: ChatViewModel) async {
        for _ in 0..<100 where viewModel.pendingPlanReview == nil {
            await Task.yield()
        }
        XCTAssertNotNil(viewModel.pendingPlanReview)
    }

    @discardableResult
    private func setUpAgentAndConversation(_ viewModel: ChatViewModel) -> AgentConnection {
        let agent = viewModel.saveAgent(name: "Recovery Agent", address: address, token: "")!
        _ = viewModel.createConversation(for: agent)
        return agent
    }
}
