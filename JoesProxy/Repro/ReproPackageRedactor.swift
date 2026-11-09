import Foundation

struct ReproRedactionAccumulator {
    var headerValuesRedacted = 0
    var queryValuesRedacted = 0
    var bodiesOmitted = 0
    var privateAddressesRedacted = 0
    var localPathsRedacted = 0
    var freeformSecretsRedacted = 0

    var report: ReproRedactionReport {
        ReproRedactionReport(
            headerValuesRedacted: headerValuesRedacted,
            queryValuesRedacted: queryValuesRedacted,
            bodiesOmitted: bodiesOmitted,
            privateAddressesRedacted: privateAddressesRedacted,
            localPathsRedacted: localPathsRedacted,
            freeformSecretsRedacted: freeformSecretsRedacted
        )
    }
}

enum ReproPackageRedactor {
    static let placeholder = "<redacted>"

    static func sanitizeSession(
        _ session: SessionRecord,
        id: String? = nil,
        accumulator: inout ReproRedactionAccumulator
    ) -> ReproSession {
        let request = sanitizeRequest(session.request, accumulator: &accumulator)
        let response = session.response.map { sanitizeResponse($0, accumulator: &accumulator) }
        return ReproSession(
            id: id ?? session.id.uuidString,
            request: request,
            response: response,
            timing: ReproTiming(
                startedAt: session.timing.startedAt,
                duration: session.timing.duration,
                wireProfile: session.timing.wireProfile
            ),
            expectedOutcome: ReproExpectedOutcome(
                statusCode: session.response?.statusCode,
                failureBucket: session.failure?.bucket
            )
        )
    }

    static func sanitizeGraph(
        _ graph: HypothesisGraph,
        accumulator: inout ReproRedactionAccumulator
    ) -> ReproHypothesisGraph {
        ReproHypothesisGraph(
            id: graph.id,
            name: sanitizeFreeform(graph.name, accumulator: &accumulator),
            targetBugDescription: sanitizeFreeform(graph.targetBugDescription, accumulator: &accumulator),
            nodes: graph.nodes.map { node in
                ReproHypothesisNode(
                    id: node.id,
                    parentID: node.parentID,
                    title: sanitizeFreeform(node.title, accumulator: &accumulator),
                    explanation: sanitizeFreeform(node.explanation, accumulator: &accumulator),
                    mutationKind: mutationKind(node.mutation),
                    expectedOutcome: sanitizeFreeform(node.expectedOutcome.description, accumulator: &accumulator),
                    status: node.status.rawValue,
                    evidenceSummary: node.evidenceSummary.map {
                        sanitizeFreeform($0, accumulator: &accumulator)
                    }
                )
            },
            currentNodeID: graph.currentNodeID,
            isolatedRootCauseNodeID: graph.isolatedRootCauseNodeID
        )
    }

    static func sanitizeFreeform(
        _ value: String,
        accumulator: inout ReproRedactionAccumulator
    ) -> String {
        var result = value
        result = replacing(
            pattern: #"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#,
            in: result,
            with: "Bearer \(placeholder)",
            counter: &accumulator.freeformSecretsRedacted
        )
        result = replacing(
            pattern: #"(?i)\b(password|token|secret|api[_-]?key)\s*[:=]\s*[^\s,;&]+"#,
            in: result,
            with: "$1=\(placeholder)",
            counter: &accumulator.freeformSecretsRedacted
        )
        result = replacing(
            pattern: #"(?:file://)?/Users/[^\s\"']+"#,
            in: result,
            with: "<local-path>",
            counter: &accumulator.localPathsRedacted
        )
        result = replacingPrivateIPv4(in: result, accumulator: &accumulator)
        return result
    }

    static func isPrivateAddress(_ value: String) -> Bool {
        let host = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") {
            return true
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        return octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || octets[0] == 127
            || (octets[0] == 169 && octets[1] == 254)
    }

    private static func sanitizeRequest(
        _ request: CapturedRequest,
        accumulator: inout ReproRedactionAccumulator
    ) -> ReproRequest {
        let sanitizedHost: String
        if isPrivateAddress(request.host) {
            accumulator.privateAddressesRedacted += 1
            sanitizedHost = "private-host.invalid"
        } else {
            sanitizedHost = request.host
        }
        let path = sanitizePath(request.path, accumulator: &accumulator)
        return ReproRequest(
            method: request.method,
            scheme: request.scheme,
            host: sanitizedHost,
            port: request.port,
            path: path,
            headers: sanitizeHeaders(request.headers, accumulator: &accumulator),
            originalBodyByteCount: request.bodySize ?? request.bodyData?.count,
            bodyOmittedForPrivacy: omitBodyIfPresent(request.bodySize ?? request.bodyData?.count, accumulator: &accumulator)
        )
    }

    private static func sanitizeResponse(
        _ response: CapturedResponse,
        accumulator: inout ReproRedactionAccumulator
    ) -> ReproResponse {
        ReproResponse(
            statusCode: response.statusCode,
            headers: sanitizeHeaders(response.headers, accumulator: &accumulator),
            originalBodyByteCount: response.bodySize ?? response.bodyData?.count,
            bodyOmittedForPrivacy: omitBodyIfPresent(response.bodySize ?? response.bodyData?.count, accumulator: &accumulator)
        )
    }

    private static func sanitizeHeaders(
        _ headers: [HTTPHeaderField],
        accumulator: inout ReproRedactionAccumulator
    ) -> [HTTPHeaderField] {
        headers.map { header in
            if SensitiveDataRedaction.isSensitiveHeaderName(header.name) {
                accumulator.headerValuesRedacted += 1
                return HTTPHeaderField(name: header.name, value: placeholder)
            }
            return HTTPHeaderField(
                name: header.name,
                value: sanitizeFreeform(header.value, accumulator: &accumulator)
            )
        }
    }

    private static func sanitizePath(
        _ path: String,
        accumulator: inout ReproRedactionAccumulator
    ) -> String {
        guard var components = URLComponents(string: path),
              let items = components.queryItems,
              !items.isEmpty else {
            return sanitizeFreeform(path, accumulator: &accumulator)
        }
        accumulator.queryValuesRedacted += items.count
        components.queryItems = items.map { URLQueryItem(name: $0.name, value: placeholder) }
        return sanitizeFreeform(components.string ?? path, accumulator: &accumulator)
    }

    private static func omitBodyIfPresent(
        _ byteCount: Int?,
        accumulator: inout ReproRedactionAccumulator
    ) -> Bool {
        guard let byteCount, byteCount > 0 else { return false }
        accumulator.bodiesOmitted += 1
        return true
    }

    private static func mutationKind(_ mutation: EphemeralMicroMutation) -> String {
        switch mutation {
        case .jsonRewrite: return "jsonRewrite"
        case .statusCodeFault: return "statusCodeFault"
        case .latencyInjection: return "latencyInjection"
        case .headerMutation: return "headerMutation"
        case .dropConnection: return "dropConnection"
        }
    }

    private static func replacing(
        pattern: String,
        in value: String,
        with template: String,
        counter: inout Int
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = regex.numberOfMatches(in: value, range: range)
        guard matches > 0 else { return value }
        counter += matches
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }

    private static func replacingPrivateIPv4(
        in value: String,
        accumulator: inout ReproRedactionAccumulator
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#) else {
            return value
        }
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value))
        var result = value
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let candidate = String(result[range])
            guard isPrivateAddress(candidate) else { continue }
            result.replaceSubrange(range, with: "<private-address>")
            accumulator.privateAddressesRedacted += 1
        }
        return result
    }
}

