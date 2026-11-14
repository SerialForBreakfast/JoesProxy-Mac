import Foundation
import LocalAuthentication
import Security

/// Keychain storage for MCP bearer verifiers (SHA-256 digests only; never plaintext credentials).
final class MCPClientCredentialKeychainStore: MCPClientCredentialStoring, @unchecked Sendable {
    private let service = "com.joesproxyapp.mcp.client-verifier"

    func saveVerifier(clientID: String, generation: Int, verifier: Data) throws {
        let account = accountKey(clientID: clientID, generation: generation)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: verifier,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MCPClientCredentialKeychainError.operationFailed(status)
        }
    }

    func loadVerifier(clientID: String, generation: Int) throws -> Data? {
        try readVerifier(clientID: clientID, generation: generation, interactive: false)
    }

    func unlockVerifier(clientID: String, generation: Int) throws -> Data? {
        try readVerifier(clientID: clientID, generation: generation, interactive: true)
    }

    private func readVerifier(clientID: String, generation: Int, interactive: Bool) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey(clientID: clientID, generation: generation),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !interactive {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status: OSStatus
        if interactive {
            status = SecItemCopyMatching(query as CFDictionary, &item)
        } else {
            // Existing enrollments use the file-based login keychain. Its ACL prompts predate
            // LAContext. Scope its legacy interaction setting to this synchronous read.
            var wasAllowed: DarwinBoolean = false
            let priorStatus = SecKeychainGetUserInteractionAllowed(&wasAllowed)
            guard priorStatus == errSecSuccess else {
                throw MCPClientCredentialKeychainError.operationFailed(priorStatus)
            }
            if wasAllowed.boolValue {
                let change = SecKeychainSetUserInteractionAllowed(false)
                guard change == errSecSuccess else {
                    throw MCPClientCredentialKeychainError.operationFailed(change)
                }
            }
            defer {
                if wasAllowed.boolValue { SecKeychainSetUserInteractionAllowed(true) }
            }
            status = SecItemCopyMatching(query as CFDictionary, &item)
        }
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw MCPClientCredentialKeychainError.operationFailed(status)
        }
        return data
    }

    func deleteVerifier(clientID: String, generation: Int) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey(clientID: clientID, generation: generation)
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MCPClientCredentialKeychainError.operationFailed(status)
        }
    }

    func deleteAllVerifiers(clientID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return
        }
        guard status == errSecSuccess else {
            throw MCPClientCredentialKeychainError.operationFailed(status)
        }
        guard let items = result as? [[String: Any]] else { return }
        let prefix = "\(clientID)#"
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix(prefix) else { continue }
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw MCPClientCredentialKeychainError.operationFailed(deleteStatus)
            }
        }
    }

    private func accountKey(clientID: String, generation: Int) -> String {
        "\(clientID)#\(generation)"
    }
}

enum MCPClientCredentialKeychainError: Error, Equatable, Sendable {
    case operationFailed(OSStatus)
}
