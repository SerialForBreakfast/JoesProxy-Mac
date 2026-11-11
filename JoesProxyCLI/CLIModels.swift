import Foundation

enum CLIRuntimeIdentity {
    /// Kept equal to `MCPCapabilitiesRevision.current`; an app-target test prevents drift.
    static let capabilitiesRevision = 29

    static func expectation(bundle: Bundle = .main) -> [String: Any] {
        let marketingVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
        let buildVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "development"
        return [
            "marketingVersion": marketingVersion,
            "buildVersion": buildVersion,
            "capabilitiesBundleVersion": "\(marketingVersion)+\(capabilitiesRevision)",
            "skillVersion": marketingVersion
        ]
    }
}

enum CLIExitCode: Int32 {
    case success = 0
    case invalidArguments = 2
    case serverUnavailable = 10
    case authenticationFailed = 11
    case approvalRequired = 20
    case policyDenied = 21
    case timedOut = 22
    case partialResult = 23
    case staleSession = 24
    case rateLimited = 25
    case staleProposal = 26
    case internalFailure = 70
}

enum CLIOutputMode: String {
    case human
    case json
    case ndjson
    case quiet
}

struct CLIInvocation {
    var command: [String]
    var options: [String: String]
    var flags: Set<String>
    var outputMode: CLIOutputMode
    var endpointURL: URL
    var timeout: TimeInterval
    /// Everything after a bare `--` token, verbatim and unparsed — forwarded as-is to
    /// `app launch`/`mcp start` as launch arguments for the app process itself (e.g.
    /// `joesproxyctl app launch -- --compact-mode`). Empty for every other command; `--` is
    /// otherwise not a recognized option for this CLI, so no other command needs to reserve it.
    var launchArguments: [String]

