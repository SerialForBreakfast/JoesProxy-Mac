import Foundation

enum CLIArtifactArguments {
    private static let common: Set<String> = ["endpoint", "timeout", "approval-timeout", "receipt-output",
        "receipt-workflow", "receipt-version", "receipt-environment"]

    static func calculation(_ invocation: CLIInvocation, live: Bool) throws -> [String: Any] {
        let operationName = try required("operation", invocation)
        let kinds = ["rowCount", "fieldStats", "distinctCount", "numericSummary", "groupCount", "topRows"]
        guard kinds.contains(operationName) else { throw CLIError.invalidArguments("Choose a documented calculation operation.") }
        let dataset = try required("dataset", invocation)
        var allowed = common.union(["dataset", "operation", "selection-pointer"])
        var operation: [String: Any] = ["kind": operationName]
        if operationName != "rowCount" {
            allowed.insert("field-pointer")
            operation["fieldPointer"] = try required("field-pointer", invocation, allowsEmpty: true)
        }
        if operationName == "groupCount" || operationName == "topRows" {
            allowed.insert("limit")
            if let text = invocation.options["limit"] {
                guard let limit = Int(text), (1...20).contains(limit) else { throw CLIError.invalidArguments("--limit must be 1...20.") }
                operation["limit"] = limit
            }
        }
        if operationName == "topRows" {
            allowed.insert("order")
            if let order = invocation.options["order"] {
                guard ["asc", "desc"].contains(order) else { throw CLIError.invalidArguments("--order must be asc or desc.") }
                operation["order"] = order
            }
        }
        var result: [String: Any] = ["selectionPointer": invocation.options["selection-pointer"] ?? "", "operation": operation]
        if live {
            allowed.insert("session-ids")
            guard ["responseJSON", "sessionMetadata"].contains(dataset) else { throw CLIError.invalidArguments("Live calculations require responseJSON or sessionMetadata.") }
            let ids = try required("session-ids", invocation).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard (1...256).contains(ids.count), ids.allSatisfy({ UUID(uuidString: $0) != nil }),
                  Set(ids).count == ids.count, dataset != "responseJSON" || ids.count == 1 else {
                throw CLIError.invalidArguments("Select 1...256 distinct session IDs, or exactly one for responseJSON.")
            }
            result["sessionIDs"] = ids
            result["dataset"] = dataset
        } else {
            allowed.formUnion(["handle", "snapshot-revision"])
            result["handle"] = try required("handle", invocation)
            result["snapshotRevision"] = try required("snapshot-revision", invocation)
            var selection: [String: Any] = ["kind": dataset]
            switch dataset {
            case "json": break
            case "responseJSON":
                allowed.insert("record-index")
                selection["recordIndex"] = try index(required("record-index", invocation))
            case "sessionMetadata":
                allowed.insert("record-indices")
                if let text = invocation.options["record-indices"] {
                    let indices = try text.split(separator: ",", omittingEmptySubsequences: false).map { try index(String($0)) }
                    guard !indices.isEmpty, indices.count <= 256, indices == indices.sorted(), Set(indices).count == indices.count else {
                        throw CLIError.invalidArguments("--record-indices must be 1...256 distinct ascending indices.")
                    }
                    selection["recordIndices"] = indices
                }
            default: throw CLIError.invalidArguments("Use json, responseJSON or sessionMetadata.")
            }
            result["dataset"] = selection
        }
        try validateOptions(invocation, allowed: allowed)
        return result
    }

    static func compare(_ invocation: CLIInvocation) throws -> [String: Any] {
        var allowed = common.union(["selection-pointer"])
        var arguments: [String: Any] = [:]
        for side in ["baseline", "candidate"] {
            allowed.formUnion([side + "-handle", side + "-revision", side + "-record"])
            let handle = try required(side + "-handle", invocation)
            let revision = try required(side + "-revision", invocation)
            guard UUID(uuidString: handle) != nil, UUID(uuidString: revision) != nil else {
                throw CLIError.invalidArguments("Each selection needs a valid handle and snapshot revision.")
            }
            arguments[side] = ["handle": handle, "snapshotRevision": revision,
                "recordIndex": try index(required(side + "-record", invocation))] as [String: Any]
        }
        try validateOptions(invocation, allowed: allowed)
        if let pointer = invocation.options["selection-pointer"] {
            guard pointer.utf8.count <= 512, pointer.isEmpty || pointer.hasPrefix("/") else {
                throw CLIError.invalidArguments("Use a JSON pointer up to 512 UTF-8 bytes.")
            }
            arguments["selectionPointer"] = pointer
        }
        return arguments
    }

    static func brief(_ invocation: CLIInvocation) throws -> [String: Any] {
        guard Set(invocation.options.keys).isSubset(of: common.union(["handle", "snapshot-revision", "record-index", "selection-pointer"])),
              invocation.flags.isSubset(of: ["json", "ndjson", "quiet", "include-structure"]) else {
            throw CLIError.invalidArguments("Unsupported artifact brief option.")
        }
        var args: [String: Any] = ["handle": try required("handle", invocation),
            "snapshotRevision": try required("snapshot-revision", invocation),
            "recordIndex": try index(required("record-index", invocation))]
        if let pointer = invocation.options["selection-pointer"] {
            guard pointer.utf8.count <= 512, pointer.isEmpty || pointer.hasPrefix("/") else {
                throw CLIError.invalidArguments("Use a JSON pointer up to 512 UTF-8 bytes.")
            }
            args["selectionPointer"] = pointer
        }
        if invocation.flags.contains("include-structure") { args["includeStructure"] = true }
        return args
    }

