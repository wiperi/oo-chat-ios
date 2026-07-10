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