    static func parse(_ arguments: [String]) throws -> CLIInvocation {
        var command: [String] = []
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var outputMode: CLIOutputMode = .human
        var endpoint = URL(string: "http://127.0.0.1:9091/mcp")!
        var timeout: TimeInterval = 45
        var launchArguments: [String] = []
        var index = 0

        let valueOptions: Set<String> = [
            "literal",
            "dataset", "field-pointer", "order", "handle", "snapshot-revision", "request-key", "kind", "ttl-seconds", "record-index", "record-indices",
            "baseline-handle", "baseline-revision", "baseline-record", "candidate-handle", "candidate-revision", "candidate-record",
            "receipt-output", "receipt-workflow", "receipt-version", "receipt-environment", "baseline-receipt", "candidate-receipt",
            "expected-revision", "scope", "recovery-id",
            "query", "topic", "section", "category", "source", "max-response-bytes",
            "after-marker",
            "revision-id",
            "activation-id", "expected-phase-id",
            "bundle-id", "mode", "target-outcome", "outcome-source", "baseline-window-id", "modified-window-id",
            "client-address",
            "image-file", "image-pointer", "retain-image-url", "image-delivery-url", "image-reference", "images", "related-responses",
            "endpoint", "timeout", "projection", "limit", "cursor", "since-sequence", "if-state-token",
            "method", "host-category", "session-id-prefix", "analysis", "started-after", "started-before", "path-contains",
            "sample-time", "format", "output", "interval", "approval-timeout",
            "if-brief-digest", "selection-pointer", "body-source", "header-source", "scheme", "host", "port", "path", "match-mode", "json-path",
            "operation", "value", "value-type", "repeat-policy", "label",
            "preview-digest", "idempotency-key", "input", "outcome",
            "domain", "since", "until", "max-sessions", "name", "detail", "edits",
            "text", "offset", "length", "draft", "revision", "profile-id", "run-id",
            "fixture-run-id", "preset-id", "status-code", "at", "session-id", "scope", "experiment-id",
            "directory", "not-found", "missing-file-policy", "file", "content-type", "ttl", "pack-id",
            "presentation-mode", "time-shift-mode", "intent", "window-segments", "loop-boundary",
            "segment-uri-identity", "target-duration", "program-date-time", "playlist-cache",
            "playlist-max-age",
            "hypothesis", "expected", "lifetime", "path-match", "capture-epoch", "fingerprint",
            "terminal", "reason", "summary", "confidence", "evidence-id", "source-kind",
            "other-fingerprint", "with", "proposal-token", "graphql-operation-name",
            "match-query-key", "match-query-value",
            "collection-pointer", "item-json", "identity-pointers", "count-pointers",
            // Advanced agentic diagnostics (AG-1..AG-6) and related tool families
            "target-bug", "graph-id", "evidence-summary", "nodes", "session-ids", "canaries",
            "url-pattern", "fault-kind", "delay-ms", "target-token-index", "target-batch",
            "endpoints", "spacing-ms", "plan-id", "outcome-summary", "observed-error",
            "baseline-sessions", "candidate-sessions", "baseline-name", "candidate-name",
            "intent-label", "example-queries", "response-body", "confidence-threshold", "rule-id",
            "live-session", "baseline-session", "live-sessions", "target-value", "sink-session",
            "target-keypaths", "strategy", "custom-host", "backend-id", "state", "collection",
            "window-seconds", "log-snippet", "master-session", "variant-sessions",
            "reference-session", "manifest-session", "license-sessions", "media-sessions",
            "query", "target-url", "collection-keypath", "bound-asset-kind", "custom-asset-url",
            "client-scope", "position", "plan-id",
            "since-marker", "rule", "field"
        ]
        let booleanFlags: Set<String> = [
            "literal-stdin",
            "json", "ndjson", "quiet", "wait-for-approval", "include-result",
            "include-structure", "include-headers", "include-query", "include-body", "include-response-headers",
            "include-context", "enable-after", "drop-connection", "accept-confounder",
            "force-no-cache", "replace-conflicts",
            "evidence-matches", "error-detected", "client-crashed", "no-preserve-urls",
            "no-preserve-ids", "integrations"
        ]

        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                command.append(argument)
                index += 1
                continue
            }
            if argument == "--" {
                launchArguments = Array(arguments[(index + 1)...])
                break
            }
            let name = String(argument.dropFirst(2))
            if booleanFlags.contains(name) {
                flags.insert(name)
                switch name {
                case "json": outputMode = .json
                case "ndjson": outputMode = .ndjson
                case "quiet": outputMode = .quiet
                default: break
                }
                index += 1
                continue
            }
            guard valueOptions.contains(name), index + 1 < arguments.count else {
                throw CLIError.invalidArguments("Unknown option or missing value: --\(name)")
            }
            let value = arguments[index + 1]
            options[name] = value
            index += 2
        }

        if let endpointValue = options["endpoint"] {
            guard let parsed = URL(string: endpointValue), parsed.scheme == "http",
                  parsed.host == "127.0.0.1" || parsed.host == "localhost" else {
                throw CLIError.invalidArguments("--endpoint must be a loopback HTTP URL.")
            }
            endpoint = parsed
        }
        if let timeoutValue = options["timeout"] {
            guard let parsed = TimeInterval(timeoutValue), parsed > 0, parsed <= 300 else {
                throw CLIError.invalidArguments("--timeout must be between 0 and 300 seconds.")
            }
            timeout = parsed
        }
        for (name, value) in [("since", options["since"]), ("until", options["until"])] {
            guard let value else { continue }
            guard ISO8601DateFormatter().date(from: value) != nil else {
                throw CLIError.invalidArguments("--\(name) must be an ISO 8601 date-time.")
            }
        }
        return CLIInvocation(
            command: command,
            options: options,
            flags: flags,
            outputMode: outputMode,
            endpointURL: endpoint,
            timeout: timeout,
            launchArguments: launchArguments
        )
    }
}

struct CLIReproPackage: Decodable {
    let title: String
    let sessions: [CLIReproSession]
}

struct CLIReproSession: Decodable {
    let id: String
    let request: CLIReproRequest
    let expectedOutcome: CLIReproExpectedOutcome
}

struct CLIReproRequest: Decodable {
    let method: String
    let scheme: String
    let host: String
    let port: Int?
    let path: String
}

