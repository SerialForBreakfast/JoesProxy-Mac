import Foundation

struct CapturedMockPreflightSnapshot: Sendable {
    struct Observation: Sendable {
        let id: UUID
        let request: CapturedRequest
        let bodyAvailability: String
        var responseStatusCode: Int? = nil
    }
    let observations: [Observation]
    let retainedCount: Int
    let droppedCount: Int
    let metadataSkippedCount: Int
    let epoch: UInt64
    let observedAt: Date

    /// Copy bounded routing metadata only; never carry captured bodies or headers across actors.
    @MainActor
    static func capture(from store: any SessionStore) -> Self {
        var observations: [Observation] = []
        var bytes = 0
        var skipped = 0
        for record in store.sessions.suffix(1_000) {
            let request = record.request
            let cost = request.host.utf8.count + request.path.utf8.count + request.method.utf8.count
                + (request.clientAddress?.utf8.count ?? 0)
            guard cost <= 16_384, bytes + cost <= 1_048_576 else { skipped += 1; continue }
            bytes += cost
            let metadata = CapturedRequest(method: request.method, scheme: request.scheme,
                host: request.host, port: request.port, path: request.path, headers: [],
                bodyData: nil, bodySize: nil, clientAddress: request.clientAddress)
            let availability: String
            if let response = record.response {
                if response.bodyDeferred { availability = "deferred" }
                else if response.bodyTruncated { availability = "truncated" }
                else if response.recordingBodyOmissionReason != nil { availability = "omitted" }
                else if response.bodyData == nil { availability = "unavailable" }
                else { availability = "available" }
            } else { availability = "noResponse" }
            observations.append(.init(id: record.id, request: metadata, bodyAvailability: availability,
                responseStatusCode: record.response?.statusCode))
        }
        return .init(observations: observations, retainedCount: store.sessions.count,
            droppedCount: store.droppedSessionCount, metadataSkippedCount: skipped,
            epoch: store.liveCaptureEpoch.current, observedAt: Date())
    }
}

struct CapturedMockPreflight: Codable, Equatable, Sendable {
    struct Resource: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let assetIDs: [String]
        let matchedCount: Int
        let otherClientCount: Int
        let siblingMatchCount: Int
        let unavailableBodyCount: Int
        let sampleSessionIDs: [UUID]
        let reason: String
        let nextAction: String
        var redirectResponseCount: Int = 0
        var redirectSessionIDs: [UUID] = []
    }
    let revisionID: UUID
    let captureEpoch: UInt64
    let observedAt: Date
    let inspectedCount: Int
    let retainedCount: Int
    let droppedCount: Int
    let metadataSkippedCount: Int
    let resources: [Resource]
    let resourcesTruncated: Bool
    var incomplete: Bool {
        inspectedCount < retainedCount || droppedCount > 0 || resourcesTruncated
            || resources.contains { $0.reason == "requiresAdditionalEvidence" }
    }
    /// A bounded historical report can qualify coverage, but cannot turn missing evidence into a
    /// delivery, cache, or rendering conclusion.
    var coverageQualification: String {
        if droppedCount > 0 || metadataSkippedCount > 0 || resourcesTruncated {
            return "incompleteRetainedEvidence"
        }
        if resources.contains(where: { $0.reason == "requiresAdditionalEvidence" }) {
            return "unsupportedMatcherEvidence"
        }
        if resources.contains(where: { $0.unavailableBodyCount > 0 }) {
            return "partialBodyEvidence"
        }
        return "boundedHistoricalEvidence"
    }
    var payload: [String: Any] {
        ["revisionID": revisionID.uuidString, "captureEpoch": String(captureEpoch),
         "observedAt": ISO8601DateFormatter().string(from: observedAt), "inspectedCount": inspectedCount,
         "retainedCount": retainedCount, "droppedCount": droppedCount,
         "metadataSkippedCount": metadataSkippedCount, "incomplete": incomplete,
         "coverageQualification": coverageQualification,
         "resourcesTruncated": resourcesTruncated,
         "resources": resources.map { resource -> [String: Any] in
             ["effectID": resource.id.uuidString, "assetIDs": resource.assetIDs,
              "matchedCount": resource.matchedCount, "otherClientCount": resource.otherClientCount,
              "siblingMatchCount": resource.siblingMatchCount, "unavailableBodyCount": resource.unavailableBodyCount,
              "sampleSessionIDs": resource.sampleSessionIDs.map(\.uuidString),
              "reason": resource.reason, "nextAction": resource.nextAction,
              "redirectResponseCount": resource.redirectResponseCount,
              "redirectSessionIDs": resource.redirectSessionIDs.map(\.uuidString)]
         }, "limitations": Self.limitations]
    }
    static let limitations = "Historical matcher check only, not delivery or rendering evidence. No request observed does not confirm caching. The latest 1,000 retained requests are inspected within a metadata budget; capture-admission gaps are not measured by this report. No rules, approvals or routing were changed."
}

