import SwiftUI
import XCTest
@testable import OOChatIOS

@MainActor
final class ComposerTests: XCTestCase {
    private func makeTransport() -> MockAgentTransport {
        let transport = MockAgentTransport()
        transport.availableSkills = [
            AgentSkill(name: "deploy", description: "Ship the current build"),
            AgentSkill(name: "review", description: ""),
        ]
        return transport
    }

    func testRendersWithActiveConversation() {
        let viewModel = ViewFixtures.chatViewModel(transport: makeTransport())
        let window = ViewHost.host(Composer(viewModel: viewModel))

        XCTAssertNotNil(ViewHost.element(labelContains: "Send message", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Chat mode: Safe", in: window))
    }

    func testSlashPromptShowsSkillPickerAndSelectionInsertsSkill() {
        let viewModel = ViewFixtures.chatViewModel(transport: makeTransport())
        let window = ViewHost.host(Composer(viewModel: viewModel))
        ViewHost.pump(0.3)

        viewModel.prompt = "/"
        ViewHost.pump(0.3)
        XCTAssertTrue(viewModel.shouldShowSlashSkillPicker)
        XCTAssertNotNil(ViewHost.element(labelContains: "/deploy", in: window))

        XCTAssertTrue(ViewHost.activate(labelContains: "/deploy", in: window))
        XCTAssertTrue(viewModel.prompt.contains("deploy"))
    }

    func testSendButtonSendsPrompt() {
        let transport = makeTransport()
        let viewModel = ViewFixtures.chatViewModel(transport: transport)
        let window = ViewHost.host(Composer(viewModel: viewModel))

        viewModel.prompt = "Hello agent"
        ViewHost.pump(0.2)
        XCTAssertTrue(ViewHost.activate(labelContains: "Send message", in: window))

        let deadline = Date().addingTimeInterval(3)
        while transport.sentPrompts.isEmpty && Date() < deadline {
            ViewHost.pump(0.1)
        }
        XCTAssertEqual(transport.sentPrompts, ["Hello agent"])
    }

    func testProcessingShowsStopButtonAndStops() {
        let transport = makeTransport()
        transport.sendBehavior = .waitUntilCancelled
        let viewModel = ViewFixtures.chatViewModel(transport: transport)
        let window = ViewHost.host(Composer(viewModel: viewModel))

        viewModel.prompt = "Slow request"
        ViewHost.pump(0.2)
        viewModel.sendPrompt()

        let deadline = Date().addingTimeInterval(3)
        while !viewModel.isProcessing && Date() < deadline {
            ViewHost.pump(0.1)
        }
        XCTAssertTrue(viewModel.isProcessing)
        ViewHost.pump(0.3)

        XCTAssertTrue(ViewHost.activate(labelContains: "Stop response", in: window))
        let stopDeadline = Date().addingTimeInterval(3)
        while viewModel.isProcessing && Date() < stopDeadline {
            ViewHost.pump(0.1)
        }
        XCTAssertFalse(viewModel.isProcessing)
    }

    func testModeMenuPresentsSheetAndSelectsMode() {
        let viewModel = ViewFixtures.chatViewModel(transport: makeTransport())
        let window = ViewHost.host(Composer(viewModel: viewModel))

        XCTAssertTrue(ViewHost.activate(labelContains: "Chat mode: Safe", in: window))
        ViewHost.pump(0.5)

        var sheetWindow: UIWindow?
        for candidate in UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows }) {
            if ViewHost.element(labelContains: "Accept Edits", in: candidate) != nil {
                sheetWindow = candidate
                break
            }
        }

        if let sheetWindow {
            ViewHost.activate(labelContains: "Accept Edits", in: sheetWindow)
            ViewHost.pump(0.5)
            XCTAssertEqual(viewModel.activeMode, .accept)
        }
    }
}

@MainActor
final class ToolCallViewTests: XCTestCase {
    func testCompletedToolExpandsToShowInputAndResult() {
        let message = ViewFixtures.toolMessage(
            name: "read_file",
            state: .completed,
            content: "file contents here"
        )
        let window = ViewHost.host(ToolCallView(message: message))

        XCTAssertNotNil(ViewHost.element(labelContains: "Tool call: Read File", in: window))
        XCTAssertTrue(ViewHost.activate(labelContains: "Tool call: Read File", in: window))
        ViewHost.pump(0.2)
        XCTAssertNotNil(ViewHost.element(valueContains: "expanded", in: window))
        XCTAssertTrue(ViewHost.activate(labelContains: "Tool call: Read File", in: window))
    }

    func testFailedToolShowsErrorDetail() {
        let message = ViewFixtures.toolMessage(
            name: "run_command",
            state: .failed,
            content: "command not found",
            arguments: ["cmd": .string("nope")]
        )
        let window = ViewHost.host(ToolCallView(message: message))
        XCTAssertTrue(ViewHost.activate(labelContains: "Tool call: Run Command", in: window))
        ViewHost.pump(0.2)
    }