struct CLIReproExpectedOutcome: Decodable {
    let statusCode: Int?
}

enum CLIHLSCodecsArguments {
    static let maxEditsBytes = 64 * 1024
    private static let allowedMatchModes: Set<String> = ["ignoreQuery", "exactPath", "pathSuffix"]

    /// Resolves `--match-mode` for `hls codecs preview` (default `ignoreQuery`).
    static func matchMode(invocation: CLIInvocation) throws -> String {
        let mode = invocation.options["match-mode"] ?? "ignoreQuery"
        guard allowedMatchModes.contains(mode) else {
            throw CLIError.invalidArguments(
                "--match-mode must be ignoreQuery, exactPath, or pathSuffix."
            )
        }
        if mode == "pathSuffix" {
            guard let path = invocation.options["path"], !path.isEmpty else {
                throw CLIError.invalidArguments("pathSuffix requires --path <suffix>.")
            }
        }
        return mode
    }

    static func edits(invocation: CLIInvocation) throws -> [[String: Any]] {
        guard let path = invocation.options["edits"], !path.isEmpty else {
            throw CLIError.invalidArguments("hls codecs preview requires --edits <json-file>.")
        }
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? NSNumber, size.intValue > maxEditsBytes {
                throw CLIError.invalidArguments("CODECS edits exceed the 64 KiB CLI limit.")
            }
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.invalidArguments("Unable to read CODECS edits: \(error.localizedDescription)")
        }
        guard data.count <= maxEditsBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let edits = object as? [[String: Any]],
              edits.count <= 100 else {
            throw CLIError.invalidArguments("CODECS edits must be a JSON array of at most 100 objects.")
        }
        for edit in edits {
            guard edit.keys.allSatisfy({ $0 == "variantRef" || $0 == "codecs" }),
                  let variantRef = edit["variantRef"] as? String, !variantRef.isEmpty,
                  let codecs = edit["codecs"] as? String, !codecs.isEmpty,
                  edit.count == 2 else {
                throw CLIError.invalidArguments("Each edit must contain only variantRef and codecs.")
            }
        }
        guard !edits.isEmpty else {
            throw CLIError.invalidArguments("CODECS edits must not be empty.")
        }
        return edits
    }
}

enum CLIResponseEditArguments {
    static let maxEditsBytes = 64 * 1024

    /// Loads generic `preview_response_edit` selector/operation JSON (array of edit objects).
    static func edits(invocation: CLIInvocation) throws -> [[String: Any]] {
        guard let path = invocation.options["edits"], !path.isEmpty else {
            throw CLIError.invalidArguments("response edit preview requires --edits <json-file>.")
        }
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? NSNumber, size.intValue > maxEditsBytes {
                throw CLIError.invalidArguments("Response edits exceed the 64 KiB CLI limit.")
            }
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.invalidArguments("Unable to read response edits: \(error.localizedDescription)")
        }
        guard data.count <= maxEditsBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let edits = object as? [[String: Any]],
              !edits.isEmpty,
              edits.count <= 100 else {
            throw CLIError.invalidArguments("Response edits must be a non-empty JSON array of at most 100 objects.")
        }
        return edits
    }
}

/// Generic reader for a bounded JSON array of objects passed via `--<flag> <json-file>`, used by
/// any command that needs structured (not flat/CSV) input — e.g. hypothesis-DAG node lists or
/// temporal-permutation endpoint lists.
enum CLIJSONArrayFileArguments {
    static let maxBytes = 64 * 1_024

    static func array(invocation: CLIInvocation, flag: String, commandDescription: String) throws -> [[String: Any]] {
        guard let path = invocation.options[flag], !path.isEmpty else {
            throw CLIError.invalidArguments("\(commandDescription) requires --\(flag) <json-file>.")
        }
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? NSNumber, size.intValue > maxBytes {
                throw CLIError.invalidArguments("--\(flag) file exceeds the 64 KiB CLI limit.")
            }
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.invalidArguments("Unable to read --\(flag): \(error.localizedDescription)")
        }
        guard data.count <= maxBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let array = object as? [[String: Any]],
              !array.isEmpty else {
            throw CLIError.invalidArguments("--\(flag) must be a non-empty JSON array of objects.")
        }
        return array
    }
}

