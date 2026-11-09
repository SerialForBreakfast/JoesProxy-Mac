import Foundation

struct DiagnosticExperimentWindow: Codable, Equatable, Identifiable, Sendable {
    enum Mode: String, Codable, Sendable { case baseline, modified }
    struct Resource: Codable, Equatable, Sendable {
        struct TextTrack: Codable, Equatable, Sendable {
            let identity: HLSWebVTTFixture.TrackIdentity
            var observed = 0
            var delivered = 0
            var failed = 0
            var pending = 0
        }
        let id: UUID
        var observed = 0
        var completed = 0
        var statusFamilies: [String: Int] = [:]
        var latencySamples = 0
        var latencyTotalMilliseconds: Double = 0
        var minimumMilliseconds: Double?
        var maximumMilliseconds: Double?
        var delivered = 0
        var deliveryFailed = 0
        var deliveryPending = 0
        var outcomes: [String: Int] = [:]
        var textTracks: [TextTrack]?
    }
    let id: UUID
    let runID: DiagnosticRunID
    let ownerID: String
    let bundleID: UUID
    let revisionID: UUID
    let scopeDigest: String
    let mode: Mode
    let activationID: UUID?
    let beganAt: Date
    var endedAt: Date?
    var resources: [Resource]
    var qualifications: [String] = []
    var phaseIDs: [UUID] = []
    var intendedChanges: [String] = []
    var evidenceStartMarker: UInt64 = 0
    var evidenceTimelineID: UUID?
    var targetOutcome = "unknown"
    var targetOutcomeSource: String?
}

struct EffectBundleComparison: Codable, Sendable {
    struct Difference: Codable, Sendable {
        let resourceID: UUID
        let baseline: DiagnosticExperimentWindow.Resource
        let modified: DiagnosticExperimentWindow.Resource
        let observedCountDelta: Int
    }
    let baseline: DiagnosticExperimentWindow
    let modified: DiagnosticExperimentWindow
    let resources: [Difference]
    let cleanupState: String
    let qualification = "Counts describe explicit windows, not causality. Missing requests were not observed; caching is unknown. Timing samples describe proxy completion, not playback. Delivery is downstream write completion, not target acceptance."
    let intendedChanges: [String]
    let recoveryActions = ["inspectReviewedScopeAndClient", "repeatExplicitWindowIfIncomplete",
                           "requestExternalTargetConfirmation", "stopOwnedBundleAndVerifyCleanup"]
}

/// Synchronous bounded admission; no tasks, bodies, headers, file reads or persistence on this path.
/// The lock owns windows and at most 256 pending request tickets across all windows.
final class DiagnosticExperimentWindowIndex: @unchecked Sendable {
    static let shared = DiagnosticExperimentWindowIndex()
    private struct Active {
        var window: DiagnosticExperimentWindow
        let rules: [ResponseOverrideRule]
        let media: [EffectBundleHLSSubstitution]
        var admittedSessionIDs: Set<UUID> = []
        var admittedSessionOrder: [UUID] = []
    }
    private struct Ticket {
        let windowID: UUID
        let resources: Set<UUID>
        let startedAt: Date
        var sessionID: UUID?
    }
    private let lock = NSLock()
    private let matcher = ResponseOverrideStore()
    private var active: [UUID: Active] = [:]
    private var tickets: [UUID: Ticket] = [:]

