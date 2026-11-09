import Foundation

enum CollectionMockError: String, Error, Sendable {
    case invalidJSON, invalidPointer, missingValue, incompatibleType
    case invalidTemplate, missingIdentity, duplicateIdentity, invalidCount, sizeLimit
}

struct CollectionMockEdit: Codable, Equatable, Sendable {
    let pointer: String
    let value: BookmarkJSONValue
}

struct CollectionTemplateItem: Codable, Equatable, Sendable {
    struct ImageBinding: Codable, Equatable, Sendable {
        let pointer: String
        let assetID: String
    }
    let edits: [CollectionMockEdit]
    var images: [ImageBinding] = []
}

struct CollectionMockDraft: Codable, Equatable, Sendable {
    enum Position: String, Codable, Sendable { case append, prepend }
    enum IdentityPresence: String, Codable, Sendable { case required, wherePresent }
    let collectionPointer: String
    /// Exactly one of item and templateIndex must be supplied.
    let item: BookmarkJSONValue?
    let templateIndex: Int?
    let edits: [CollectionMockEdit]
    let identityPointers: [String]
    let countPointers: [String]
    let position: Position
    var identityPresence: IdentityPresence? = nil
    var ignoredQueryNames: [String]? = nil
    /// Captured fixtures only. Live single-item plans must reject this field.
    var expansionItems: [CollectionTemplateItem]? = nil
}

/// Immutable operations prepared against one source response. Contains no file references or authority.
struct CompiledCollectionMock: Codable, Equatable, Sendable {
    let collectionPointer: String
    let item: BookmarkJSONValue
    let identityPointers: [String]
    let countPointers: [String]
    let position: CollectionMockDraft.Position
    var identityPresence: CollectionMockDraft.IdentityPresence? = nil

    /// Human-readable, sanitized rendering shared by the MCP preview/propose effect summary and
    /// the `activate_collection_mock` disclosure — the same renderer both places use, so a human
    /// sees an identical description at preview time and at activation time. Uses `item`'s
    /// sanitized `disclosureDescriptor` (byte count + digest, never raw captured content), matching
    /// how `liveRewriteSummary` never prints a rewrite's raw override literal either.
    var mcpSummary: String {
        var parts = ["\(position.rawValue) item \(item.disclosureDescriptor) into \(collectionPointer)"]
        if !identityPointers.isEmpty {
            parts.append("identity: \(identityPointers.joined(separator: ", "))")
        }
        if !countPointers.isEmpty {
            parts.append("count fields: \(countPointers.joined(separator: ", "))")
        }
        return parts.joined(separator: "; ")
    }
}

enum CollectionMockOutcome: Equatable, Sendable {
    case applied(Data, beforeCount: Int, afterCount: Int)
    case alreadyPresent
}

/// Pure, bounded compiler. Callers must schedule this CPU work off UI and network event loops.
enum CollectionMockCompiler {
    static let maximumBodyBytes = 5 * 1_024 * 1_024

    static func prepare(source: Data, draft: CollectionMockDraft) throws -> CompiledCollectionMock {
        let root = try parse(source)
        let plan = try prepare(root: root, draft: draft)
        if let result = try apply(root: root, plan: plan) { _ = try serialize(result.root) }
        return plan
    }