enum CLIScenarioArguments {
    static let maxDraftBytes = 256 * 1_024

    static func draft(invocation: CLIInvocation) throws -> [String: Any] {
        guard let inputPath = invocation.options["input"], !inputPath.isEmpty else {
            throw CLIError.invalidArguments("scenario preview/draft requires --input <json-file>.")
        }
        let expandedPath = NSString(string: inputPath).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? NSNumber,
               fileSize.intValue > maxDraftBytes {
                throw CLIError.invalidArguments("Scenario draft exceeds the 256 KiB CLI limit.")
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= maxDraftBytes else {
                throw CLIError.invalidArguments("Scenario draft exceeds the 256 KiB CLI limit.")
            }
            guard let json = String(data: data, encoding: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  JSONSerialization.isValidJSONObject(object) else {
                throw CLIError.invalidArguments("Scenario draft must be one UTF-8 JSON object.")
            }
            return ["draftJSON": json]
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.invalidArguments("Unable to read scenario draft: \(error.localizedDescription)")
        }
    }

    static func identified(
        _ scenarioID: String,
        invocation: CLIInvocation,
        allowsOutcome: Bool = false
    ) throws -> [String: Any] {
        guard !scenarioID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError.invalidArguments("scenario ID must not be empty.")
        }
        var arguments: [String: Any] = ["scenarioID": scenarioID]
        if let outcome = invocation.options["outcome"] {
            guard allowsOutcome else {
                throw CLIError.invalidArguments("--outcome is supported only by scenario stop and cleanup.")
            }
            let allowed = ["completed", "failed", "inconclusive", "canceled"]
            guard allowed.contains(outcome) else {
                throw CLIError.invalidArguments("--outcome must be one of: \(allowed.joined(separator: ", ")).")
            }
            arguments["outcome"] = outcome
        }
        return arguments
    }
}

enum CLIScenarioProjection {
    static func compact(_ payload: [String: Any], toolName: String) -> [String: Any] {
        switch toolName {
        case "preview_test_scenario", "validate_test_scenario":
            let definition = payload["definition"] as? [String: Any]
            let disclosure = payload["approvalDisclosure"] as? [String: Any]
            return compactValues([
                "scenarioID": scenarioID(from: definition?["id"]),
                "name": definition?["name"],
                "riskTier": payload["riskTier"],
                "affectedTargetKeys": payload["affectedTargetKeys"],
                "faultSummaries": disclosure?["faultSummaries"],
                "cleanupSummary": disclosure?["cleanupSummary"],
                "warnings": payload["warnings"]
            ])
        case "get_test_observations":
            return compactValues([
                "scenarioID": scenarioID(from: payload["scenarioID"]),
                "phase": payload["phase"],
                "evidenceCount": (payload["evidence"] as? [Any])?.count,
                "warnings": payload["warnings"]
            ])
        case "evaluate_test_assertions":
            let assertionResults = payload["assertionResults"] as? [[String: Any]] ?? []
            return compactValues([
                "scenarioID": scenarioID(from: payload["scenarioID"]),
                "resolvedOutcome": payload["resolvedOutcome"],
                "evidenceCount": (payload["evidence"] as? [Any])?.count,
                "assertionCount": assertionResults.count,
                "assertionOutcomes": assertionOutcomeCounts(assertionResults),
                "warnings": payload["warnings"]
            ])
        case "get_test_report":
            let assertionResults = payload["assertionResults"] as? [[String: Any]] ?? []
            return compactValues([
                "scenarioID": payload["scenarioID"],
                "scenarioName": payload["scenarioName"],
                "phase": payload["phase"],
                "riskTier": payload["riskTier"],
                "evidenceCount": payload["evidenceCount"],
                "assertionCount": assertionResults.count,
                "assertionOutcomes": assertionOutcomeCounts(assertionResults),
                "cleanupResult": payload["cleanupResult"],
                "redactionSummary": payload["redactionSummary"],
                "warnings": payload["warnings"]
            ])
        default:
            let keys = [
                "scenarioID", "name", "phase", "riskTier", "armedAt", "activatedAt",
                "cleanupCompletedAt", "evidenceCount", "assertionResultCount", "hasReport",
                "lastError"
            ]
            return compactValues(Dictionary(uniqueKeysWithValues: keys.map { ($0, payload[$0]) }))
        }
    }

