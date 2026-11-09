import Foundation

/// JSON parsing helpers with depth limits for MCP request bodies.
///
/// Depth is enforced with a byte-level scan *before* any JSON parsing runs. `JSONSerialization`'s
/// parser is itself recursive with no depth cap of its own, so a pathologically nested body (still
/// well under the request-size cap) can overflow its call stack while building the object tree —
/// checking depth on the tree afterward is too late to prevent that crash.
enum MCPJSONParsing {
    enum Failure: Error, Equatable {
        case invalidJSON
        case depthExceeded(maxDepth: Int)
    }

    /// Rejects nesting deeper than ``MCPServerLimits/maxJSONDepth`` before parsing, then parses.
    static func parseJSONObject(from data: Data, maxDepth: Int = MCPServerLimits.maxJSONDepth) throws -> Any {
        try rejectExcessiveNesting(in: data, maxDepth: maxDepth)
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw Failure.invalidJSON
        }
        return object
    }

    /// Scans raw bytes for container-nesting depth without building any object graph, so an
    /// adversarially nested body is rejected before `JSONSerialization` ever sees it. Tracks string
    /// state (including escaped quotes) so brackets inside string literals aren't miscounted as
    /// structural — this only needs to bound depth, not fully validate JSON syntax.
    private static func rejectExcessiveNesting(in data: Data, maxDepth: Int) throws {
        var depth = 0
        var inString = false
        var escapedNext = false
        for byte in data {
            if inString {
                if escapedNext {
                    escapedNext = false
                } else if byte == UInt8(ascii: "\\") {
                    escapedNext = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                guard depth <= maxDepth else {
                    throw Failure.depthExceeded(maxDepth: maxDepth)
                }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth = max(0, depth - 1)
            default:
                break
            }
        }
    }
}
