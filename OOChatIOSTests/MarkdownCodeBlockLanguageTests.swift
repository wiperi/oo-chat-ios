import XCTest
@testable import OOChatIOS

final class MarkdownCodeBlockLanguageTests: XCTestCase {
    func testUsesFirstFenceTokenAsLanguageLabel() {
        XCTAssertEqual(MarkdownCodeBlockLanguage.label(for: "swift linenos=true"), "swift")
    }

    func testReturnsNilForMissingFenceLanguage() {
        XCTAssertNil(MarkdownCodeBlockLanguage.label(for: "  "))
        XCTAssertNil(MarkdownCodeBlockLanguage.label(for: nil))
    }
}