    private static func scenarioID(from value: Any?) -> Any? {
        if let raw = value as? String { return raw }
        return (value as? [String: Any])?["rawValue"]
    }

    private static func assertionOutcomeCounts(_ results: [[String: Any]]) -> [String: Int] {
        var counts = ["passed": 0, "failed": 0, "inconclusive": 0]
        for result in results {
            guard let outcome = result["outcome"] as? String else { continue }
            counts[outcome, default: 0] += 1
        }
        return counts
    }

    private static func compactValues(_ values: [String: Any?]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: values.compactMap { entry in
            guard let value = entry.value else { return nil }
            return (entry.key, value)
        })
    }
}

enum CLILiveRewriteArguments {
    static func preview(invocation: CLIInvocation, sessionID: String) throws -> [String: Any] {
        var arguments = try candidate(invocation: invocation)
        arguments["sessionIDs"] = [sessionID]
        return arguments
    }

    static func proposal(invocation: CLIInvocation, previewDigest: String) throws -> [String: Any] {
        var arguments = try candidate(invocation: invocation)
        arguments["previewDigest"] = previewDigest
        if let label = invocation.options["label"] { arguments["label"] = label }
        if let key = invocation.options["idempotency-key"] { arguments["idempotencyKey"] = key }
        return arguments
    }

    static func apply(proposalToken: String, invocation: CLIInvocation) -> [String: Any] {
        var arguments: [String: Any] = ["proposalToken": proposalToken]
        if let key = invocation.options["idempotency-key"] { arguments["idempotencyKey"] = key }
        return arguments
    }

    private static func candidate(invocation: CLIInvocation) throws -> [String: Any] {
        let method = try requiredOption("method", invocation: invocation).uppercased()
        let host = try requiredOption("host", invocation: invocation)
        let path = try requiredOption("path", invocation: invocation)
        let jsonPath = try requiredOption("json-path", invocation: invocation)
        let operation = invocation.options["operation"] ?? "set"
        let allowedOperations = [
            "set", "insert", "insertArrayElement", "appendString", "prependString",
            "removeProperty", "removeIndex", "move"
        ]
        guard allowedOperations.contains(operation) else {
            throw CLIError.invalidArguments("--operation must be one of: \(allowedOperations.joined(separator: ", ")).")
        }

        var arguments: [String: Any] = [
            "method": method,
            "host": host,
            "path": path,
            "matchMode": invocation.options["match-mode"] ?? "exactPath",
            "jsonPath": jsonPath,
            "operation": operation,
            "repeatPolicy": invocation.options["repeat-policy"]
                ?? (["appendString", "prependString"].contains(operation) ? "ifMissingSuffix" : "always")
        ]
        if let scheme = invocation.options["scheme"] { arguments["scheme"] = scheme }
        if let portText = invocation.options["port"] {
            guard let port = Int(portText), (1 ... 65_535).contains(port) else {
                throw CLIError.invalidArguments("--port must be between 1 and 65535.")
            }
            arguments["port"] = port
        }
        if operation != "removeProperty", operation != "removeIndex" {
            arguments["overrideValue"] = try overrideValue(invocation: invocation)
        }
        if let opName = invocation.options["graphql-operation-name"] {
            arguments["graphqlOperationName"] = opName
        }
        if let queryKey = invocation.options["match-query-key"] {
            arguments["matchQueryKey"] = queryKey
        }
        if let queryValue = invocation.options["match-query-value"] {
            arguments["matchQueryValue"] = queryValue
        }
        if let sourceClientAddress = invocation.options["source-client-address"] {
            arguments["sourceClientAddress"] = sourceClientAddress
        }
        return arguments
    }

