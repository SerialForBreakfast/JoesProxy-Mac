//
//  JSONTreeParser.swift
//  JoesProxy
//
//  Parses JSON data into a tree of JSONTreeNode for display in the JSON viewer.
//

import Foundation

/// Errors thrown when parsing JSON for the tree viewer.
enum JSONTreeParserError: LocalizedError {
    case invalidUTF8
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "Invalid UTF-8"
        case .parseFailed(let message):
            return "Parse failed: \(message)"
        }
    }
}

/// Parses JSON data into a tree structure for the JSON viewer.
enum JSONTreeParser {

    /// Parses JSON data into a root tree node.
    ///
    /// Accepts a single JSON document or Adobe Konductor-style streaming payloads where
    /// records are separated by null bytes (and optional line feeds).
    static func parse(_ data: Data) throws -> JSONTreeNode {
        let signpost = JSONViewerPerformanceSignposts.beginTreeParse()
        defer { JSONViewerPerformanceSignposts.endTreeParse(signpost) }

        let value = try parseJSONObject(from: data)
        return node(from: value, key: nil)
    }

    /// Parses a JSON string into a root tree node.
    static func parse(_ string: String) throws -> JSONTreeNode {
        try parse(Data(string.utf8))
    }

    /// Parses one JSON value or a delimited stream of JSON records.
    ///
    /// Multiple records are returned as a Swift array so tree and prettified views can
    /// render them as `[0]`, `[1]`, … without mutating the stored capture bytes.
    static func parseJSONObject(from data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            let records = try parseDelimitedRecords(from: data)
            if records.count == 1 {
                return records[0]
            }
            return records
        }
    }

    /// Whether ``parseJSONObject(from:)`` can interpret the payload.
    static func canParseJSONObject(from data: Data) -> Bool {
        (try? parseJSONObject(from: data)) != nil
    }

    private static func parseDelimitedRecords(from data: Data) throws -> [Any] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw JSONTreeParserError.invalidUTF8
        }

        let segments: [String]
        if text.contains("\0") {
            segments = text
                .split(separator: "\0", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            segments = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && ($0.hasPrefix("{") || $0.hasPrefix("[")) }
        }

        guard !segments.isEmpty else {
            throw JSONTreeParserError.parseFailed("No JSON records found")
        }

        var records: [Any] = []
        records.reserveCapacity(segments.count)

        for segment in segments {
            let segmentData = Data(segment.utf8)
            do {
                records.append(try JSONSerialization.jsonObject(with: segmentData))
            } catch {
                throw JSONTreeParserError.parseFailed(
                    "Invalid JSON record: \(error.localizedDescription)"
                )
            }
        }

        return records
    }

    private static func node(from value: Any, key: String?) -> JSONTreeNode {
        switch value {
        case let dict as [String: Any]:
            let box = UncheckedJSONValueBox(dict)
            let children = JSONTreeChildren(count: dict.count) {
                guard let dict = box.value as? [String: Any] else { return [] }
                return dict.sorted(by: { $0.key < $1.key }).map { item in
                    node(from: item.value, key: item.key)
                }
            }
            return .object(key: key, children: children)
        case let array as [Any]:
            let box = UncheckedJSONValueBox(array)
            let children = JSONTreeChildren(count: array.count) {
                guard let array = box.value as? [Any] else { return [] }
                return array.enumerated().map { index, element in
                    node(from: element, key: "[\(index)]")
                }
            }
            return .array(key: key, children: children)
        case let string as String:
            return .string(key: key, value: string)
        case let bool as Bool:
            return .bool(key: key, value: bool)
        case let number as NSNumber:
            return .number(key: key, value: "\(number)")
        case is NSNull:
            return .null(key: key)
        default:
            return .string(key: key, value: String(describing: value))
        }
    }
}

private final class UncheckedJSONValueBox: @unchecked Sendable {
    let value: Any
    init(_ value: Any) {
        self.value = value
    }
}
