//
//  JSONTreeNode.swift
//  JoesProxy
//
//  Tree model for JSON display. Represents JSON values as expandable nodes
//  in a folder-like structure (objects and arrays have children; primitives are leaves).
//

import Foundation

/// Thread-safe caching box for lazy child node evaluation in the JSON tree viewer.
final class JSONTreeChildrenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _cached: [JSONTreeNode]?
    private let provider: (@Sendable () -> [JSONTreeNode])?
    let count: Int

    init(count: Int, provider: @escaping @Sendable () -> [JSONTreeNode]) {
        self.count = count
        self.provider = provider
        self._cached = nil
    }

    init(eager: [JSONTreeNode]) {
        self.count = eager.count
        self.provider = nil
        self._cached = eager
    }

    var resolved: [JSONTreeNode] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = _cached {
            return cached
        }
        if let provider {
            let result = provider()
            _cached = result
            return result
        }
        return []
    }
}

/// A lazily-evaluated, thread-safe collection of child nodes for JSON objects and arrays.
struct JSONTreeChildren: RandomAccessCollection, Sendable, ExpressibleByArrayLiteral {
    typealias Element = JSONTreeNode
    typealias Index = Int

    private let box: JSONTreeChildrenBox

    init(count: Int, provider: @escaping @Sendable () -> [JSONTreeNode]) {
        self.box = JSONTreeChildrenBox(count: count, provider: provider)
    }

    init(_ children: [JSONTreeNode]) {
        self.box = JSONTreeChildrenBox(eager: children)
    }

    init(arrayLiteral elements: JSONTreeNode...) {
        self.box = JSONTreeChildrenBox(eager: elements)
    }

    var count: Int {
        box.count
    }

    var isEmpty: Bool {
        box.count == 0
    }

    var startIndex: Int { 0 }
    var endIndex: Int { box.count }

    subscript(position: Int) -> JSONTreeNode {
        box.resolved[position]
    }

    var asArray: [JSONTreeNode] {
        box.resolved
    }
}

/// A node in the JSON tree for the JSON viewer.
///
/// Objects and arrays are containers with expandable children; strings, numbers, booleans, and null are leaves.
enum JSONTreeNode: Sendable {
    case object(key: String?, children: JSONTreeChildren)
    case array(key: String?, children: JSONTreeChildren)
    case string(key: String?, value: String)
    case number(key: String?, value: String)
    case bool(key: String?, value: Bool)
    case null(key: String?)

    static func object(key: String?, children: [JSONTreeNode]) -> JSONTreeNode {
        .object(key: key, children: JSONTreeChildren(children))
    }

    static func array(key: String?, children: [JSONTreeNode]) -> JSONTreeNode {
        .array(key: key, children: JSONTreeChildren(children))
    }

    /// Whether this node can be expanded (has children).
    var isExpandable: Bool {
        switch self {
        case .object(_, let children), .array(_, let children):
            return !children.isEmpty
        case .string, .number, .bool, .null:
            return false
        }
    }

    /// Child nodes for objects and arrays.
    var children: JSONTreeChildren {
        switch self {
        case .object(_, let children), .array(_, let children):
            return children
        case .string, .number, .bool, .null:
            return []
        }
    }

    /// Display label for the node (key or value summary).
    var label: String {
        switch self {
        case .object(let key, let children):
            if let key {
                return "\(key): \(children.count) items"
            }
            return "{ \(children.count) items }"
        case .array(let key, let children):
            if let key {
                return "\(key): [\(children.count)]"
            }
            return "[ \(children.count) items ]"
        case .string(let key, let value):
            let truncated = value.count > 60 ? String(value.prefix(60)) + "…" : value
            let escaped = truncated.replacingOccurrences(of: "\"", with: "\\\"")
            if let key {
                return "\(key): \"\(escaped)\""
            }
            return "\"\(escaped)\""
        case .number(let key, let value):
            if let key {
                return "\(key): \(value)"
            }
            return value
        case .bool(let key, let value):
            if let key {
                return "\(key): \(value)"
            }
            return String(value)
        case .null(let key):
            if let key {
                return "\(key): null"
            }
            return "null"
        }
    }

    /// SFSymbol name for the node type.
    var iconName: String {
        switch self {
        case .object:
            return "folder.fill"
        case .array:
            return "square.stack.3d.up.fill"
        case .string:
            return "text.quote"
        case .number:
            return "number"
        case .bool:
            return "checkmark.circle"
        case .null:
            return "questionmark.circle"
        }
    }
}