    private static func overrideValue(invocation: CLIInvocation) throws -> [String: Any] {
        let type = invocation.options["value-type"] ?? "string"
        switch type {
        case "string":
            return ["type": type, "value": try requiredOption("value", invocation: invocation)]
        case "number":
            let value = try requiredOption("value", invocation: invocation)
            guard Double(value) != nil else {
                throw CLIError.invalidArguments("--value must be numeric when --value-type is number.")
            }
            return ["type": type, "value": value]
        case "bool":
            let value = try requiredOption("value", invocation: invocation).lowercased()
            guard value == "true" || value == "false" else {
                throw CLIError.invalidArguments("--value must be true or false when --value-type is bool.")
            }
            return ["type": type, "value": value == "true"]
        case "null":
            guard invocation.options["value"] == nil else {
                throw CLIError.invalidArguments("--value must be omitted when --value-type is null.")
            }
            return ["type": type]
        default:
            throw CLIError.invalidArguments("--value-type must be string, number, bool, or null.")
        }
    }

    private static func requiredOption(_ name: String, invocation: CLIInvocation) throws -> String {
        guard let value = invocation.options[name], !value.isEmpty else {
            throw CLIError.invalidArguments("rewrite requires --\(name) <value>.")
        }
        return value
    }
}

enum CLICollectionMockArguments {
    static func preview(invocation: CLIInvocation, sessionID: String) throws -> [String: Any] {
        [
            "sessionID": sessionID,
            "draftJSON": try draftJSONText(invocation: invocation)
        ]
    }

    static func proposal(invocation: CLIInvocation, revisionID: String) throws -> [String: Any] {
        let method = try requiredOption("method", invocation: invocation).uppercased()
        let host = try requiredOption("host", invocation: invocation)
        let path = try requiredOption("path", invocation: invocation)
        var arguments: [String: Any] = [
            "method": method,
            "host": host,
            "path": path,
            "matchMode": invocation.options["match-mode"] ?? "exactPath",
            "revisionID": revisionID
        ]
        if let scheme = invocation.options["scheme"] { arguments["scheme"] = scheme }
        if let portText = invocation.options["port"] {
            guard let port = Int(portText), (1 ... 65_535).contains(port) else {
                throw CLIError.invalidArguments("--port must be between 1 and 65535.")
            }
            arguments["port"] = port
        }
        if let label = invocation.options["label"] { arguments["label"] = label }
        if let key = invocation.options["idempotency-key"] { arguments["idempotencyKey"] = key }
        if let opName = invocation.options["graphql-operation-name"] { arguments["graphqlOperationName"] = opName }
        if let queryKey = invocation.options["match-query-key"] { arguments["matchQueryKey"] = queryKey }
        if let queryValue = invocation.options["match-query-value"] { arguments["matchQueryValue"] = queryValue }
        return arguments
    }

    static func apply(proposalToken: String, invocation: CLIInvocation) -> [String: Any] {
        var arguments: [String: Any] = ["proposalToken": proposalToken]
        if let key = invocation.options["idempotency-key"] { arguments["idempotencyKey"] = key }
        return arguments
    }

