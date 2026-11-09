import Foundation
import CoreFoundation
import CryptoKit

/// Bounded, deterministic analysis of one complete authorized JSON document. No captured scalar
/// values are returned. Field names and pointers remain untrusted captured data.
enum ResponseEvidenceBrief {
    static let maximumInputBytes = 262_144
    static let maximumFields = 32

    struct Field: Codable, Equatable, Sendable {
        var name: String
        var present: Int
        var missing: Int
        var null: Int
        var types: [String: Int]
    }

    struct Report: Codable, Equatable, Sendable {
        var schemaVersion = 1
        var status: String
        var sourceSHA256: String?
        var analyzedUTF8Bytes = 0
        var selectionPointer: String
        var selectionType: String?
        var itemCount: Int?
        var objectItemCount: Int?
        var itemTypes: [String: Int] = [:]
        var fields: [Field] = []
        var omittedFieldCount = 0
        var coverage = "none"
        var structure: [StructureNode]?
        var structureCoverage: String?
        var structureLimits: [String]?
        var contentTrust = "captured_untrusted"
        var scope = "Selected value; array elements or one non-array item. Immediate object fields only; missing counts use object items. No semantic validity or duplicate-identity claim."
    }

    static func analyze(text: String?, truncated: Bool, unavailableReason: String?, pointer: String, includeStructure: Bool = false) -> Report {
        var report = Report(status: "unavailable", selectionPointer: pointer)
        guard unavailableReason == nil else { return report }
        guard !truncated else { report.status = "incomplete_body"; return report }
        guard let text, !text.isEmpty else { report.status = "empty_body"; return report }
        let data = Data(text.utf8)
        guard data.count <= maximumInputBytes else { report.status = "input_limit"; return report }
        report.sourceSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            report.status = "invalid_json"
            return report
        }
        guard let tokens = try? CollectionMockCompiler.pointer(pointer),
              let selected = select(root, tokens: tokens) else {
            report.status = "selection_not_found"
            return report
        }
        let items = (selected as? [Any]) ?? [selected]
        let objects = items.compactMap { $0 as? [String: Any] }
        report.analyzedUTF8Bytes = data.count
        report.selectionType = type(selected)
        report.itemCount = items.count
        report.objectItemCount = objects.count
        for item in items { report.itemTypes[type(item), default: 0] += 1 }
        let keys = Set(objects.flatMap { $0.keys }).sorted()
        let included = Array(keys.filter { $0.utf8.count <= 128 }.prefix(maximumFields))
        report.omittedFieldCount = keys.count - included.count
        for key in included {
            var field = Field(name: key, present: 0, missing: 0, null: 0, types: [:])
            for object in objects {
                guard let value = object[key] else { field.missing += 1; continue }
                field.present += 1
                let kind = type(value)
                field.types[kind, default: 0] += 1
                if kind == "null" { field.null += 1 }
            }
            report.fields.append(field)
        }
        report.status = "complete"
        report.coverage = report.omittedFieldCount == 0 ? "all_selected_items_immediate_fields" : "all_selected_items_bounded_fields"
        if includeStructure {
            let nested = structure(of: selected)
            report.structure = nested.nodes
            report.structureLimits = nested.limits
            report.structureCoverage = nested.limits.isEmpty ? "complete" : "bounded"
        }
        return report
    }

    struct StructureNode: Codable, Equatable, Sendable {
        /// JSON-quoted field segments and [*] array groups, relative to the selected value.
        var path: String
        var occurrences: Int
        var missingFromParentObjects: Int
        var types: [String: Int]
    }

    /// Breadth-first groups preserve exact counts for each emitted path. Unexpanded groups never
    /// become zero-count facts. Depth, groups, visited values and encoded paths are independently bounded.
    private static func structure(of root: Any) -> (nodes: [StructureNode], limits: [String]) {
        struct Group { var path: String; var values: [Any]; var missing: Int; var depth: Int }
        var queue = [Group(path: "$", values: [root], missing: 0, depth: 0)]
        var nodes: [StructureNode] = []
        var limits = Set<String>()
        var visits = 0
        var index = 0
        while index < queue.count {
            let group = queue[index]
            index += 1
            guard nodes.count < 32 else { limits.insert("node_limit"); break }
            guard visits + group.values.count <= 20_000 else { limits.insert("visit_limit"); continue }
            visits += group.values.count
            var types: [String: Int] = [:]
            for value in group.values { types[type(value), default: 0] += 1 }
            nodes.append(StructureNode(path: group.path, occurrences: group.values.count,
                missingFromParentObjects: group.missing, types: types))
            let objects = group.values.compactMap { $0 as? [String: Any] }
            let arrays = group.values.compactMap { $0 as? [Any] }
            let keys = Set(objects.flatMap { $0.keys }).sorted()
            guard group.depth < 4 else {
                if !keys.isEmpty || arrays.contains(where: { !$0.isEmpty }) { limits.insert("depth_limit") }
                continue
            }
            for key in keys {
                guard key.utf8.count <= 128,
                      let quoted = try? JSONEncoder().encode(key) else { limits.insert("path_limit"); continue }
                let path = group.path + "[" + String(decoding: quoted, as: UTF8.self) + "]"
                guard path.utf8.count <= 256 else { limits.insert("path_limit"); continue }
                guard queue.count < 64 else { limits.insert("group_limit"); break }
                let values = objects.compactMap { $0[key] }
                queue.append(Group(path: path, values: values, missing: objects.count - values.count, depth: group.depth + 1))
            }
            if arrays.contains(where: { !$0.isEmpty }) {
                if queue.count < 64 {
                    queue.append(Group(path: group.path + "[*]", values: arrays.flatMap { $0 }, missing: 0, depth: group.depth + 1))
                } else { limits.insert("group_limit") }
            }
        }
        return (nodes, limits.sorted())
    }

    private static func select(_ root: Any, tokens: [String]) -> Any? {
        var value = root
        for token in tokens {
            if let object = value as? [String: Any], let next = object[token] { value = next }
            else if let array = value as? [Any], let index = Int(token), String(index) == token,
                    array.indices.contains(index) { value = array[index] }
            else { return nil }
        }
        return value
    }

    private static func type(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if value is [String: Any] { return "object" }
        if value is [Any] { return "array" }
        if value is String { return "string" }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number"
        }
        return "unknown"
    }
}
