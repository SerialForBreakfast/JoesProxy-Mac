import Foundation

/// One path-template segment. Parameters match exactly one non-empty path component.
enum OpenAPIMockPathSegment: Equatable, Sendable, Hashable {
    case literal(String)
    case parameter(String)

    /// Whether this segment is a `{param}` placeholder.
    var isParameter: Bool {
        if case .parameter = self { return true }
        return false
    }
}

/// Segment-aware OpenAPI path template. v1 forbids wildcards and multi-segment parameters.
struct OpenAPIMockPathTemplate: Equatable, Sendable, Hashable {
    var rawValue: String
    var segments: [OpenAPIMockPathSegment]

    /// Count of non-parameter segments. Higher wins precedence.
    var literalSegmentCount: Int {
        segments.filter { !$0.isParameter }.count
    }

    /// Total segment count. Longer paths win after literal count.
    var segmentCount: Int { segments.count }

    /// Concrete path used to probe overlapping Map Local rules. Parameters become `jp`.
    var probePath: String {
        let body = segments.map { segment -> String in
            switch segment {
            case .literal(let value): return value
            case .parameter: return "jp"
            }
        }.joined(separator: "/")
        return body.isEmpty ? "/" : "/\(body)"
    }

    /// Parses a v1 template such as `/v1/catalog/items/{itemId}`.
    ///
    /// - Throws: ``OpenAPIMockPackError/invalidPathTemplate(_:)`` or
    ///   ``OpenAPIMockPackError/tooManyPathSegments(count:)``.
    static func parse(_ raw: String) throws -> OpenAPIMockPathTemplate {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), !trimmed.contains("*") else {
            throw OpenAPIMockPackError.invalidPathTemplate(raw)
        }
        let pathOnly = Self.stripQuery(trimmed)
        let rawSegments = pathOnly.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        try OpenAPIMockPackBudget.validatePathSegmentCount(rawSegments.count)

        var parsed: [OpenAPIMockPathSegment] = []
        parsed.reserveCapacity(rawSegments.count)
        for segment in rawSegments {
            parsed.append(try parseSegment(segment, template: raw))
        }
        return OpenAPIMockPathTemplate(rawValue: pathOnly, segments: parsed)
    }

    /// Returns true when `path` has the same arity and each segment matches.
    func matches(path: String) -> Bool {
        let requestSegments = Self.pathSegments(path)
        guard requestSegments.count == segments.count else { return false }
        for (expected, actual) in zip(segments, requestSegments) {
            switch expected {
            case .literal(let value):
                if value != actual { return false }
            case .parameter:
                if actual.isEmpty { return false }
            }
        }
        return true
    }

    /// Percent-decoded path components, query stripped.
    static func pathSegments(_ path: String) -> [String] {
        let pathOnly = stripQuery(path)
        return pathOnly.split(separator: "/", omittingEmptySubsequences: true).map { component in
            let raw = String(component)
            return raw.removingPercentEncoding ?? raw
        }
    }

    private static func stripQuery(_ path: String) -> String {
        String(path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(path))
    }

    private static func parseSegment(_ segment: String, template: String) throws -> OpenAPIMockPathSegment {
        if segment.hasPrefix("{") {
            guard segment.hasSuffix("}"), segment.count >= 3 else {
                throw OpenAPIMockPackError.invalidPathTemplate(template)
            }
            let name = String(segment.dropFirst().dropLast())
            guard !name.isEmpty, !name.contains("{"), !name.contains("}"), !name.contains("/") else {
                throw OpenAPIMockPackError.invalidPathTemplate(template)
            }
            return .parameter(name)
        }
        if segment.contains("{") || segment.contains("}") {
            throw OpenAPIMockPackError.invalidPathTemplate(template)
        }
        let decoded = segment.removingPercentEncoding ?? segment
        return .literal(decoded)
    }
}

