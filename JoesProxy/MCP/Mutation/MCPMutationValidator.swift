import Foundation

enum MCPMutationValidationError: Error, Equatable, Sendable {
    case malformedRequest(String)
    case policyDenied(String)
    case busy
}

/// Validates MCP mutation matchers and family-specific arguments at propose time.
enum MCPMutationValidator {
    private static let blockStatusCodeRange = 400 ... 599
    private static let maxInlineBodyBytes = MCPResourceBudget.maxDisclosedItemBytes
    /// Dedicated outbound request-target byte limit — deliberately NOT `MCPResourceBudget`'s
    /// disclosure-size constants, which bound what's shown *to* a client, an unrelated policy
    /// domain from what's sent *out* on the wire to an upstream server.
    private static let maxMapRemoteRequestTargetBytes = 2048

    /// Parses and validates a request matcher from tool arguments.
    static func parseMatcher(from arguments: [String: Any]) throws -> MCPMutationMatcher {
        guard let method = trimmedString(arguments["method"]), !method.isEmpty else {
            throw MCPMutationValidationError.malformedRequest("method is required.")
        }
        let schemeRaw = trimmedString(arguments["scheme"]) ?? SessionScheme.https.rawValue
        guard let scheme = SessionScheme(rawValue: schemeRaw.lowercased()) else {
            throw MCPMutationValidationError.malformedRequest("scheme must be http or https.")
        }
        guard let host = trimmedString(arguments["host"]), !host.isEmpty else {
            throw MCPMutationValidationError.malformedRequest("host is required.")
        }
        let normalizedHost = host.lowercased()
        if normalizedHost == "*" || normalizedHost.hasPrefix("*.") && normalizedHost.count <= 2 {
            throw MCPMutationValidationError.policyDenied("Host matcher is too broad.")
        }
        let path = trimmedString(arguments["path"]) ?? "/"
        let matchModeRaw = trimmedString(arguments["matchMode"]) ?? ResponseOverrideMatchMode.exactPath.rawValue
        guard let matchMode = ResponseOverrideMatchMode(rawValue: matchModeRaw) else {
            throw MCPMutationValidationError.malformedRequest("Unknown matchMode.")
        }
        if matchMode == .pathPrefix {
            let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if trimmedPath.isEmpty || trimmedPath == "*" {
                throw MCPMutationValidationError.malformedRequest("pathPrefix cannot match '/' or '*' alone.")
            }
        }
        let port = arguments["port"] as? Int
        let graphQLOperationName = trimmedString(arguments["graphqlOperationName"])
        let (matchQueryKey, matchQueryValue) = try parseQueryPredicate(from: arguments)
        let sourceClientAddress = try parseSourceClientAddress(from: arguments)
        return MCPMutationMatcher(
            method: method.uppercased(),
            scheme: scheme,
            host: normalizedHost,
            port: port,
            path: path,
            matchMode: matchMode,
            graphQLOperationName: graphQLOperationName,
            matchQueryKey: matchQueryKey,
            matchQueryValue: matchQueryValue,
            sourceClientAddress: sourceClientAddress
        )
    }

    static func parseSourceClientAddress(from arguments: [String: Any]) throws -> String? {
        let sourceClientAddress = trimmedString(arguments["sourceClientAddress"])
        if let sourceClientAddress, sourceClientAddress.utf8.count > 64 {
            throw MCPMutationValidationError.malformedRequest("sourceClientAddress must not exceed 64 UTF-8 bytes.")
        }
        return sourceClientAddress
    }