    /// Builds the `CollectionMockDraft`-shaped JSON text `preview_collection_mock` decodes.
    /// `--item-json` carries the item as raw JSON text (an object, not a scalar wrapper) since a
    /// collection item is typically `{"id": "...", ...}`, unlike a live-rewrite override literal.
    private static func draftJSONText(invocation: CLIInvocation) throws -> String {
        let collectionPointer = try requiredOption("collection-pointer", invocation: invocation)
        let itemText = try requiredOption("item-json", invocation: invocation)
        guard let itemData = itemText.data(using: .utf8),
              let item = try? JSONSerialization.jsonObject(with: itemData, options: [.fragmentsAllowed]) else {
            throw CLIError.invalidArguments("--item-json must be valid JSON.")
        }
        let identityPointers = (invocation.options["identity-pointers"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let countPointers = (invocation.options["count-pointers"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let position = invocation.options["position"] ?? "append"
        guard ["append", "prepend"].contains(position) else {
            throw CLIError.invalidArguments("--position must be append or prepend.")
        }
        var draft: [String: Any] = [
            "collectionPointer": collectionPointer,
            "item": item,
            "identityPointers": identityPointers,
            "countPointers": countPointers,
            "position": position
        ]
        draft["edits"] = []
        guard JSONSerialization.isValidJSONObject(draft),
              let data = try? JSONSerialization.data(withJSONObject: draft),
              let text = String(data: data, encoding: .utf8) else {
            throw CLIError.invalidArguments("Failed to encode the collection-mock draft as JSON.")
        }
        return text
    }

    private static func requiredOption(_ name: String, invocation: CLIInvocation) throws -> String {
        guard let value = invocation.options[name], !value.isEmpty else {
            throw CLIError.invalidArguments("collection-mock requires --\(name) <value>.")
        }
        return value
    }
}

enum CLIError: Error {
    case documentation(reason: String, recovery: String)
    case invalidPreparation(message: String, details: [String: String])
    case invalidArguments(String)
    case serverUnavailable(String)
    case authenticationFailed(String)
    case approvalRequired(requestID: String?, message: String)
    case policyDenied(String)
    case rateLimited(String)
    case timedOut(String)
    case staleSession(String)
    /// A proposal, preview, or revision reference is stale, consumed, or no longer exists — a
    /// different failure class from `.staleSession` (the logical MCP session/transport itself
    /// expiring). Conflating the two under one CLIError case previously gave "retry with a fresh
    /// MCP session" as advice for a failure a fresh session can never fix (e.g. a consumed preview
    /// digest, or a rule that was deleted between propose and apply) — see
    /// `Live-NOBLENDER-Audit-2026-08-05.md` G6-03.
    case staleProposal(String)
    case malformedResponse(String)
    case internalFailure(String)

    var exitCode: CLIExitCode {
        switch self {
        case .invalidArguments, .invalidPreparation, .documentation: return .invalidArguments
        case .serverUnavailable: return .serverUnavailable
        case .authenticationFailed: return .authenticationFailed
        case .approvalRequired: return .approvalRequired
        case .policyDenied: return .policyDenied
        case .rateLimited: return .rateLimited
        case .timedOut: return .timedOut
        case .staleSession: return .staleSession
        case .staleProposal: return .staleProposal
        case .malformedResponse, .internalFailure: return .internalFailure
        }
    }

    var message: String {
        switch self {
        case .documentation(let reason, let recovery):
            return "\(reason): \(recovery)"
        case .invalidArguments(let message), .serverUnavailable(let message),
             .authenticationFailed(let message), .policyDenied(let message),
             .rateLimited(let message),
             .timedOut(let message), .staleSession(let message),
             .staleProposal(let message),
             .malformedResponse(let message), .internalFailure(let message):
            return message
        case .approvalRequired(_, let message):
            return message
        case .invalidPreparation(let message, _):
            return message
        }
    }
}

struct CLIResultEnvelope {
    static let schemaVersion = 1

    var command: String
    var success: Bool
    var result: Any?
    var warnings: [String]
    var errorCode: String?
    var errorMessage: String?

    func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "schemaVersion": Self.schemaVersion,
            "command": command,
            "success": success,
            "warnings": warnings
        ]
        if let result { object["result"] = result }
        if let errorCode { object["errorCode"] = errorCode }
        if let errorMessage { object["errorMessage"] = errorMessage }
        return object
    }
}

enum CLIJSON {
    static func data(_ object: Any, pretty: Bool) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CLIError.internalFailure("The command result could not be encoded as JSON.")
        }
        var options: JSONSerialization.WritingOptions = [.sortedKeys]
        if pretty { options.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: object, options: options)
    }

    static func string(_ object: Any, pretty: Bool) throws -> String {
        guard let value = String(data: try data(object, pretty: pretty), encoding: .utf8) else {
            throw CLIError.internalFailure("The command result was not valid UTF-8.")
        }
        return value
    }
}
