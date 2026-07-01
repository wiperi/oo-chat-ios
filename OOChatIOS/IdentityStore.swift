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
        let createdAt = UserDefaults.standard.object(forKey: "connectonion.native-ios.identity.createdAt") as? Date ?? Date()
        UserDefaults.standard.set(createdAt, forKey: "connectonion.native-ios.identity.createdAt")
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
        try writePrivateKeyData(key.rawRepresentation)
        return key
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

    private func writePrivateKeyData(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw IdentityStoreError.keychain(status)
        }
    }
}
