import Foundation
import Security
import LocalAuthentication

public enum GroqKeychain {
    public enum StorageStatus: Equatable, Sendable {
        case stored, missing, authorizationRequired, failure(Int32)
    }

    /// Check metadata only; opening Settings must not prompt for the secret.
    public static func storageStatus() -> StorageStatus {
        var request = query
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var attributes: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &attributes)
        switch status {
        case errSecSuccess: return .stored
        case errSecItemNotFound: return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed: return .authorizationRequired
        default: return .failure(status)
        }
    }
    private static let service = "Sotto.Groq"
    private static let account = "api-key"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public static func read() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw SottoError("Groq API key unavailable in Keychain (OSStatus \(status)). Run `sotto key set`.")
        }
        return key
    }

    public static func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else { throw SottoError("API key is empty or contains whitespace.") }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SottoError("Cannot save key to Keychain (OSStatus \(status)).") }
    }
}
