import CryptoKit
import Foundation
import Security

enum IdentityStoreError: Error {
    case invalidStoredKey
    case keychain(OSStatus)
}

final class IdentityStore {
    private let service = "connectonion.native-ios.identity.ed25519"
    private let account = "default"

    func loadOrCreateIdentity() throws -> StoredIdentity {
        let key = try loadOrCreatePrivateKey()
        let publicKeyHex = Hex.encode(key.publicKey.rawRepresentation)
        let createdAtKey = "connectonion.native-ios.identity.createdAt"
        let createdAt: Date
        if let stored = UserDefaults.standard.object(forKey: createdAtKey) as? Date {
            createdAt = stored
        } else {
            createdAt = Date()
            UserDefaults.standard.set(createdAt, forKey: createdAtKey)
        }
        return StoredIdentity(address: "0x\(publicKeyHex)", publicKeyHex: publicKeyHex, createdAt: createdAt)
    }

    func signedEnvelope(type: String, payload: [String: JSONValue]) throws -> [String: JSONValue] {
        let key = try loadOrCreatePrivateKey()
        let signature = try key.signature(for: CanonicalJSON.data(from: payload))
        var envelope: [String: JSONValue] = [
            "type": .string(type),
            "payload": .object(payload),
            "from": .string("0x\(Hex.encode(key.publicKey.rawRepresentation))"),
            "signature": .string(Hex.encode(signature)),
        ]
        if let timestamp = payload["timestamp"] {
            envelope["timestamp"] = timestamp
        }
        return envelope
    }

    private func loadOrCreatePrivateKey() throws -> Curve25519.Signing.PrivateKey {
        if let data = try readPrivateKeyData() {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        let key = Curve25519.Signing.PrivateKey()
        switch try writePrivateKeyData(key.rawRepresentation) {
        case .stored:
            return key
        case .adoptedExisting(let data):
            // Another caller won the race and already stored a key. Adopt theirs rather than
            // overwriting it — the device address is derived from this key, and changing it
            // invalidates every peer's trust entry for this device.
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
    }

    private enum KeyWriteResult {
        case stored
        case adoptedExisting(Data)
    }

    private func readPrivateKeyData() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw IdentityStoreError.keychain(status)
        }
        guard let data = result as? Data else {
            throw IdentityStoreError.invalidStoredKey
        }
        return data
    }

    /// Adds `data` without clobbering an existing entry, reporting whether this caller's key
    /// won the race or an existing one has to be adopted.
    private func writePrivateKeyData(_ data: Data) throws -> KeyWriteResult {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard let existing = try readPrivateKeyData() else {
                throw IdentityStoreError.keychain(status)
            }
            return .adoptedExisting(existing)
        }
        guard status == errSecSuccess else {
            throw IdentityStoreError.keychain(status)
        }
        return .stored
    }
}