    @discardableResult
    func begin(_ window: DiagnosticExperimentWindow, manifest: EffectBundleManifest) throws -> DiagnosticExperimentWindow {
        let rules = manifest.responseEffects.map { effect in
            ResponseOverrideRule(id: effect.id, requestMethod: effect.requestMethod,
                requestScheme: effect.requestScheme, host: effect.host, port: effect.port, path: effect.path,
                matchMode: effect.matchMode, sourceKind: effect.sourceKind, sourceDescription: "Observation window",
                statusCode: effect.statusCode, headers: [], bodySource: .inline(Data()), isEnabled: false,
                matchQueryKey: effect.matchQueryKey, matchQueryValue: effect.matchQueryValue,
                sourceClientAddress: effect.sourceClientAddress, ignoredQueryNames: effect.ignoredQueryNames)
        }
        return try lock.withLock {
            guard active.count < 2, !active.values.contains(where: { $0.window.bundleID == window.bundleID && $0.window.endedAt == nil }) else {
                throw EffectBundleError.activationConflict
            }
            var value = window
            let changes = (manifest.authoring?.reviewedChanges ?? []) + manifest.responseEffects.compactMap { effect in
                effect.collectionMockPlan.map { "Intended \($0.position.rawValue) at \($0.collectionPointer.prefix(128)); count fields: \($0.countPointers.prefix(8).map { String($0.prefix(128)) }.joined(separator: ", "))." }
            } + (manifest.authoring?.relatedResponses ?? []).flatMap { response in
                response.changedPointers.map { "Intended edit at \($0.prefix(128)); body difference not independently verified." }
            } + (manifest.phases ?? []).flatMap { phase in
                phase.timestampBindings.map { "Intended timestamp binding at \($0.jsonPointer.prefix(128))." }
            }
            value.intendedChanges = Array(changes.prefix(32))
            if changes.count > 32 || manifest.authoring?.reviewedChangesTruncated == true { value.qualifications.append("intendedChangesTruncated") }
            if changes.isEmpty, !manifest.responseEffects.isEmpty { value.qualifications.append("reviewedFieldEditsUnavailable") }
            if manifest.responseEffects.contains(where: { $0.graphQLOperationName != nil || $0.matchHeaderName != nil }) {
                value.qualifications.append("unsupportedMetadataPredicate")
            }
            if !manifest.hlsSubstitutions.isEmpty {
                value.qualifications.append("mediaBaselineEntryOnlyNoUpstreamChildInference")
            }
            let supported = zip(manifest.responseEffects, rules).filter { $0.0.graphQLOperationName == nil && $0.0.matchHeaderName == nil }.map(\.1)
            active[window.id] = .init(window: value, rules: supported,
                media: manifest.hlsSubstitutions.filter { $0.replacesSubstitutionID == nil })
            return value
        }
    }

    func admit(_ request: CapturedRequest, at instant: Date = Date()) -> [UUID] {
        lock.withLock {
            guard !active.isEmpty else { return [] }
            var result: [UUID] = []
            for id in Array(active.keys) {
                guard var state = active[id], state.window.endedAt == nil else { continue }
                guard request.path.utf8.count <= 8192, request.host.utf8.count <= 1024 else {
                    qualify(&state.window, "requestMetadataLimit")
                    active[id] = state
                    continue
                }
                var matches = Set(state.rules.filter { matcher.matchesConfiguration(rule: $0, request: request) }.map(\.id))
                let path = String(request.path.split(separator: "?", maxSplits: 1).first ?? "")
                for media in state.media where request.method == "GET" || request.method == "HEAD" {
                    guard media.requestPolicy?.permits(request) ?? true else { continue }
                    guard media.origin == HLSSubstitutionOrigin(scheme: request.scheme, host: request.host, port: request.port) else { continue }
                    let mount = "/.joesproxy/hls-substitution/\(media.id.uuidString.lowercased())/"
                    let entry = HLSRequestPolicy.entryMatches(request.path, scope: media.scope, policy: media.requestPolicy)
                    if entry || path.hasPrefix(mount) { matches.insert(media.id) }
                }
                guard !matches.isEmpty else { continue }
                for index in state.window.resources.indices where matches.contains(state.window.resources[index].id) {
                    state.window.resources[index].observed += 1
                }
                if tickets.count < 256 {
                    let ticket = UUID()
                    tickets[ticket] = .init(windowID: id, resources: matches, startedAt: instant)
                    result.append(ticket)
                } else { qualify(&state.window, "pendingObservationLimit") }
                active[id] = state
            }
            return result
        }
    }

    func attach(_ ids: [UUID], sessionID: UUID?) {
        lock.withLock {
            for id in ids {
                guard let ticket = tickets[id] else { continue }
                if let sessionID {
                    tickets[id]?.sessionID = sessionID
                    if var state = active[ticket.windowID] {
                        if state.admittedSessionIDs.insert(sessionID).inserted {
                            state.admittedSessionOrder.append(sessionID)
                            if state.admittedSessionOrder.count > 256 {
                                state.admittedSessionIDs.remove(state.admittedSessionOrder.removeFirst())
                                qualify(&state.window, "deliveryMembershipEvicted")
                            }
                        }
                        active[ticket.windowID] = state
                    }
                }
                else {
                    if var state = active[ticket.windowID] {
                        qualify(&state.window, "captureNotAdmitted")
                        active[ticket.windowID] = state
                    }
                    tickets.removeValue(forKey: id)
                }
            }
        }
    }

