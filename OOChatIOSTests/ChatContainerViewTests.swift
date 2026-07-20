import SwiftUI
import XCTest
@testable import OOChatIOS

@MainActor
final class ChatViewTests: XCTestCase {
    func testNoConversationShowsEmptyStateAndOpenSidebarAction() {
        let viewModel = makeContainerViewModel(agents: [], conversations: [])
        var openSidebarCount = 0
        let window = ViewHost.host(
            ChatView(viewModel: viewModel) {
                openSidebarCount += 1
            }
        )

        XCTAssertNotNil(ViewHost.element(labelContains: "No Conversation", in: window))
        XCTAssertTrue(ViewHost.activateButton(labelContains: "Open sidebar", in: window))
        XCTAssertEqual(openSidebarCount, 1)
    }

    func testTimelineRendersMessagesAndToolGroupsWithoutComposer() {
        let fixture = ChatContainerFixture()
        let conversation = fixture.conversation(
            messages: [
                ChatMessage(id: "user1", role: .user, content: "Need a project summary"),
                ChatMessage(
                    id: "tool1",
                    role: .tool,
                    content: "",
                    toolName: "read_file",
                    toolArguments: ["path": .string("/tmp/notes.md")],
                    toolState: .completed
                ),
                ChatMessage(
                    id: "tool2",
                    role: .tool,
                    content: "",
                    toolName: "bash",
                    toolArguments: ["cmd": .string("swift test")],
                    toolState: .completed
                ),
                ChatMessage(id: "agent1", role: .agent, content: "Here is the summary."),
            ]
        )
        let viewModel = makeContainerViewModel(
            agents: [fixture.agent],
            conversations: [conversation],
            activeAgentID: fixture.agent.id,
            activeConversationID: conversation.id
        )
        let window = ViewHost.host(ChatView(viewModel: viewModel, showsComposer: false))

        XCTAssertNotNil(ViewHost.element(labelContains: "Container Chat", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Need a project summary", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Read a file and ran a command", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Here is the summary.", in: window))
        XCTAssertNil(ViewHost.element(labelContains: "Send message", in: window))
    }

    func testComposerRendersWhenEnabled() {
        let fixture = ChatContainerFixture()
        let conversation = fixture.conversation()
        let viewModel = makeContainerViewModel(
            agents: [fixture.agent],
            conversations: [conversation],
            activeAgentID: fixture.agent.id,
            activeConversationID: conversation.id
        )
        let window = ViewHost.host(ChatView(viewModel: viewModel))

        XCTAssertNotNil(ViewHost.element(labelContains: "Send message", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Chat mode: Safe", in: window))
    }
}

@MainActor
final class ChatShellViewTests: XCTestCase {
    func testShellOpensSidebar() {
        let fixture = ChatContainerFixture()
        let conversation = fixture.conversation()
        let viewModel = makeContainerViewModel(
            agents: [fixture.agent],
            conversations: [conversation],
            activeAgentID: fixture.agent.id,
            activeConversationID: conversation.id
        )
        let window = ViewHost.host(ChatShellView(viewModel: viewModel))

        XCTAssertNotNil(ViewHost.element(labelContains: "Container Chat", in: window))
        XCTAssertTrue(ViewHost.activateButton(labelContains: "Open sidebar", in: window))
        ViewHost.pump(0.4)
        XCTAssertNotNil(ViewHost.element(labelContains: "Container Agent", in: window))
    }

    func testShellSettingsCanReturnToSidebar() {
        let fixture = ChatContainerFixture()
        let conversation = fixture.conversation()
        let viewModel = makeContainerViewModel(
            agents: [fixture.agent],
            conversations: [conversation],
            activeAgentID: fixture.agent.id,
            activeConversationID: conversation.id
        )
        let window = ViewHost.host(ChatShellView(viewModel: viewModel, startsInSettings: true))

        XCTAssertNotNil(ViewHost.waitForElement(labelContains: "Settings", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Reconnect", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: conversation.id, in: window))

        XCTAssertTrue(ViewHost.activateButton(labelContains: "Close", in: window))
        ViewHost.pump(0.4)
        XCTAssertNotNil(ViewHost.waitForElement(labelContains: "Container Agent", in: window))
    }

    func testShellSelectingActiveConversationFromOpenSidebarReturnsToChat() {
        let fixture = ChatContainerFixture()
        let conversation = fixture.conversation()
        let viewModel = makeContainerViewModel(
            agents: [fixture.agent],
            conversations: [conversation],
            activeAgentID: fixture.agent.id,
            activeConversationID: conversation.id
        )
        let window = ViewHost.host(ChatShellView(viewModel: viewModel, startsSidebarOpen: true))

        XCTAssertTrue(ViewHost.activateButton(labelContains: "Container Chat", in: window))
        ViewHost.pump(0.4)

        XCTAssertNotNil(ViewHost.waitForElement(labelContains: "Send message", in: window))
    }
}

final class SidebarShellLayoutTests: XCTestCase {
    func testContentOffsetCoversClosedOpenAndRubberBandStates() {
        XCTAssertEqual(
            SidebarShellLayout.contentOffset(isSidebarOpen: false, dragOffset: 0, openOffset: 100),
            0
        )
        XCTAssertEqual(
            SidebarShellLayout.contentOffset(isSidebarOpen: true, dragOffset: 0, openOffset: 100),
            100
        )
        XCTAssertLessThan(
            SidebarShellLayout.contentOffset(isSidebarOpen: false, dragOffset: -40, openOffset: 100),
            0
        )
        XCTAssertGreaterThan(
            SidebarShellLayout.contentOffset(isSidebarOpen: true, dragOffset: 40, openOffset: 100),
            100
        )
    }

    func testSidebarProgressClampsToOpenRange() {
        XCTAssertEqual(SidebarShellLayout.sidebarProgress(contentOffset: 40, openOffset: 0), 0)
        XCTAssertEqual(SidebarShellLayout.sidebarProgress(contentOffset: -10, openOffset: 100), 0)
        XCTAssertEqual(SidebarShellLayout.sidebarProgress(contentOffset: 50, openOffset: 100), 0.5)
        XCTAssertEqual(SidebarShellLayout.sidebarProgress(contentOffset: 140, openOffset: 100), 1)
    }

    func testRubberBandHandlesZeroDimension() {
        XCTAssertEqual(SidebarShellLayout.rubberBand(40, dimension: 0), 0)
        XCTAssertGreaterThan(SidebarShellLayout.rubberBand(40, dimension: 100), 0)
    }
}

private struct ChatContainerFixture {
    let agent = AgentConnection(
        id: "agent-container",
        address: "0x" + String(repeating: "cc", count: 32),
        name: "Container Agent"
    )

    func conversation(messages: [ChatMessage] = []) -> Conversation {
        Conversation(
            id: "conversation-container",
            title: "Container Chat",
            agentID: agent.id,
            agentAddress: agent.address,
            mode: .safe,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            messages: messages,
            serverSession: nil
        )
    }
}

@MainActor
private func makeContainerViewModel(
    agents: [AgentConnection],
    conversations: [Conversation],
    activeAgentID: String? = nil,
    activeConversationID: String? = nil
) -> ChatViewModel {
    let repository = InMemoryConversationRepository(
        snapshot: ChatSnapshot(
            agents: agents,
            conversations: conversations,
            activeAgentID: activeAgentID,
            activeConversationID: activeConversationID
        )
    )
    return ChatViewModel(
        store: repository,
        client: MockAgentTransport(),
        networkMonitor: MockNetworkMonitor()
    )
}