    static func search(_ invocation: CLIInvocation, inventory: Bool, input: FileHandle = .standardInput) throws -> [String: Any] {
        var allowed = common.union(["handle", "snapshot-revision", "record-indices", "method", "status-code", "limit", "cursor"])
        if !inventory { allowed.formUnion(["literal", "dataset"]) }
        var flags: Set<String> = ["json", "quiet", "ndjson"]
        if !inventory { flags.insert("literal-stdin") }
        guard Set(invocation.options.keys).isSubset(of: allowed), invocation.flags.isSubset(of: flags) else {
            throw CLIError.invalidArguments("Unsupported artifact search option.")
        }
        var args: [String: Any] = ["handle": try required("handle", invocation), "snapshotRevision": try required("snapshot-revision", invocation)]
        if let cursor = invocation.options["cursor"] { args["cursor"] = cursor }
        if let method = invocation.options["method"] {
            guard (1...256).contains(method.utf8.count) else { throw CLIError.invalidArguments("Invalid method length.") }
            args["method"] = method
        }
        for (option, field, range) in [("status-code", "statusCode", 100...599), ("limit", "limit", 1...50)] {
            if let text = invocation.options[option] {
                guard let number = Int(text), range.contains(number) else { throw CLIError.invalidArguments("Invalid --\(option).") }
                args[field] = number
            }
        }
        if let text = invocation.options["record-indices"] {
            let values = try text.split(separator: ",", omittingEmptySubsequences: false).map { try index(String($0)) }
            guard (1...256).contains(values.count), values == values.sorted(), Set(values).count == values.count else {
                throw CLIError.invalidArguments("Use distinct ascending record indices.")
            }
            args["recordIndices"] = values
        }
        if !inventory {
            let dataset = try required("dataset", invocation)
            guard ["sourceUTF8", "responseJSON"].contains(dataset) else { throw CLIError.invalidArguments("Unknown search dataset.") }
            args["dataset"] = dataset
            let literal: String
            if invocation.flags.contains("literal-stdin") {
                guard invocation.options["literal"] == nil else { throw CLIError.invalidArguments("Choose one literal input.") }
                var data = Data()
                while data.count <= 4096, let part = try input.read(upToCount: 4097 - data.count), !part.isEmpty { data.append(part) }
                guard let text = String(data: data, encoding: .utf8) else { throw CLIError.invalidArguments("Literal must be UTF-8.") }
                literal = text
            } else { literal = try required("literal", invocation) }
            guard (3...4096).contains(literal.utf8.count) else { throw CLIError.invalidArguments("Literal must contain 3–4096 UTF-8 bytes.") }
            args["literal"] = literal
        }
        return args
    }

    static func source(_ invocation: CLIInvocation, action: String) throws -> [String: Any] {
        var allowed = common
        var result: [String: Any] = [:]
        switch action {
        case "register":
            allowed.formUnion(["request-key", "kind", "scope", "ttl-seconds"])
            let key = try required("request-key", invocation)
            guard UUID(uuidString: key) != nil else { throw CLIError.invalidArguments("--request-key must be a fresh UUID.") }
            let kind = try required("kind", invocation)
            guard ["recording", "har", "json", "text", "image", "effectBundle"].contains(kind) else { throw CLIError.invalidArguments("Unsupported source kind.") }
            let scopes = try required("scope", invocation).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard Set(scopes).count == scopes.count, scopes.contains("metadata-v1"),
                  Set(scopes).isSubset(of: ["metadata-v1", "calculations-v1", "search-v1", "brief-v1"]) else { throw CLIError.invalidArguments("Use metadata-v1, optionally with calculations-v1, search-v1 or brief-v1.") }
            if scopes.contains("brief-v1"), !["recording", "har"].contains(kind) {
                throw CLIError.invalidArguments("Response briefs require a recording or HAR.")
            }
            result = ["requestKey": key, "kind": kind, "scopes": scopes.sorted()]
            if let text = invocation.options["ttl-seconds"] {
                guard let ttl = Int(text), (60...3600).contains(ttl) else { throw CLIError.invalidArguments("--ttl-seconds must be 60...3600.") }
                result["ttlSeconds"] = ttl
            }
        case "status":
            allowed.insert("request-key")
            result["requestKey"] = try required("request-key", invocation)
        case "inspect", "release":
            allowed.insert("handle")
            result["handle"] = try required("handle", invocation)
        default: throw CLIError.invalidArguments("Unknown artifact source command.")
        }
        try validateOptions(invocation, allowed: allowed)
        return result
    }

    private static func validateOptions(_ invocation: CLIInvocation, allowed: Set<String>) throws {
        guard Set(invocation.options.keys).isSubset(of: allowed),
              invocation.flags.isSubset(of: ["wait-for-approval", "json", "quiet", "ndjson"]) else {
            throw CLIError.invalidArguments("Unsupported option for this artifact operation; no path, query file or script input is accepted.")
        }
    }

    private static func required(_ name: String, _ invocation: CLIInvocation, allowsEmpty: Bool = false) throws -> String {
        guard let value = invocation.options[name], allowsEmpty || !value.isEmpty else { throw CLIError.invalidArguments("--\(name) is required.") }
        return value
    }

    private static func index(_ text: String) throws -> Int {
        guard let value = Int(text), (0..<1000).contains(value) else { throw CLIError.invalidArguments("Record indices must be 0...999.") }
        return value
    }
}