    /// `matchQueryKey`/`matchQueryValue` must be supplied together or not at all — one without the
    /// other is a caller mistake, not a valid partial predicate (there is no "any value for this
    /// key" or "this value on any key" mode).
    static func parseQueryPredicate(from arguments: [String: Any]) throws -> (key: String?, value: String?) {
        let key = trimmedString(arguments["matchQueryKey"])
        let value = trimmedString(arguments["matchQueryValue"])
        switch (key, value) {
        case (nil, nil):
            return (nil, nil)
        case (.some(let key), .some(let value)):
            guard !key.isEmpty else {
                throw MCPMutationValidationError.malformedRequest("matchQueryKey cannot be empty.")
            }
            return (key, value)
        default:
            throw MCPMutationValidationError.malformedRequest("matchQueryKey and matchQueryValue must be supplied together.")
        }
    }

    static func validateBlockStatusCode(_ statusCode: Int) throws {
        guard blockStatusCodeRange.contains(statusCode) else {
            throw MCPMutationValidationError.malformedRequest("Block status code must be between 400 and 599.")
        }
    }

    static func validateMapRemoteDestination(
        host: String,
        port: Int?,
        scheme: SessionScheme,
        allowLoopbackDestination: Bool = false,
        policy: LoopbackDestinationPolicy = .disabled,
        reservedRegistry: ReservedListenerRegistry = .shared
    ) throws {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPMutationValidationError.malformedRequest("remoteHost is required.")
        }
        let defaultPort = (scheme == .https) ? 443 : 80
        let resolvedPort = port ?? defaultPort
        guard (1 ... 65_535).contains(resolvedPort) else {
            throw MCPMutationValidationError.malformedRequest("remotePort must be between 1 and 65535.")
        }
        do {
            _ = try LoopbackAddressInspector.validateStaticDestination(
                host: trimmed,
                port: resolvedPort,
                scheme: scheme,
                allowLoopbackDestination: allowLoopbackDestination,
                policy: policy,
                reservedRegistry: reservedRegistry
            )
        } catch MapRemoteValidationError.malformedRequest(let message) {
            throw MCPMutationValidationError.malformedRequest(message)
        } catch MapRemoteValidationError.policyDenied(_, let message) {
            throw MCPMutationValidationError.policyDenied(message)
        }
    }

    /// Validates a Map Remote destination-path override as an HTTP origin-form request-target —
    /// NOT a filesystem path. Rejecting `..` segments (a filesystem-traversal concern) is not the
    /// relevant boundary here; the real risks are request-line/header injection via control
    /// characters, smuggling a scheme/authority into what should be a bare path, and malformed
    /// percent-encoding reaching the wire unchecked.
    static func validateMapRemoteRequestTarget(_ path: String) throws {
        guard path.hasPrefix("/") else {
            throw MCPMutationValidationError.malformedRequest("remotePath must be an origin-form request-target starting with '/'.")
        }
        guard !path.contains("://") else {
            throw MCPMutationValidationError.malformedRequest("remotePath must not include a scheme or authority.")
        }
        guard !path.contains("@") else {
            throw MCPMutationValidationError.malformedRequest("remotePath must not include userinfo.")
        }
        guard !path.contains("#") else {
            throw MCPMutationValidationError.malformedRequest("remotePath must not include a fragment.")
        }
        guard path.utf8.count <= maxMapRemoteRequestTargetBytes else {
            throw MCPMutationValidationError.malformedRequest("remotePath exceeds the \(maxMapRemoteRequestTargetBytes)-byte request-target limit.")
        }
        try validateNoControlCharactersOrMalformedPercentEncoding(path, fieldName: "remotePath")
    }

    /// Validates a Map Remote replacement query string (used only with `remoteQueryPolicy ==
    /// .replace`). Same request-line-injection and percent-encoding concerns as the path itself;
    /// callers pass the query without a leading `?`.
    static func validateMapRemoteQuery(_ query: String) throws {
        guard !query.contains("#") else {
            throw MCPMutationValidationError.malformedRequest("remoteQuery must not include a fragment.")
        }
        guard query.utf8.count <= maxMapRemoteRequestTargetBytes else {
            throw MCPMutationValidationError.malformedRequest("remoteQuery exceeds the \(maxMapRemoteRequestTargetBytes)-byte limit.")
        }
        try validateNoControlCharactersOrMalformedPercentEncoding(query, fieldName: "remoteQuery")
    }

    private static func validateNoControlCharactersOrMalformedPercentEncoding(_ value: String, fieldName: String) throws {
        let scalars = Array(value.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value < 0x20 || scalar.value == 0x7f {
                throw MCPMutationValidationError.malformedRequest("\(fieldName) must not contain control characters.")
            }
            if scalar == "%" {
                guard index + 2 < scalars.count,
                      isHexDigit(scalars[index + 1]),
                      isHexDigit(scalars[index + 2]) else {
                    throw MCPMutationValidationError.malformedRequest("\(fieldName) contains malformed percent-encoding.")
                }
                index += 3
            } else {
                index += 1
            }
        }
    }

    private static func isHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x46, 0x61...0x66:
            return true
        default:
            return false
        }
    }

    static func validateInlineBody(_ bodyText: String) throws {
        let byteCount = bodyText.utf8.count
        guard byteCount <= maxInlineBodyBytes else {
            throw MCPMutationValidationError.policyDenied("Inline body exceeds the approved byte budget.")
        }
    }

    /// Validates a restricted dot/bracket JSON locator string (NOT full JSONPath — no wildcards,
    /// filters, quoted keys, recursive descent, or escaped property names). Delegates the actual
    /// bracket/index syntax check to `BookmarkJSONRewriteEngine.validateLocatorSyntax(_:)` — the
    /// exact same parser `apply`/`value(at:in:)` use to execute a locator — so this validator can
    /// never accept something the engine would reject, or vice versa (a confirmed drift risk when
    /// this function had its own independent string checks).
    static func validateJSONPath(_ jsonPath: String) throws {
        let trimmed = jsonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPMutationValidationError.malformedRequest("jsonPath is required.")
        }
        guard trimmed.hasPrefix("$") || trimmed.hasPrefix(".") else {
            throw MCPMutationValidationError.malformedRequest("jsonPath must start with '$' or '.'.")
        }
        if trimmed.contains("..") {
            throw MCPMutationValidationError.malformedRequest("jsonPath cannot contain empty path segments.")
        }
        do {
            try BookmarkJSONRewriteEngine.validateLocatorSyntax(trimmed)
        } catch {
            throw MCPMutationValidationError.malformedRequest("jsonPath is not a valid locator: \(error.localizedDescription)")
        }
    }

    /// `insertArrayElement` is accepted as an MCP-facing alias for `.insert` — there is no
    /// separate internal case (see `JSONMutationOperation.insert`'s doc comment), so this is the
    /// one place the alias gets translated before the neutral model ever sees it.
    static func parseRewriteOperation(from arguments: [String: Any]) throws -> JSONMutationOperation {
        guard let raw = arguments["operation"] as? String else {
            return .set
        }
        if raw == "insertArrayElement" {
            return .insert
        }
        guard let operation = JSONMutationOperation(rawValue: raw) else {
            throw MCPMutationValidationError.malformedRequest(
                "operation must be one of: set, insert, insertArrayElement, appendString, prependString, "
                    + "removeProperty, removeIndex, move."
            )
        }
        return operation
    }

    /// Parses `repeatPolicy` — only meaningful for `.appendString`/`.prependString`; ignored (and
    /// not required) for every other operation.
    static func parseRewriteRepeatPolicy(from arguments: [String: Any]) throws -> JSONMutationRepeatPolicy {
        guard let raw = arguments["repeatPolicy"] as? String else {
            return .always
        }
        guard let policy = JSONMutationRepeatPolicy(rawValue: raw) else {
            throw MCPMutationValidationError.malformedRequest("repeatPolicy must be 'always' or 'ifMissingSuffix'.")
        }
        return policy
    }

    static func validateRewriteLocator(
        jsonPath: String,
        operation: JSONMutationOperation
    ) throws {
        try validateJSONPath(jsonPath)
        switch operation {
        case .insert:
            do {
                try BookmarkJSONRewriteEngine.validateInsertLocatorSyntax(jsonPath)
            } catch {
                throw MCPMutationValidationError.malformedRequest(
                    "insert jsonPath must end with an array index: \(error.localizedDescription)"
                )
            }
        case .removeIndex:
            do {
                try BookmarkJSONRewriteEngine.validateRemoveIndexLocatorSyntax(jsonPath)
            } catch {
                throw MCPMutationValidationError.malformedRequest(
                    "removeIndex jsonPath must end with an array index: \(error.localizedDescription)"
                )
            }
        case .move:
            do {
                try BookmarkJSONRewriteEngine.validateMoveLocatorSyntax(jsonPath)
            } catch {
                throw MCPMutationValidationError.malformedRequest(
                    "move jsonPath (the \"from\" position) must end with an array index: \(error.localizedDescription)"
                )
            }
        case .set, .appendString, .prependString, .removeProperty:
            break
        }
    }

    static func parseBookmarkJSONValue(from arguments: [String: Any]) throws -> BookmarkJSONValue {
        guard let valueObject = arguments["overrideValue"] as? [String: Any],
              let type = valueObject["type"] as? String else {
            throw MCPMutationValidationError.malformedRequest("overrideValue.type is required.")
        }
        switch type {
        case "string":
            guard let value = valueObject["value"] as? String else {
                throw MCPMutationValidationError.malformedRequest("overrideValue.value must be a string.")
            }
            return .string(value)
        case "number":
            if let value = valueObject["value"] as? String {
                return .number(value)
            }
            if let value = valueObject["value"] as? NSNumber {
                return .number(value.stringValue)
            }
            throw MCPMutationValidationError.malformedRequest("overrideValue.value must be a number.")
        case "bool":
            guard let value = valueObject["value"] as? Bool else {
                throw MCPMutationValidationError.malformedRequest("overrideValue.value must be a boolean.")
            }
            return .bool(value)
        case "null":
            return .null
        default:
            throw MCPMutationValidationError.malformedRequest("Unsupported overrideValue.type.")
        }
    }

    /// Parses `overrideValue` per the operation's contract: required for every operation except
    /// `removeProperty`/`removeIndex`, which take no literal and reject a stray one rather than
    /// silently ignoring it (a caller supplying `overrideValue` alongside one of these almost
    /// certainly misunderstands what the operation does). `move` requires `overrideValue`, but
    /// specifically as a whole-number "to" index rather than arbitrary content — malformed input
    /// is rejected here, at the wire boundary, rather than surfacing as an engine-level
    /// `.typeMismatch` outcome the caller has to interpret.
    static func parseRewriteOverrideValue(
        operation: JSONMutationOperation,
        from arguments: [String: Any]
    ) throws -> BookmarkJSONValue {
        switch operation {
        case .removeProperty, .removeIndex:
            guard arguments["overrideValue"] == nil else {
                throw MCPMutationValidationError.malformedRequest(
                    "overrideValue must not be supplied for \(operation.rawValue)."
                )
            }
            return .null
        case .move:
            let value = try parseBookmarkJSONValue(from: arguments)
            guard case .number(let raw) = value, Int(raw) != nil else {
                throw MCPMutationValidationError.malformedRequest(
                    "move overrideValue must be a whole number — the destination array index."
                )
            }
            return value
        case .set, .insert, .appendString, .prependString:
            return try parseBookmarkJSONValue(from: arguments)
        }
    }

    static func structuredError(for error: MCPMutationValidationError) -> MCPStructuredError {
        switch error {
        case .malformedRequest(let message):
            return MCPStructuredError(code: .malformedRequest, message: message)
        case .policyDenied(let message):
            return MCPStructuredError(code: .policyDenied, message: message)
        case .busy:
            return MCPStructuredError(code: .busy, message: "Target is locked by another mutation.")
        }
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