    static func prepare(root: BookmarkJSONValue, draft: CollectionMockDraft) throws -> CompiledCollectionMock {
        guard draft.expansionItems == nil else { throw CollectionMockError.invalidTemplate }
        let collection = try array(at: draft.collectionPointer, root: root)
        guard (draft.item == nil) != (draft.templateIndex == nil) else { throw CollectionMockError.invalidTemplate }
        var item: BookmarkJSONValue
        if let supplied = draft.item {
            item = supplied
        } else if let index = draft.templateIndex, collection.indices.contains(index) {
            item = collection[index]
        } else {
            throw CollectionMockError.invalidTemplate
        }
        guard case .object = item else { throw CollectionMockError.incompatibleType }
        for edit in draft.edits {
            let path = try pointer(edit.pointer)
            let original = try value(at: path, in: item)
            guard original.kind == edit.value.kind || edit.value == .null else {
                throw CollectionMockError.incompatibleType
            }
            item = try replacing(path, in: item, with: edit.value)
        }
        guard !draft.identityPointers.isEmpty,
              Set(draft.identityPointers).count == draft.identityPointers.count,
              Set(draft.countPointers).count == draft.countPointers.count else {
            throw CollectionMockError.missingIdentity
        }
        for path in draft.identityPointers {
            let identity = try value(at: pointer(path), in: item)
            guard identity.kind == .string || identity.kind == .number else { throw CollectionMockError.missingIdentity }
            if identity == .string("") { throw CollectionMockError.missingIdentity }
        }
        let compiled = CompiledCollectionMock(collectionPointer: draft.collectionPointer, item: item,
            identityPointers: draft.identityPointers, countPointers: draft.countPointers, position: draft.position,
            identityPresence: draft.identityPresence)
        _ = try serialize(item)
        // Preparation is strict; live application can instead report alreadyPresent without changing bytes.
        guard let _ = try apply(root: root, plan: compiled) else { throw CollectionMockError.duplicateIdentity }
        return compiled
    }

    static func apply(source: Data, plan: CompiledCollectionMock) throws -> CollectionMockOutcome {
        guard let result = try apply(root: parse(source), plan: plan) else { return .alreadyPresent }
        return .applied(try serialize(result.root), beforeCount: result.before, afterCount: result.after)
    }

    /// Keeps batch work in one parsed tree. A nil result means an identity collision.
    static func apply(root source: BookmarkJSONValue, plan: CompiledCollectionMock)
        throws -> (root: BookmarkJSONValue, before: Int, after: Int)? {
        guard !plan.identityPointers.isEmpty,
              Set(plan.identityPointers).count == plan.identityPointers.count,
              Set(plan.countPointers).count == plan.countPointers.count,
              case .object = plan.item else { throw CollectionMockError.missingIdentity }
        var root = source
        var collection = try array(at: plan.collectionPointer, root: root)
        let collectionPath = try pointer(plan.collectionPointer)
        let identities = try plan.identityPointers.map { path in
            let components = try pointer(path)
            let expected = try value(at: components, in: plan.item)
            guard expected.kind == .string || expected.kind == .number,
                  expected != .string("") else { throw CollectionMockError.missingIdentity }
            return (components, expected)
        }
        let counts = try plan.countPointers.map { path in
            let components = try pointer(path)
            // Counts cannot modify collection members or replace the collection itself.
            guard !components.starts(with: collectionPath),
                  case .number(let text) = try value(at: components, in: root),
                  let count = Int(text), count >= 0, count < Int.max else {
                throw CollectionMockError.invalidCount
            }
            return (components, count)
        }
        var alreadyPresent = false
        for existing in collection {
            for (components, expected) in identities {
                let actual: BookmarkJSONValue
                do { actual = try value(at: components, in: existing) }
                catch CollectionMockError.missingValue where plan.identityPresence == .wherePresent {
                    // Only absent keys opt out. Nulls, malformed containers and type drift still fail.
                    continue
                }
                guard actual.kind == expected.kind else { throw CollectionMockError.incompatibleType }
                // Each declared identity is independently unique, rather than an inferred composite key.
                if try identitiesEqual(actual, expected) { alreadyPresent = true }
            }
        }
        // A collision is a no-op only after the entire declared contract has been checked.
        if alreadyPresent { return nil }
        let before = collection.count
        switch plan.position {
        case .append: collection.append(plan.item)
        case .prepend: collection.insert(plan.item, at: 0)
        }
        root = try replacing(pointer(plan.collectionPointer), in: root, with: .array(collection))
        for (components, count) in counts {
            root = try replacing(components, in: root, with: .number(String(count + 1)))
        }
        return (root, before, collection.count)
    }

