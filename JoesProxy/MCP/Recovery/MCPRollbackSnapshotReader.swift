import Foundation

/// Decodes journaled rollback snapshots for AH-4 enable/disable/throttle mutations.
///
/// Concurrency: stateless — safe from any isolation domain.
enum MCPRollbackSnapshotReader {
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encodeRuleRollback(_ snapshot: MCPRuleRollbackSnapshot) throws -> Data {
        try encoder.encode(snapshot)
    }

    static func decodeRuleRollback(from data: Data) throws -> MCPRuleRollbackSnapshot {
        try decoder.decode(MCPRuleRollbackSnapshot.self, from: data)
    }

    static func encodeDeletedRuleRollback(_ snapshot: MCPDeletedRuleRollbackSnapshot) throws -> Data {
        try encoder.encode(snapshot)
    }

    static func decodeDeletedRuleRollback(from data: Data) throws -> MCPDeletedRuleRollbackSnapshot {
        try decoder.decode(MCPDeletedRuleRollbackSnapshot.self, from: data)
    }

    static func encodeBookmarkRewriteRollback(_ snapshot: MCPBookmarkRewriteRollbackSnapshot) throws -> Data {
        try encoder.encode(snapshot)
    }

    static func decodeBookmarkRewriteRollback(from data: Data) throws -> MCPBookmarkRewriteRollbackSnapshot {
        try decoder.decode(MCPBookmarkRewriteRollbackSnapshot.self, from: data)
    }

    static func encodeThrottleRollback(_ snapshot: MCPThrottleRollbackSnapshot) throws -> Data {
        try encoder.encode(snapshot)
    }

    static func decodeThrottleRollback(from data: Data) throws -> MCPThrottleRollbackSnapshot {
        try decoder.decode(MCPThrottleRollbackSnapshot.self, from: data)
    }
}
