import XCTest
@testable import OOChatIOS

final class AgentQRCodePayloadTests: XCTestCase {
    private let address = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    func testAcceptsValidAgentAddress() {
        XCTAssertEqual(AgentQRCodePayload.address(from: address), address)
    }

    func testAcceptsWebShareURL() {
        XCTAssertEqual(
            AgentQRCodePayload.address(from: "https://chat.openonion.ai/\(address)"),
            address
        )
    }

    func testShareURLMatchesWebQRCodeFormat() {
        XCTAssertEqual(
            AgentShareURL.url(for: address)?.absoluteString,
            "https://chat.openonion.ai/\(address)"
        )
    }

    func testShareURLRejectsInvalidAddress() {
        XCTAssertNil(AgentShareURL.url(for: "not-an-agent-address"))
    }

    func testRejectsUnrecognisedPayloads() {
        XCTAssertNil(AgentQRCodePayload.address(from: ""))
        XCTAssertNil(AgentQRCodePayload.address(from: "https://example.com/\(address)"))
        XCTAssertNil(AgentQRCodePayload.address(from: "https://chat.openonion.ai/agents/\(address)"))
        XCTAssertNil(AgentQRCodePayload.address(from: "not-an-agent-address"))
    }

    func testRejectsShareURLsWithUnexpectedComponents() {
        XCTAssertNil(AgentQRCodePayload.address(from: "https://chat.openonion.ai:444/\(address)"))
        XCTAssertNil(AgentQRCodePayload.address(from: "https://user@chat.openonion.ai/\(address)"))
        XCTAssertNil(AgentQRCodePayload.address(from: "https://chat.openonion.ai/\(address)?source=qr"))
        XCTAssertNil(AgentQRCodePayload.address(from: "https://chat.openonion.ai/\(address)#agent"))
    }
}