    static func serialize(_ root: BookmarkJSONValue) throws -> Data {
        let data: Data
        do { data = try JSONSerialization.data(withJSONObject: foundationValue(root), options: [.sortedKeys, .fragmentsAllowed]) }
        catch { throw CollectionMockError.invalidJSON }
        guard data.count <= maximumBodyBytes else { throw CollectionMockError.sizeLimit }
        return data
    }

    static func pointer(_ text: String) throws -> [String] {
        if text.isEmpty { return [] }
        guard text.hasPrefix("/"), text.utf8.count <= 4_096,
              text.filter({ $0 == "/" }).count <= 128 else { throw CollectionMockError.invalidPointer }
        return try text.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map { token in
            var result = ""
            var iterator = token.makeIterator()
            while let character = iterator.next() {
                if character != "~" { result.append(character); continue }
                switch iterator.next() {
                case "0": result.append("~")
                case "1": result.append("/")
                default: throw CollectionMockError.invalidPointer
                }
            }
            return result
        }
    }

    private static func array(at pointerText: String, root: BookmarkJSONValue) throws -> [BookmarkJSONValue] {
        guard case .array(let values) = try value(at: pointer(pointerText), in: root) else {
            throw CollectionMockError.incompatibleType
        }
        return values
    }

    private static func index(_ key: String, count: Int) throws -> Int {
        guard let index = Int(key), String(index) == key, index >= 0, index < count else {
            throw CollectionMockError.invalidPointer
        }
        return index
    }

    static func value(at path: [String], in root: BookmarkJSONValue) throws -> BookmarkJSONValue {
        guard let key = path.first else { return root }
        let child: BookmarkJSONValue
        switch root {
        case .object(let values):
            guard let found = values[key] else { throw CollectionMockError.missingValue }
            child = found
        case .array(let values): child = values[try index(key, count: values.count)]
        default: throw CollectionMockError.incompatibleType
        }
        return try value(at: Array(path.dropFirst()), in: child)
    }

    static func replacing(_ path: [String], in root: BookmarkJSONValue, with replacement: BookmarkJSONValue) throws -> BookmarkJSONValue {
        guard let key = path.first else { return replacement }
        let remaining = Array(path.dropFirst())
        switch root {
        case .object(var values):
            guard let child = values[key] else { throw CollectionMockError.missingValue }
            values[key] = try replacing(remaining, in: child, with: replacement)
            return .object(values)
        case .array(var values):
            let offset = try index(key, count: values.count)
            values[offset] = try replacing(remaining, in: values[offset], with: replacement)
            return .array(values)
        default: throw CollectionMockError.incompatibleType
        }
    }

    static func parse(_ data: Data) throws -> BookmarkJSONValue {
        guard data.count <= maximumBodyBytes else { throw CollectionMockError.sizeLimit }
        do { return try convert(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) }
        catch let error as CollectionMockError { throw error }
        catch { throw CollectionMockError.invalidJSON }
    }

    private static func convert(_ value: Any) throws -> BookmarkJSONValue {
        switch value {
        case is NSNull: return .null
        case let text as String: return .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.stringValue)
        case let values as [Any]: return .array(try values.map(convert))
        case let values as [String: Any]: return .object(try values.mapValues(convert))
        default: throw CollectionMockError.invalidJSON
        }
    }

    private static func identitiesEqual(_ lhs: BookmarkJSONValue, _ rhs: BookmarkJSONValue) throws -> Bool {
        if case .number = lhs, case .number = rhs,
           let left = try foundationValue(lhs) as? NSNumber, let right = try foundationValue(rhs) as? NSNumber {
            return left.compare(right) == .orderedSame
        }
        return lhs == rhs
    }

    static func foundationValue(_ value: BookmarkJSONValue) throws -> Any {
        switch value {
        case .number(let text):
            let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            guard let number = parsed as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw CollectionMockError.incompatibleType
            }
            return number
        case .array(let values): return try values.map(foundationValue)
        case .object(let values): return try values.mapValues(foundationValue)
        case .bool(let value): return value
        case .string(let value): return value
        case .null: return NSNull()
        }
    }
}