    func testRunningToolShowsRunningStatus() {
        let message = ViewFixtures.toolMessage(name: "grep_search", state: .running, arguments: [:])
        let window = ViewHost.host(ToolCallView(message: message))
        XCTAssertNotNil(ViewHost.element(valueContains: "Running", in: window))
    }

    func testNilToolMetadataFallsBackToDefaults() {
        let message = ViewFixtures.toolMessage(name: nil, state: nil, arguments: nil)
        let window = ViewHost.host(ToolCallView(message: message))
        XCTAssertNotNil(ViewHost.element(labelContains: "Tool call: Tool", in: window))
    }

    func testIconographyVariantsRender() {
        for name in ["edit_file", "read_file", "bash", "grep_search", "list_dir", "mystery"] {
            let message = ViewFixtures.toolMessage(name: name, state: .completed)
            _ = ViewHost.host(ToolCallView(message: message))
        }
    }
}

@MainActor
final class ToolCallGroupViewTests: XCTestCase {
    func testGroupRendersAndCollapses() {
        let messages = [
            ViewFixtures.toolMessage(id: "t1", name: "read_file", state: .completed),
            ViewFixtures.toolMessage(id: "t2", name: "edit_file", state: .completed),
            ViewFixtures.toolMessage(id: "t3", name: "bash", state: .failed, content: "boom"),
        ]
        let window = ViewHost.host(ToolCallGroupView(messages: messages))

        let title = ToolCallGroupSummary.title(for: messages)
        XCTAssertNotNil(ViewHost.element(labelContains: title, in: window))
        XCTAssertTrue(ViewHost.activate(labelContains: title, in: window))
        XCTAssertTrue(ViewHost.activate(labelContains: title, in: window))
    }

    func testGroupWithRunningToolShowsRunningTitle() {
        let messages = [
            ViewFixtures.toolMessage(id: "t1", name: "read_file", state: .running),
            ViewFixtures.toolMessage(id: "t2", name: "bash", state: .completed),
        ]
        let window = ViewHost.host(ToolCallGroupView(messages: messages))
        XCTAssertNotNil(ViewHost.element(labelContains: "Running 2 tools", in: window))
    }
}

final class ToolCallGroupSummaryTests: XCTestCase {
    private func message(name: String?, state: ToolCallState? = .completed) -> ChatMessage {
        ChatMessage(id: UUID().uuidString, role: .tool, content: "", toolName: name, toolState: state)
    }

    func testEmptyMessagesFallBackToGenericTitle() {
        XCTAssertEqual(ToolCallGroupSummary.title(for: []), "Tool activity")
    }

    func testRunningMessagesReportCount() {
        let messages = [message(name: "read_file", state: .running), message(name: "bash")]
        XCTAssertEqual(ToolCallGroupSummary.title(for: messages), "Running 2 tools")
    }

    func testSingleCategorySingular() {
        XCTAssertEqual(ToolCallGroupSummary.title(for: [message(name: "edit_file")]), "Edited a file")
        XCTAssertEqual(ToolCallGroupSummary.title(for: [message(name: "read_file")]), "Read a file")
        XCTAssertEqual(ToolCallGroupSummary.title(for: [message(name: "bash")]), "Ran a command")
        XCTAssertEqual(ToolCallGroupSummary.title(for: [message(name: "grep_search")]), "Searched")
        XCTAssertEqual(ToolCallGroupSummary.title(for: [message(name: "list_dir")]), "Listed files")
        XCTAssertEqual(ToolCallGroupSummary.title(for: [message(name: "mystery")]), "Used a tool")
        XCTAssertEqual(ToolCallGroupSummary.title(for: [message(name: nil)]), "Used a tool")
    }

    func testPluralAndMultiCategorySentences() {
        XCTAssertEqual(
            ToolCallGroupSummary.title(for: [message(name: "edit_a"), message(name: "write_b")]),
            "Edited files"
        )
        XCTAssertEqual(
            ToolCallGroupSummary.title(for: [message(name: "read_a"), message(name: "read_b")]),
            "Read files"
        )
        XCTAssertEqual(
            ToolCallGroupSummary.title(for: [message(name: "exec"), message(name: "shell")]),
            "Ran commands"
        )
        XCTAssertEqual(
            ToolCallGroupSummary.title(for: [message(name: "read_file"), message(name: "bash")]),
            "Read a file and ran a command"
        )
        XCTAssertEqual(
            ToolCallGroupSummary.title(
                for: [message(name: "read_file"), message(name: "bash"), message(name: "grep_search")]
            ),
            "Read a file, ran a command, and searched"
        )
        XCTAssertEqual(
            ToolCallGroupSummary.title(for: [message(name: "tool_a"), message(name: "tool_b")]),
            "Used tools"
        )
    }
}
