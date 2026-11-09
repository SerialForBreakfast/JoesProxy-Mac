import Foundation
import Security

protocol CLICredentialStoring {
    func load(endpoint: URL) throws -> String?
    func save(_ credential: String, endpoint: URL) throws
    func delete(endpoint: URL) throws
}

struct CLIKeychainCredentialStore: CLICredentialStoring {
    private let service = "com.ShowBlender.JoesProxy.cli"

    func load(endpoint: URL) throws -> String? {
        var query = baseQuery(endpoint: endpoint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let credential = String(data: data, encoding: .utf8) else {
            throw CLIError.internalFailure("Unable to read the JoesProxy CLI credential from Keychain (\(status)).")
        }
        return credential
    }

    func save(_ credential: String, endpoint: URL) throws {
        guard credential.utf8.count >= 32 else {
            throw CLIError.invalidArguments("The enrollment credential is not valid.")
        }
        let data = Data(credential.utf8)
        let query = baseQuery(endpoint: endpoint)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CLIError.internalFailure("Unable to update the JoesProxy CLI credential in Keychain (\(updateStatus)).")
        }
        var insert = query
        insert[kSecValueData as String] = data
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CLIError.internalFailure("Unable to store the JoesProxy CLI credential in Keychain (\(status)).")
        }
    }

    func delete(endpoint: URL) throws {
        let status = SecItemDelete(baseQuery(endpoint: endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CLIError.internalFailure("Unable to remove the JoesProxy CLI credential from Keychain (\(status)).")
        }
    }

    private func baseQuery(endpoint: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: endpoint.absoluteString
        ]
    }
}

enum CLITerminalCredentialReader {
    static func read(prompt: String) throws -> String {
        guard isatty(STDIN_FILENO) != 0 else {
            throw CLIError.invalidArguments("auth login requires an interactive terminal.")
        }
        FileHandle.standardError.write(Data(prompt.utf8))
        var settings = termios()
        guard tcgetattr(STDIN_FILENO, &settings) == 0 else {
            throw CLIError.internalFailure("Unable to configure secure terminal input.")
        }
        let original = settings
        settings.c_lflag &= ~UInt(ECHO)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &settings) == 0 else {
            throw CLIError.internalFailure("Unable to disable terminal echo.")
        }
        defer {
            var restored = original
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &restored)
            FileHandle.standardError.write(Data("\n".utf8))
        }
        guard let line = readLine() else {
            throw CLIError.invalidArguments("No credential was entered.")
        }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
