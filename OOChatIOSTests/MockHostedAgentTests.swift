import XCTest
@testable import OOChatIOS

final class MockHostedAgentTests: XCTestCase {
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
}
