import Combine
import SwiftUI
import XCTest
@testable import OOChatIOS

@MainActor
final class AgentFormViewTests: XCTestCase {
    func testAddAgentFormRendersFieldsAndInvokesCancel() {
        var didCancel = false
        let window = ViewHost.host(
            AgentFormView(draft: AgentFormDraft()) { _ in
                XCTFail("unexpected save")
                return false
            } onCancel: {
                didCancel = true
            }
        )

        XCTAssertNotNil(ViewHost.element(labelContains: "Add Agent", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Name", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Agent address", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Scan QR Code", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Saved with this configuration", in: window))
        XCTAssertTrue(ViewHost.activateButton(labelContains: "Cancel", in: window))
        XCTAssertTrue(didCancel)
    }

    func testInvalidAddressDoesNotSave() {
        var didAttemptSave = false
        let window = ViewHost.host(
            AgentFormView(draft: makeDraft(address: "not-an-agent-address")) { _ in
                didAttemptSave = true
                return true
            } onCancel: {}
        )

        XCTAssertTrue(ViewHost.activateButton(labelContains: "Save", in: window))
        ViewHost.pump(0.3)
        XCTAssertFalse(didAttemptSave)
    }

    func testSaveFailureKeepsFormOpenAfterSaveAttempt() {
        var saveAttemptCount = 0
        let window = ViewHost.host(
            AgentFormView(draft: makeDraft(address: hostedAddress)) { _ in
                saveAttemptCount += 1
                return false
            } onCancel: {}
        )

        XCTAssertTrue(ViewHost.activateButton(labelContains: "Save", in: window))
        ViewHost.pump(0.3)
        XCTAssertEqual(saveAttemptCount, 1)
        XCTAssertNotNil(ViewHost.element(labelContains: "Add Agent", in: window))
    }

    func testEditAgentFormSavesExistingDraftWithoutScanner() {
        let agent = AgentConnection(
            id: "agent-edit",
            address: hostedAddress,
            name: "Orbit Agent",
            token: "secret-token",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        var savedDraft: AgentFormDraft?
        let window = ViewHost.host(
            AgentFormView(draft: AgentFormDraft(agent: agent)) { draft in
                savedDraft = draft
                return true
            } onCancel: {}
        )

        XCTAssertNotNil(ViewHost.element(labelContains: "Edit Agent", in: window))
        XCTAssertNil(ViewHost.element(labelContains: "Scan QR Code", in: window))
        XCTAssertTrue(ViewHost.activateButton(labelContains: "Save", in: window))
        XCTAssertEqual(savedDraft?.agentID, "agent-edit")
        XCTAssertEqual(savedDraft?.name, "Orbit Agent")
        XCTAssertEqual(savedDraft?.address, hostedAddress)
        XCTAssertEqual(savedDraft?.token, "secret-token")
        XCTAssertEqual(savedDraft?.shouldConnectAfterSave, false)
    }
}

@MainActor
final class SettingsViewTests: XCTestCase {
    func testSettingsShowsIdentitySessionAndInvokesActions() {
        let model = TestSettingsModel(
            identity: StoredIdentity(
                address: hostedAddress,
                publicKeyHex: String(repeating: "cd", count: 32),
                createdAt: Date(timeIntervalSince1970: 1_000)
            ),
            connectionState: .connected,
            activeConversation: conversation(id: "conversation-42")
        )
        var didClose = false
        let window = ViewHost.host(
            SettingsView(viewModel: model) {
                didClose = true
            }
        )

        XCTAssertNotNil(ViewHost.element(labelContains: "Settings", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: hostedAddress, in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "conversation-42", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Reconnect", in: window))

        XCTAssertTrue(ViewHost.activateButton(labelContains: "Reconnect", in: window))
        ViewHost.pump(0.2)
        XCTAssertEqual(model.reconnectCallCount, 1)

        XCTAssertTrue(ViewHost.activateButton(labelContains: "Close", in: window))
        XCTAssertTrue(didClose)
    }

    func testSettingsShowsPlaceholdersWhenIdentityAndSessionAreMissing() {
        let model = TestSettingsModel(
            identity: nil,
            connectionState: .disconnected,
            activeConversation: nil
        )
        let window = ViewHost.host(SettingsView(viewModel: model))

        XCTAssertNotNil(ViewHost.element(labelContains: "Creating...", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "None", in: window))
    }
}

@MainActor
final class AgentQRCodeShareViewTests: XCTestCase {
    func testShareViewRendersQRCodeScreen() throws {
        let url = try XCTUnwrap(AgentShareURL.url(for: hostedAddress))
        let window = ViewHost.host(AgentQRCodeShareView(url: url))

        XCTAssertNotNil(window.rootViewController)
    }
}

private let hostedAddress = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

private func makeDraft(
    name: String = "",
    address: String = "",
    token: String = ""
) -> AgentFormDraft {
    var draft = AgentFormDraft()
    draft.name = name
    draft.address = address
    draft.token = token
    return draft
}

private func conversation(id: String) -> Conversation {
    let agent = ViewFixtures.agent()
    return Conversation(
        id: id,
        title: "Settings Chat",
        agentID: agent.id,
        agentAddress: agent.address,
        mode: .safe,
        createdAt: Date(timeIntervalSince1970: 1_000),
        updatedAt: Date(timeIntervalSince1970: 2_000),
        messages: [],
        serverSession: nil
    )
}

@MainActor
private final class TestSettingsModel: SettingsFeatureModel {
    @Published var identity: StoredIdentity?
    @Published var connectionState: ConnectionState
    @Published var activeConversation: Conversation?
    private(set) var reconnectCallCount = 0

    init(
        identity: StoredIdentity?,
        connectionState: ConnectionState,
        activeConversation: Conversation?
    ) {
        self.identity = identity
        self.connectionState = connectionState
        self.activeConversation = activeConversation
    }

    func reconnect() async {
        reconnectCallCount += 1
    }
}