    func complete(sessionID: UUID, status: Int?, duration: TimeInterval?) {
        lock.withLock {
            for id in tickets.keys.filter({ tickets[$0]?.sessionID == sessionID }) {
                guard let ticket = tickets.removeValue(forKey: id), var state = active[ticket.windowID], state.window.endedAt == nil else { continue }
                for index in state.window.resources.indices where ticket.resources.contains(state.window.resources[index].id) {
                    state.window.resources[index].completed += 1
                    if let status { state.window.resources[index].statusFamilies["\(status / 100)xx", default: 0] += 1 }
                    if let duration, duration.isFinite, duration >= 0 {
                        let ms = duration * 1000
                        state.window.resources[index].latencySamples += 1
                        state.window.resources[index].latencyTotalMilliseconds += ms
                        state.window.resources[index].minimumMilliseconds = min(state.window.resources[index].minimumMilliseconds ?? ms, ms)
                        state.window.resources[index].maximumMilliseconds = max(state.window.resources[index].maximumMilliseconds ?? ms, ms)
                    }
                }
                active[ticket.windowID] = state
            }
        }
    }

    func noteCaptureReset() {
        lock.withLock {
            for id in Array(active.keys) {
                guard var state = active[id], state.window.endedAt == nil else { continue }
                qualify(&state.window, "captureEpochChanged")
                active[id] = state
            }
            tickets.removeAll()
        }
    }

    func notePhase(activationID: UUID, phaseID: UUID) {
        lock.withLock {
            for id in Array(active.keys) {
                guard var state = active[id], state.window.endedAt == nil,
                      state.window.activationID == activationID,
                      !state.window.phaseIDs.contains(phaseID) else { continue }
                if state.window.phaseIDs.count < 32 { state.window.phaseIDs.append(phaseID) }
                else { qualify(&state.window, "phaseHistoryLimit") }
                active[id] = state
            }
        }
    }

    func end(id: UUID, observations: [EffectBundleObservation], at instant: Date) throws -> DiagnosticExperimentWindow {
        try lock.withLock {
            guard var state = active[id] else { throw EffectBundleError.bundleNotFound }
            if state.window.endedAt != nil { return state.window }
            state.window.endedAt = instant
            let samples = observations.filter {
                $0.identity.activationID == state.window.activationID &&
                $0.sessionID.map { state.admittedSessionIDs.contains($0) } == true
            }
            for index in state.window.resources.indices {
                let resource = state.window.resources[index].id
                let matching = samples.filter { $0.identity.resourceID == resource }
                state.window.resources[index].delivered = matching.filter { $0.delivery == .downstreamWriteSucceeded }.count
                state.window.resources[index].deliveryFailed = matching.filter { $0.delivery == .downstreamWriteFailed }.count
                state.window.resources[index].deliveryPending = matching.filter { $0.delivery == .pending }.count
                for item in matching { state.window.resources[index].outcomes[item.outcome, default: 0] += 1 }
                let groups = Dictionary(grouping: matching.filter { $0.textTrack != nil }, by: { $0.textTrack! })
                let identities = groups.keys.sorted {
                    [$0.id, $0.language, $0.role, $0.sourceRevision].lexicographicallyPrecedes([$1.id, $1.language, $1.role, $1.sourceRevision])
                }
                if identities.count > 8 { qualify(&state.window, "textTrackSummaryTruncated") }
                if !identities.isEmpty {
                    state.window.resources[index].textTracks = identities.prefix(8).map { identity in
                        let values = groups[identity] ?? []
                        return .init(identity: identity, observed: values.count,
                            delivered: values.filter { $0.delivery == .downstreamWriteSucceeded }.count,
                            failed: values.filter { $0.delivery == .downstreamWriteFailed }.count,
                            pending: values.filter { $0.delivery == .pending }.count)
                    }
                    qualify(&state.window, "textDeliveryNotPlayerSelectionOrRendering")
                }
            }
            state.window.phaseIDs = Array(Set(state.window.phaseIDs + samples.compactMap { $0.identity.phaseID })).sorted { $0.uuidString < $1.uuidString }
            if state.window.resources.contains(where: { $0.completed < $0.observed }) { qualify(&state.window, "pendingOrUnavailableAtClose") }
            if state.window.mode == .modified { qualify(&state.window, "boundedReceiptCoverage") }
            tickets = tickets.filter { $0.value.windowID != id }
            active[id] = state
            return state.window
        }
    }

    func remove(id: UUID) { lock.withLock { active.removeValue(forKey: id); tickets = tickets.filter { $0.value.windowID != id } } }

    private func qualify(_ window: inout DiagnosticExperimentWindow, _ reason: String) {
        if !window.qualifications.contains(reason) { window.qualifications.append(reason) }
    }
}