extension OpenAPIMockPathTemplate: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = try OpenAPIMockPathTemplate.parse(try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Compiled query constraint. Unlisted request keys are ignored at match time.
struct OpenAPIMockQueryConstraint: Equatable, Sendable, Codable, Hashable {
    var name: String
    var isRequired: Bool
    /// When non-nil, the request value must be a member of this set.
    var allowedValues: [String]?
}

/// Normalized operation graph node. AW-2 fills this; AW-1 owns matching.
struct OpenAPIMockRoute: Equatable, Sendable, Codable, Identifiable {
    var id: String
    var origin: OpenAPIMockOrigin
    var method: String
    var pathTemplate: OpenAPIMockPathTemplate
    var queryConstraints: [OpenAPIMockQueryConstraint]
    var requestContentType: String?
    var variantIDs: [String]

    /// Uppercases the method so matching is case-insensitive at the stored value.
    init(
        id: String,
        origin: OpenAPIMockOrigin,
        method: String,
        pathTemplate: OpenAPIMockPathTemplate,
        queryConstraints: [OpenAPIMockQueryConstraint] = [],
        requestContentType: String? = nil,
        variantIDs: [String] = []
    ) {
        self.id = id
        self.origin = origin
        self.method = method.uppercased()
        self.pathTemplate = pathTemplate
        self.queryConstraints = queryConstraints
        self.requestContentType = requestContentType.map(OpenAPIMockRouteMatcher.contentTypeEssence)
        self.variantIDs = variantIDs
    }
}

/// Request snapshot for pure matching. Independent of `CapturedRequest` so tests stay local.
struct OpenAPIMockMatchRequest: Equatable, Sendable {
    /// Header a client may send to select a named compiled variant (`404` `not_found`).
    static let variantHeaderName = "X-JoesProxy-OpenAPI-Variant"

    var method: String
    var origin: OpenAPIMockOrigin
    var path: String
    var query: [String: String]
    var contentType: String?
    var requestedVariant: String? = nil

    /// Builds a match request from a captured proxy request. Query values are used for matching only.
    static func from(_ request: CapturedRequest) -> OpenAPIMockMatchRequest {
        let pathAndQuery = request.path
        let parts = pathAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts.first ?? Substring("/"))
        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&", omittingEmptySubsequences: true) {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = decodeQueryComponent(kv[0])
                let value = kv.count > 1 ? decodeQueryComponent(kv[1]) : ""
                if !key.isEmpty {
                    query[key] = value
                }
            }
        }
        let contentType = request.headers.first {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value
        let requestedVariant = request.headers.first {
            $0.name.caseInsensitiveCompare(variantHeaderName) == .orderedSame
        }?.value
        return OpenAPIMockMatchRequest(
            method: request.method,
            origin: OpenAPIMockOrigin(scheme: request.scheme, host: request.host, port: request.port),
            path: path,
            query: query,
            contentType: contentType,
            requestedVariant: requestedVariant
        )
    }

    private static func decodeQueryComponent(_ raw: Substring) -> String {
        let string = String(raw).replacingOccurrences(of: "+", with: " ")
        return string.removingPercentEncoding ?? string
    }
}

/// Fail-open intercept result. Missing fixtures become ``noMatch``, never a guessed 200.
enum OpenAPIMockInterceptDecision: Equatable, Sendable {
    case noMatch
    case serve(routeID: String, variantID: String)
}

/// Deterministic route matching and precedence for mock packs.
enum OpenAPIMockRouteMatcher {
    /// Whether `route` matches `request` under the AW-1 rules.
    static func matches(_ route: OpenAPIMockRoute, request: OpenAPIMockMatchRequest) -> Bool {
        guard route.origin == request.origin else { return false }
        guard route.method == request.method.uppercased() else { return false }
        guard route.pathTemplate.matches(path: request.path) else { return false }
        guard matchesQuery(route.queryConstraints, request.query) else { return false }
        return matchesContentType(route: route, request: request)
    }

    /// Returns the unique winning route, `nil` on no match, or throws on a remaining precedence tie.
    static func select(
        routes: [OpenAPIMockRoute],
        request: OpenAPIMockMatchRequest
    ) throws -> OpenAPIMockRoute? {
        let matched = routes.filter { matches($0, request: request) }
        guard !matched.isEmpty else { return nil }
        if matched.count == 1 { return matched[0] }

        let ranked = matched.sorted { lhs, rhs in
            let left = precedence(lhs)
            let right = precedence(rhs)
            if left != right { return left > right }
            return lhs.id < rhs.id
        }
        let winner = ranked[0]
        let runnerUp = ranked[1]
        if precedence(winner) == precedence(runnerUp) {
            throw OpenAPIMockPackError.remainingTieConflict
        }
        return winner
    }

    /// Fail-open: unmatched or fixture-less traffic does not intercept.
    static func interceptDecision(
        matchedRoute: OpenAPIMockRoute?,
        selectedVariant: OpenAPIMockResponseVariant?
    ) -> OpenAPIMockInterceptDecision {
        guard let matchedRoute, let selectedVariant else {
            return .noMatch
        }
        return .serve(routeID: matchedRoute.id, variantID: selectedVariant.id)
    }

    /// Media-type essence, lowercased, parameters stripped (`application/json; charset=utf-8` → `application/json`).
    static func contentTypeEssence(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let semicolon = trimmed.firstIndex(of: ";") else { return trimmed }
        return trimmed[..<semicolon].trimmingCharacters(in: .whitespaces)
    }

    private static func matchesQuery(
        _ constraints: [OpenAPIMockQueryConstraint],
        _ query: [String: String]
    ) -> Bool {
        for constraint in constraints {
            let value = query[constraint.name]
            if constraint.isRequired, value == nil { return false }
            if let value, let allowed = constraint.allowedValues, !allowed.contains(value) {
                return false
            }
        }
        return true
    }

    private static func matchesContentType(route: OpenAPIMockRoute, request: OpenAPIMockMatchRequest) -> Bool {
        if route.method == "GET" || route.method == "HEAD" { return true }
        guard let expected = route.requestContentType else { return true }
        guard let actual = request.contentType else { return false }
        return contentTypeEssence(actual) == expected
    }

    /// Tuple ordered so `>` prefers more literals, then longer paths, then more query constraints, then content-type.
    private static func precedence(_ route: OpenAPIMockRoute) -> (Int, Int, Int, Int) {
        (
            route.pathTemplate.literalSegmentCount,
            route.pathTemplate.segmentCount,
            route.queryConstraints.count,
            route.requestContentType == nil ? 0 : 1
        )
    }
}
