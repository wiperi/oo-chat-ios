import Security
import XCTest
@testable import OOChatIOS

final class IdentityStoreErrorTests: XCTestCase {
    func testKeychainErrorReportsStatusCodeInsteadOfEnumIndex() {
        let message = IdentityStoreError.keychain(errSecMissingEntitlement).localizedDescription

        XCTAssertTrue(message.contains("\(errSecMissingEntitlement)"), message)
        XCTAssertFalse(message.contains("error 0"), message)
    }

    func testKeychainErrorExplainsUnsignedSimulatorBuilds() {
        let message = IdentityStoreError.keychain(errSecMissingEntitlement).localizedDescription

        XCTAssertTrue(message.contains("Simulator without code signing"), message)
    }

    func testKeychainErrorNamesTheStatusWhenSecurityHasWordingForIt() {
        let message = IdentityStoreError.keychain(errSecItemNotFound).localizedDescription

        XCTAssertTrue(message.contains("could not be found in the keychain"), message)
    }

    func testKeychainErrorStillDescribesUnnamedStatusCodes() {
        let message = IdentityStoreError.keychain(-99999).localizedDescription

        XCTAssertTrue(message.contains("OSStatus -99999"), message)
        // Security echoes "OSStatus -99999" back as its own wording; don't print it twice.
        XCTAssertFalse(message.contains("OSStatus -99999: OSStatus"), message)
    }

    func testInvalidStoredKeyHasReadableDescription() {
        let message = IdentityStoreError.invalidStoredKey.localizedDescription

        XCTAssertTrue(message.contains("identity key"), message)
        XCTAssertFalse(message.contains("error 1"), message)
    }
}
