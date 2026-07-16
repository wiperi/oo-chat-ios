import XCTest
@testable import OOChatIOS

final class MockHostedAgentTests: XCTestCase {
    private let endpointA = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let endpointB = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    private struct MockHostedAgent {
        let replyText: String

        func reply(to prompt: String) -> ChatMessage {
            ChatMessage(role: .agent, content: "Mock reply to '\(prompt)': \(replyText)")
        }
    }

    func testMockAgentReplyCreatesAgentMessage() {
        let agent = MockHostedAgent(replyText: "hello from test")

        let message = agent.reply(to: "ping")

        XCTAssertEqual(message.role, .agent)
        XCTAssertTrue(message.content.contains("ping"))
        XCTAssertTrue(message.content.contains("hello from test"))
        XCTAssertFalse(message.id.isEmpty)
    }

    func testNewConversationStartsWithDefaultAgentMessage() {
        let conversation = Conversation()

        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.first?.role, .agent)
        XCTAssertEqual(conversation.messages.first?.content, Conversation.defaultInitialMessage)
    }

    func testAgentConnectionDecodesLegacyPayloadWithoutToken() throws {
        let json = """
        {
          "id": "agent-1",
          "name": "Legacy",
          "address": "\(endpointA)",
          "createdAt": "2026-07-09T01:00:00Z",
          "updatedAt": "2026-07-09T01:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let agent = try decoder.decode(AgentConnection.self, from: Data(json.utf8))

        XCTAssertEqual(agent.name, "Legacy")
        XCTAssertEqual(agent.address, endpointA)
        XCTAssertEqual(agent.token, "")
    }

    func testAgentInfoDecodesDirectAndRelayAdvertisedSkills() throws {
        let direct = try JSONDecoder().decode(AgentInfo.self, from: Data("""
        {
          "address": "\(endpointA)",
          "name": "Local agent",
          "skills": [
            {"name": "review", "description": "Review the current changes", "location": "project"}
          ]
        }
        """.utf8))
        let relay = try JSONDecoder().decode(AgentInfo.self, from: Data("""
        {
          "endpoints": ["https://agent.example"],
          "profile": {
            "alias": "Relay agent",
            "skills": [
              {"name": "commit", "description": "Create a commit"}
            ]
          }
        }
        """.utf8))

        XCTAssertEqual(
            direct.advertisedSkills,
            [AgentSkill(name: "review", description: "Review the current changes", location: "project")]
        )
        XCTAssertEqual(
            relay.advertisedSkills,
            [AgentSkill(name: "commit", description: "Create a commit")]
        )
    }

    func testAgentInfoTreatsMissingSkillDescriptionsAsEmpty() throws {
        let info = try JSONDecoder().decode(AgentInfo.self, from: Data("""
        {"skills": [{"name": "status"}]}
        """.utf8))

        XCTAssertEqual(info.advertisedSkills, [AgentSkill(name: "status")])
    }

    func testToolCallFramesMapToCorrelatedCallAndResultEvents() {
        let arguments: [String: JSONValue] = [
            "path": .string("OOChatIOS/Features/Chat/MessageBubble.swift"),
            "line_end": .number(280),
        ]

        let call = HostedAgentEvent.from([
            "type": .string("tool_call"),
            "tool_id": .string("tool-read-1"),
            "name": .string("read_file"),
            "args": .object(arguments),
        ])
        let result = HostedAgentEvent.from([
            "type": .string("tool_result"),
            "tool_id": .string("tool-read-1"),
            "name": .string("read_file"),
            "result": .string("import SwiftUI"),
        ])

        XCTAssertEqual(
            call,
            .toolCall(id: "tool-read-1", name: "read_file", arguments: arguments)
        )
        XCTAssertEqual(
            result,
            .toolResult(
                id: "tool-read-1",
                name: "read_file",
                output: "import SwiftUI",
                state: .completed
            )
        )
    }

    func testLargeToolArgumentDoesNotTrapWhenRendered() {
        let arguments: [String: JSONValue] = [
            "n": .number(1e20),
        ]

        XCTAssertEqual(ToolActionSummary.argumentsDescription(arguments), "n: 1e+20")
        XCTAssertEqual(CanonicalJSON.string(from: .number(1e20)), "1e+20")
    }

    func testToolResultUsesErrorStateAndMessageFallback() {
        let event = HostedAgentEvent.from([
            "type": .string("tool_result"),
            "id": .string("tool-shell-1"),
            "status": .string("error"),
            "message": .string("Permission denied"),
        ])

        XCTAssertEqual(
            event,
            .toolResult(
                id: "tool-shell-1",
                name: nil,
                output: "Permission denied",
                state: .failed
            )
        )
    }

    func testToolResultPreservesStructuredOutput() {
        let event = HostedAgentEvent.from([
            "type": .string("tool_result"),
            "tool_id": .string("tool-search-1"),
            "result": .object([
                "files": .array([.string("README.md")]),
            ]),
        ])

        guard case .toolResult(_, _, let output, _) = event else {
            return XCTFail("Expected a tool result event")
        }
        XCTAssertTrue(output.contains("files"))
        XCTAssertTrue(output.contains("README.md"))
    }

    func testToolEventParserIgnoresFramesWithoutCallIdentifiers() {
        XCTAssertNil(HostedAgentEvent.from([
            "type": .string("tool_call"),
            "name": .string("read_file"),
        ]))
    }

    func testApprovalFrameMapsToRequest() {
        let request = ToolApprovalRequest.from([
            "type": .string("approval_needed"),
            "approval_id": .string("approval-1"),
            "tool": .string("write"),
            "arguments": .object([
                "path": .string("prompt.md"),
                "content": .string("You are a summarizer."),
            ]),
            "description": .string("Create the agent prompt"),
            "batch_remaining": .array([
                .object([
                    "tool": .string("bash"),
                    "arguments": .string(#"{"command":"swift test"}"#),
                ]),
                .object([
                    "tool": .string("notify"),
                    "arguments": .string("not-json"),
                ]),
            ]),
        ])

        XCTAssertEqual(
            request,
            ToolApprovalRequest(
                id: "approval-1",
                tool: "write",
                arguments: [
                    "path": .string("prompt.md"),
                    "content": .string("You are a summarizer."),
                ],
                description: "Create the agent prompt",
                batchRemaining: [
                    ToolApprovalBatchItem(
                        tool: "bash",
                        arguments: ["command": .string("swift test")]
                    ),
                    ToolApprovalBatchItem(
                        tool: "notify",
                        rawArguments: .string("not-json")
                    ),
                ]
            )
        )
    }

    func testApprovalFrameAcceptsArgsAliasAndCreatesLocalIdentifier() {
        let request = ToolApprovalRequest.from([
            "type": .string("APPROVAL_NEEDED"),
            "tool": .string("edit"),
            "args": .object(["path": .string("README.md")]),
        ])

        XCTAssertEqual(request?.tool, "edit")
        XCTAssertEqual(request?.arguments, ["path": .string("README.md")])
        XCTAssertFalse(request?.id.isEmpty ?? true)
    }

    func testApprovalFrameRejectsMissingToolOrInvalidArguments() {
        XCTAssertNil(ToolApprovalRequest.from([
            "type": .string("approval_needed"),
            "arguments": .object([:]),
        ]))
        XCTAssertNil(ToolApprovalRequest.from([
            "type": .string("approval_needed"),
            "tool": .string("write"),
            "arguments": .string("prompt.md"),
        ]))
    }

    func testApprovalDecisionsEncodeProtocolFrames() {
        XCTAssertEqual(
            ApprovalDecision.allowOnce.responseFrame,
            [
                "type": .string("APPROVAL_RESPONSE"),
                "approved": .bool(true),
                "scope": .string("once"),
            ]
        )
        XCTAssertEqual(
            ApprovalDecision.allowSession.responseFrame,
            [
                "type": .string("APPROVAL_RESPONSE"),
                "approved": .bool(true),
                "scope": .string("session"),
            ]
        )
        XCTAssertEqual(
            ApprovalDecision.rejectSoft(feedback: "Use a different file").responseFrame,
            [
                "type": .string("APPROVAL_RESPONSE"),
                "approved": .bool(false),
                "scope": .string("once"),
                "mode": .string("reject_soft"),
                "feedback": .string("Use a different file"),
            ]
        )
        XCTAssertEqual(
            ApprovalDecision.rejectHard(feedback: nil).responseFrame,
            [
                "type": .string("APPROVAL_RESPONSE"),
                "approved": .bool(false),
                "scope": .string("once"),
                "mode": .string("reject_hard"),
            ]
        )
        XCTAssertEqual(
            ApprovalDecision.rejectExplain(feedback: nil).responseFrame,
            [
                "type": .string("APPROVAL_RESPONSE"),
                "approved": .bool(false),
                "scope": .string("once"),
                "mode": .string("reject_explain"),
            ]
        )

        let relayEndpoint = ResolvedEndpoint(
            wsURL: URL(string: "wss://relay.example/ws/input")!,
            kind: .relay,
            label: "relay"
        )
        let directEndpoint = ResolvedEndpoint(
            wsURL: URL(string: "ws://127.0.0.1:8000/ws")!,
            kind: .direct,
            label: "local"
        )

        XCTAssertEqual(
            HostedAgentClient.approvalResponseFrame(
                decision: .allowOnce,
                agentAddress: endpointA,
                endpoint: relayEndpoint
            ),
            [
                "type": .string("APPROVAL_RESPONSE"),
                "approved": .bool(true),
                "scope": .string("once"),
                "to": .string(endpointA),
            ]
        )
        XCTAssertNil(HostedAgentClient.approvalResponseFrame(
            decision: .allowOnce,
            agentAddress: endpointA,
            endpoint: directEndpoint
        )["to"])
    }

    func testPlanReviewFramesMatchUpstreamContract() {
        let request = PlanReviewRequest.from([
            "type": .string("plan_review"),
            "plan_content": .string("# Plan\n\n1. Implement"),
        ])
        XCTAssertEqual(request?.planContent, "# Plan\n\n1. Implement")

        XCTAssertEqual(
            PlanReviewDecision.approve.responseFrame(for: request!),
            [
                "type": .string("PLAN_REVIEW_RESPONSE"),
                "message": .string("Plan approved. Implement now. Do NOT re-enter plan mode.\n\n---\n\n# Plan\n\n1. Implement"),
            ]
        )
        XCTAssertEqual(
            PlanReviewDecision.requestChanges(feedback: "Use smaller commits").responseFrame(for: request!),
            [
                "type": .string("PLAN_REVIEW_RESPONSE"),
                "message": .string("Plan rejected. Revise with write_plan(). Feedback: Use smaller commits"),
            ]
        )
    }

    func testAskUserFrameMapsAllSupportedInputShapes() {
        let request = AskUserRequest.from([
            "type": .string("ask_user"),
            "id": .string("question-1"),
            "question": .string("Enter your login"),
            "options": .array([.string("Use saved account")]),
            "multi_select": .bool(true),
            "fields": .array([
                .object([
                    "name": .string("username"),
                    "label": .string("Username"),
                    "type": .string("text"),
                    "placeholder": .string("name@example.com"),
                ]),
                .object([
                    "name": .string("password"),
                    "label": .string("Password"),
                    "type": .string("password"),
                ]),
            ]),
        ])

        XCTAssertEqual(
            request,
            AskUserRequest(
                id: "question-1",
                question: "Enter your login",
                options: ["Use saved account"],
                multiSelect: true,
                fields: [
                    AskUserField(
                        name: "username",
                        label: "Username",
                        placeholder: "name@example.com"
                    ),
                    AskUserField(name: "password", label: "Password", type: "password"),
                ]
            )
        )
        XCTAssertTrue(request?.fields.last?.isSecure ?? false)
    }

    func testAskUserFrameAcceptsLegacyTextAndDefaultsOptionalValues() {
        let request = AskUserRequest.from([
            "type": .string("ask_user"),
            "text": .string("Which date?"),
        ])

        XCTAssertEqual(request?.question, "Which date?")
        XCTAssertEqual(request?.options, [])
        XCTAssertEqual(request?.fields, [])
        XCTAssertEqual(request?.multiSelect, false)
        XCTAssertFalse(request?.id.isEmpty ?? true)
    }

    func testAskUserRejectsMissingQuestionAndEncodesResponseForEndpoint() {
        XCTAssertNil(AskUserRequest.from([
            "type": .string("ask_user"),
            "options": .array([.string("Yes")]),
        ]))

        let relayEndpoint = ResolvedEndpoint(
            wsURL: URL(string: "wss://relay.example/ws/input")!,
            kind: .relay,
            label: "relay"
        )
        let directEndpoint = ResolvedEndpoint(
            wsURL: URL(string: "ws://127.0.0.1:8000/ws")!,
            kind: .direct,
            label: "local"
        )

        XCTAssertEqual(
            HostedAgentClient.askUserResponseFrame(
                answer: #"{"username":"me","password":"secret"}"#,
                agentAddress: endpointA,
                endpoint: relayEndpoint
            ),
            [
                "answer": .string(#"{"username":"me","password":"secret"}"#),
                "to": .string(endpointA),
            ]
        )
        XCTAssertEqual(
            HostedAgentClient.askUserResponseFrame(
                answer: "red, blue",
                agentAddress: endpointA,
                endpoint: directEndpoint
            ),
            ["answer": .string("red, blue")]
        )
    }

    @MainActor
    func testSaveAgentUpdatesTokenEndpointAndClearsSessions() {
        let viewModel = makeViewModel()
        let agent = viewModel.saveAgent(name: "Primary", address: endpointA, token: "old-token")
        XCTAssertNotNil(agent)
        let conversation = viewModel.createConversation(for: agent!)
        let conversationIndex = viewModel.conversations.firstIndex { $0.id == conversation.id }
        XCTAssertNotNil(conversationIndex)
        viewModel.conversations[conversationIndex!].serverSession = ["session_id": .string("old")]

        let updated = viewModel.saveAgent(id: agent!.id, name: "Renamed", address: endpointB, token: "new-token")

        XCTAssertEqual(updated?.id, agent?.id)
        XCTAssertEqual(updated?.name, "Renamed")
        XCTAssertEqual(updated?.address, endpointB)
        XCTAssertEqual(updated?.token, "new-token")
        XCTAssertEqual(viewModel.conversations.first?.agentID, agent?.id)
        XCTAssertEqual(viewModel.conversations.first?.agentAddress, endpointB)
        XCTAssertNil(viewModel.conversations.first?.serverSession)
    }

    @MainActor
    func testDuplicateEndpointsRemainDistinctConfigurations() {
        let viewModel = makeViewModel()

        let first = viewModel.saveAgent(name: "First", address: endpointA, token: "token-one")
        let second = viewModel.saveAgent(name: "Second", address: endpointA, token: "token-two")

        XCTAssertNotEqual(first?.id, second?.id)
        XCTAssertEqual(viewModel.agents.count, 2)
        XCTAssertEqual(Set(viewModel.agents.map(\.token)), ["token-one", "token-two"])
    }

    @MainActor
    func testDeletingAgentRemovesCredentialsAndConversations() {
        let viewModel = makeViewModel()
        let first = viewModel.saveAgent(name: "First", address: endpointA, token: "token-one")!
        let second = viewModel.saveAgent(name: "Second", address: endpointB, token: "token-two")!
        let deletedConversation = viewModel.createConversation(for: first)
        let remainingConversation = viewModel.createConversation(for: second)

        viewModel.deleteAgent(first)

        XCTAssertFalse(viewModel.agents.contains { $0.id == first.id || $0.token == "token-one" })
        XCTAssertFalse(viewModel.conversations.contains { $0.id == deletedConversation.id })
        XCTAssertTrue(viewModel.conversations.contains { $0.id == remainingConversation.id })
        XCTAssertEqual(viewModel.activeAgentID, second.id)
    }

    @MainActor
    func testSwitchToAgentForChatCreatesConversationWhenMissing() {
        let viewModel = makeViewModel()
        let agent = viewModel.saveAgent(name: "Primary", address: endpointA, token: "")!

        viewModel.switchToAgentForChat(agent)

        XCTAssertEqual(viewModel.activeAgentID, agent.id)
        XCTAssertEqual(viewModel.activeConversation?.agentID, agent.id)
        XCTAssertEqual(viewModel.activeConversation?.agentAddress, endpointA)
    }

    @MainActor
    private func makeViewModel() -> ChatViewModel {
        let suiteName = "OOChatIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = try! SwiftDataConversationRepository(inMemory: true, defaults: defaults)
        return ChatViewModel(store: store)
    }
}
