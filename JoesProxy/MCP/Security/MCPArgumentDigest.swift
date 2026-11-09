import CryptoKit
import Foundation

/// Stable argument digests for MCP approval minting and retry validation.
enum MCPArgumentDigest {
    private static let approvalKey = "approval"

    /// Builds a SHA-256 digest over tool arguments with the retry authorization stripped.
    static func normalized(_ arguments: [String: Any]) -> String {
        let filtered = arguments.filter { $0.key != approvalKey && !$0.key.hasPrefix("__mcpInternal") }
        guard JSONSerialization.isValidJSONObject(filtered),
              let data = try? JSONSerialization.data(withJSONObject: filtered, options: [.sortedKeys]) else {
            return "invalid"
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Arguments with any embedded approval object removed for dispatch.
    static func dispatchArguments(_ arguments: [String: Any]) -> [String: Any] {
        arguments.filter { $0.key != approvalKey && !$0.key.hasPrefix("__mcpInternal") }
    }

    /// Decodes a retry authorization object from tool arguments when present.
    static func authorization(from arguments: [String: Any]) -> MCPApprovalAuthorization? {
        guard let approvalObject = arguments[approvalKey] else { return nil }
        guard JSONSerialization.isValidJSONObject(approvalObject),
              let data = try? JSONSerialization.data(withJSONObject: approvalObject) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MCPApprovalAuthorization.self, from: data)
    }
}