extension ResponseOverrideStore {
    /// Runs on this actor, using the same configuration matcher as live routing, without state changes.
    func preflight(manifest: EffectBundleManifest, snapshot: CapturedMockPreflightSnapshot) throws -> CapturedMockPreflight {
        var resources: [CapturedMockPreflight.Resource] = []
        for effect in manifest.responseEffects.prefix(32) {
            try Task.checkCancellation()
            let unsupported = effect.graphQLOperationName != nil || effect.matchHeaderName != nil
            let rule = ResponseOverrideRule(id: effect.id, requestMethod: effect.requestMethod,
                requestScheme: effect.requestScheme, host: effect.host, port: effect.port, path: effect.path,
                matchMode: effect.matchMode, sourceKind: effect.sourceKind, sourceDescription: "Preflight",
                statusCode: effect.statusCode, headers: [], bodySource: .inline(Data()), isEnabled: false,
                matchQueryKey: effect.matchQueryKey, matchQueryValue: effect.matchQueryValue,
                sourceClientAddress: effect.sourceClientAddress, ignoredQueryNames: effect.ignoredQueryNames)
            var matched = 0, otherClients = 0, siblings = 0, unavailable = 0
            var samples: [UUID] = []
            var redirectCount = 0
            var redirects: [UUID] = []
            if !unsupported {
                for observation in snapshot.observations {
                    try Task.checkCancellation()
                    guard matchesConfiguration(rule: rule, request: observation.request, ignoringClientScope: true) else { continue }
                    guard matchesConfiguration(rule: rule, request: observation.request) else { otherClients += 1; continue }
                    matched += 1
                    if samples.count < 3 { samples.append(observation.id) }
                    if observation.request.path != effect.path { siblings += 1 }
                    if observation.bodyAvailability != "available" { unavailable += 1 }
                    if let status = observation.responseStatusCode, [301, 302, 303, 307, 308].contains(status) {
                        redirectCount += 1
                        if redirects.count < 3 { redirects.append(observation.id) }
                    }
                }
            }
            let reason: String
            let next: String
            if unsupported {
                reason = "requiresAdditionalEvidence"; next = "Review header/body predicates separately; this metadata-only check cannot evaluate them."
            } else if matched == 0, otherClients > 0 {
                reason = "clientScopeMismatch"; next = "Review the intended client against the captured source; do not broaden scope automatically."
            } else if matched == 0 {
                reason = "noRequestObserved"; next = "Verify routing and the exact image/reference or endpoint transformation, then request a target refresh explicitly."
            } else if siblings > 0 {
                reason = "additionalPathsMatched"; next = "Review query and sibling-path consequences before activating this revision."
            } else {
                reason = "historicalMatchesObserved"; next = "Review this revision and request activation separately; confirm subsequent delivery and target outcome."
            }
            resources.append(.init(id: effect.id, assetIDs: Array(effect.bodySource.assetIDs.prefix(16)),
                matchedCount: matched, otherClientCount: otherClients, siblingMatchCount: siblings,
                unavailableBodyCount: unavailable, sampleSessionIDs: samples, reason: reason, nextAction: next,
                redirectResponseCount: redirectCount, redirectSessionIDs: redirects))
        }
        return .init(revisionID: manifest.id, captureEpoch: snapshot.epoch, observedAt: snapshot.observedAt,
            inspectedCount: snapshot.observations.count, retainedCount: snapshot.retainedCount,
            droppedCount: snapshot.droppedCount, metadataSkippedCount: snapshot.metadataSkippedCount,
            resources: resources, resourcesTruncated: manifest.responseEffects.count > 32)
    }
}
