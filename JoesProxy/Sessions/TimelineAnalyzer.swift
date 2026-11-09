import Foundation

struct TimelineClassification: Equatable, Sendable {
    let lane: TimelineLane
    let labels: Set<TimelineLabel>
}

protocol TimelineClassifying: Sendable {
    func classify(_ session: SessionRecord) -> TimelineClassification
}

struct TimelineClassificationService: Sendable {
    static let timelineBodyDecodeLimit = 64 * 1024

    func classify(_ session: SessionRecord) -> TimelineClassification {
        var labels: Set<TimelineLabel> = []

        if session.state == .failed || isErrorStatus(session.response?.statusCode) {
            labels.insert(.error)
            return TimelineClassification(lane: .errorsRetries, labels: labels)
        }

        let path = session.request.path.lowercased()
        let host = session.request.host.lowercased()
        let hostPath = "\(host) \(path)"
        let contentType = headerValue("Content-Type", in: session.response?.headers ?? []).lowercased()
        let mediaType = MediaDetector.listMediaType(for: session)

        if isAdOrAnalytics(hostPath: hostPath) {
            labels.insert(.adAnalytics)
            return TimelineClassification(lane: .adsAnalytics, labels: labels)
        }

        if isLicenseRequest(hostPath: hostPath, contentType: contentType) {
            labels.insert(.drmLicense)
            return TimelineClassification(lane: .drmLicense, labels: labels)
        }

        switch mediaType {
        case .hls:
            labels.formUnion([.manifest, .hls])
            return TimelineClassification(lane: .manifest, labels: labels)
        case .dash:
            labels.formUnion([.manifest, .dash])
            return TimelineClassification(lane: .manifest, labels: labels)
        case .hlsDiscovery:
            labels.formUnion([.api, .playbackAPI, .manifest])
            return TimelineClassification(lane: .api, labels: labels)
        case .video:
            if isLikelyInitSegment(path: path) {
                labels.formUnion([.mediaSegment, .initSegment])
            } else {
                labels.insert(.mediaSegment)
            }
            return TimelineClassification(lane: .mediaSegments, labels: labels)
        case .image:
            labels.insert(.imageAsset)
            return TimelineClassification(lane: .imagesAssets, labels: labels)
        case .adXml:
            labels.insert(.adAnalytics)
            return TimelineClassification(lane: .adsAnalytics, labels: labels)
        case .none:
            break
        }

        if isManifestPath(path) || contentType.contains("mpegurl") || contentType.contains("dash+xml") {
            labels.insert(.manifest)
            if path.contains(".mpd") || contentType.contains("dash+xml") {
                labels.insert(.dash)
            } else {
                labels.insert(.hls)
            }
            return TimelineClassification(lane: .manifest, labels: labels)
        }

        if isMediaSegmentPath(path) {
            labels.insert(.mediaSegment)
            if isLikelyInitSegment(path: path) {
                labels.insert(.initSegment)
            }
            return TimelineClassification(lane: .mediaSegments, labels: labels)
        }

        if isImageOrAssetPath(path) || contentType.hasPrefix("image/") {
            labels.insert(.imageAsset)
            return TimelineClassification(lane: .imagesAssets, labels: labels)
        }

        if isAuthOrConfig(hostPath: hostPath) {
            labels.insert(.api)
            return TimelineClassification(lane: .authConfig, labels: labels)
        }

        labels.insert(.api)
        if shouldInspectBodyHints(
            hostPath: hostPath,
            path: path,
            contentType: contentType,
            response: session.response
        ), let bodyLabels = boundedJSONLabels(in: session.response) {
            labels.formUnion(bodyLabels)
        }
        return TimelineClassification(lane: .api, labels: labels)
    }

    private func shouldInspectBodyHints(
        hostPath: String,
        path: String,
        contentType: String,
        response: CapturedResponse?
    ) -> Bool {
        guard let response,
              let bodySize = response.bodySize ?? response.bodyData?.count,
              bodySize <= Self.timelineBodyDecodeLimit else {
            return false
        }

        let jsonish = contentType.contains("json") ||
            path.hasSuffix(".json") ||
            path.contains(".json?")
        guard jsonish else { return false }

        return [
            "playback", "dynamicplay", "stream", "manifest", "video", "media",
            "player", "config", "entitlement", "show", "episode", "license",
            "fairplay", "widevine"
        ].contains { hostPath.contains($0) }
    }

    private func boundedJSONLabels(in response: CapturedResponse?) -> Set<TimelineLabel>? {
        guard let response,
              let decoded = CapturedBodyDecoder.decode(
                response: response,
                maxDecodedBytes: Self.timelineBodyDecodeLimit
              ),
              decoded.canUseAnalysisDataForInspection,
              let text = decoded.analysisUTF8Text() else {
            return nil
        }

        var labels: Set<TimelineLabel> = []
        if !decoded.appliedCodings.isEmpty {
            labels.insert(.gzipDecoded)
        }

        let lower = text.lowercased()
        if lower.contains(".m3u8") || lower.contains("streamingurl") || lower.contains("playback_url") {
            labels.formUnion([.playbackAPI, .manifest])
        }
        if lower.contains("license") || lower.contains("fairplay") || lower.contains("widevine") {
            labels.insert(.drmLicense)
        }

        return labels.isEmpty ? nil : labels
    }

    private func headerValue(_ name: String, in headers: [HTTPHeaderField]) -> String {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
    }

    private func isErrorStatus(_ statusCode: Int?) -> Bool {
        guard let statusCode else { return false }
        return statusCode >= 400
    }

    private func isLicenseRequest(hostPath: String, contentType: String) -> Bool {
        let combined = "\(hostPath) \(contentType)"
        return ["license", "fairplay", "widevine", "playready", "/ckc", "/spc", "/key"]
            .contains { combined.contains($0) }
    }

    private func isAdOrAnalytics(hostPath: String) -> Bool {
        [
            "doubleclick", "googlesyndication", "adservice", "adsystem", "vast", "vmap",
            "analytics", "telemetry", "newrelic", "braze", "segment.io", "amplitude"
        ].contains { hostPath.contains($0) }
    }

    private func isAuthOrConfig(hostPath: String) -> Bool {
        ["auth", "oauth", "token", "login", "config", "feature", "entitlement"]
            .contains { hostPath.contains($0) }
    }

    private func isManifestPath(_ path: String) -> Bool {
        path.contains(".m3u8") || path.contains(".mpd")
    }

    private func isMediaSegmentPath(_ path: String) -> Bool {
        [".ts", ".m4s", ".cmfv", ".cmfa", ".mp4", ".m4v"].contains { hasPathExtension($0, in: path) }
    }

    private func isLikelyInitSegment(path: String) -> Bool {
        path.contains("init") || path.contains("map.") || path.contains("_init")
    }

    private func isImageOrAssetPath(_ path: String) -> Bool {
        let assetExtensions = [
            ".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".svg",
            ".css", ".js", ".woff", ".woff2", ".ttf"
        ]
        return assetExtensions.contains { hasPathExtension($0, in: path) }
    }

    private func looksLikeAPIPath(_ path: String) -> Bool {
        path.contains("/api/") ||
        path.contains("/apps-api/") ||
        path.contains("/graphql") ||
        path.hasSuffix(".json") ||
        path.contains(".json?")
    }

    private func hasPathExtension(_ pathExtension: String, in path: String) -> Bool {
        guard let markerRange = path.range(of: pathExtension) else {
            return false
        }
        let markerEnd = markerRange.upperBound
        guard markerEnd == path.endIndex else {
            let next = path[markerEnd]
            return next == "?" || next == "#" || next == "/" || next == "&"
        }
        return true
    }
}

extension TimelineClassificationService: TimelineClassifying {}

struct TimelineAnalyzer: Sendable {
    private let classifier: any TimelineClassifying

    init(classifier: any TimelineClassifying = TimelineClassificationService()) {
        self.classifier = classifier
    }

    func analyze(
        sessions: [SessionRecord],
        filter: TimelineFilterState = .empty,
        selectedSessionID: SessionRecord.ID? = nil,
        pins: [TimelinePin] = []
    ) -> TimelineAnalysisResult {
        let events = classifyAll(sessions: sessions, pins: pins)
        let media = MediaTimelineCorrelator().summarize(events: events)
        return buildResult(
            events: events,
            filter: filter,
            selectedSessionID: selectedSessionID,
            mediaSummary: media,
            captureStart: events.lazy.map(\.startedAt).min(),
            captureEnd: events.lazy.map(\.completedAt).max()
        )
    }

    /// Phase 1 (expensive): classify all sessions into events. Re-run when sessions or pins change.
    func classifyAll(sessions: [SessionRecord], pins: [TimelinePin] = []) -> [TimelineEvent] {
        guard !sessions.isEmpty else { return [] }
        let pinnedRequestIDs: Set<SessionRecord.ID> = Set(pins.compactMap {
            guard case .request(let id) = $0 else { return nil }
            return id
        })
        return sessions
            .map { event(for: $0, isPinned: pinnedRequestIDs.contains($0.id)) }
            .sorted { lhs, rhs in
                lhs.startedAt == rhs.startedAt ? lhs.duration < rhs.duration : lhs.startedAt < rhs.startedAt
            }
    }

    /// Phase 2 (cheap): apply filter + build derived data. Re-run when filter or selection changes.
    func buildResult(
        events: [TimelineEvent],
        filter: TimelineFilterState = .empty,
        selectedSessionID: SessionRecord.ID? = nil,
        mediaSummary: MediaTimelineSummary?,
        captureStart: Date?,
        captureEnd: Date?,
        renderLimit: Int = TimelineRenderPolicy.defaultVisibleEventLimit
    ) -> TimelineAnalysisResult {
        let spState = CapturePerformanceSignposts.signposter.beginInterval("timeline-buildResult")
        defer { CapturePerformanceSignposts.signposter.endInterval("timeline-buildResult", spState) }
        let normalizedEvents = normalizedEvents(events, captureStart: captureStart, captureEnd: captureEnd)
        let visibleEvents = apply(filter: filter, to: normalizedEvents, selectedSessionID: selectedSessionID)
        let renderedEvents = renderWindow(
            from: visibleEvents,
            selectedSessionID: selectedSessionID,
            renderLimit: renderLimit
        )
        let gaps = buildGaps(from: visibleEvents)
        let findings = buildFindings(events: visibleEvents, gaps: gaps, mediaSummary: mediaSummary)
        return TimelineAnalysisResult(
            events: normalizedEvents,
            visibleEvents: visibleEvents,
            renderedEvents: renderedEvents,
            gaps: gaps,
            findings: findings,
            mediaSummary: mediaSummary,
            captureStart: captureStart,
            captureEnd: captureEnd,
            filteredEventCount: visibleEvents.count,
            renderedEventCount: renderedEvents.count,
            renderLimit: renderLimit,
            eventsByLane: Dictionary(grouping: renderedEvents, by: \.lane),
            gapsByLane: Dictionary(grouping: gaps.filter { $0.lane != nil }, by: { $0.lane! })
        )
    }

    func event(for session: SessionRecord, isPinned: Bool = false) -> TimelineEvent {
        let classification = classifier.classify(session)
        let duration = max(session.timing.duration ?? 0.05, 0.05)
        var labels = classification.labels
        if isPinned {
            labels.insert(.pinned)
        }

        return TimelineEvent(
            sessionID: session.id,
            lane: classification.lane,
            labels: labels,
            startedAt: session.timing.startedAt,
            duration: duration,
            method: session.request.method,
            statusCode: session.response?.statusCode,
            host: session.request.host,
            pathSummary: session.request.path,
            byteCount: session.response?.bodySize,
            inspectionKind: session.request.inspectionKind,
            isPinned: isPinned,
            normalizedStart: 0,
            normalizedDuration: 0
        )
    }

    func normalizedEvents(_ events: [TimelineEvent], captureStart: Date?, captureEnd: Date?) -> [TimelineEvent] {
        guard let captureStart, let captureEnd, !events.isEmpty else { return events }
        let span = max(0.1, captureEnd.timeIntervalSince(captureStart))
        return events.map { event in
            TimelineEvent(
                sessionID: event.sessionID,
                lane: event.lane,
                labels: event.labels,
                startedAt: event.startedAt,
                duration: event.duration,
                method: event.method,
                statusCode: event.statusCode,
                host: event.host,
                pathSummary: event.pathSummary,
                byteCount: event.byteCount,
                inspectionKind: event.inspectionKind,
                isPinned: event.isPinned,
                normalizedStart: max(0, event.startedAt.timeIntervalSince(captureStart) / span),
                normalizedDuration: max(0.001, event.duration / span)
            )
        }
    }

    private func apply(
        filter: TimelineFilterState,
        to events: [TimelineEvent],
        selectedSessionID: SessionRecord.ID?
    ) -> [TimelineEvent] {
        let selectedEvent = selectedSessionID.flatMap { id in events.first { $0.sessionID == id } }
        let aroundInterval = filter.aroundSelection.interval
        let query = filter.hostOrPathContains.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return events.filter { event in
            if let lane = filter.lane {
                if lane == .pinned {
                    guard event.isPinned else { return false }
                } else if event.lane != lane {
                    return false
                }
            }

            if filter.pinnedOnly && !event.isPinned {
                return false
            }

            if !query.isEmpty &&
                !event.host.lowercased().contains(query) &&
                !event.pathSummary.lowercased().contains(query) {
                return false
            }

            if let minimumDuration = filter.minimumDuration,
               event.duration < minimumDuration {
                return false
            }

            if !matchesStatus(filter.statusFilter, event: event) {
                return false
            }

            if let aroundInterval, let selectedEvent {
                let lowerBound = selectedEvent.startedAt.addingTimeInterval(-aroundInterval)
                let upperBound = selectedEvent.startedAt.addingTimeInterval(aroundInterval)
                if event.startedAt < lowerBound || event.startedAt > upperBound {
                    return false
                }
            }

            return true
        }
    }

    private func renderWindow(
        from events: [TimelineEvent],
        selectedSessionID: SessionRecord.ID?,
        renderLimit: Int
    ) -> [TimelineEvent] {
        guard renderLimit > 0, events.count > renderLimit else {
            return events
        }

        if let selectedSessionID,
           let selectedIndex = events.firstIndex(where: { $0.sessionID == selectedSessionID }) {
            let half = renderLimit / 2
            let lower = max(0, min(selectedIndex - half, events.count - renderLimit))
            return Array(events[lower..<lower + renderLimit])
        }

        return Array(events.suffix(renderLimit))
    }

    private func matchesStatus(_ filter: TimelineStatusFilter, event: TimelineEvent) -> Bool {
        switch filter {
        case .all:
            return true
        case .success:
            return event.statusCode.map { (200...299).contains($0) } ?? false
        case .redirect:
            return event.statusCode.map { (300...399).contains($0) } ?? false
        case .clientError:
            return event.statusCode.map { (400...499).contains($0) } ?? false
        case .serverError:
            return event.statusCode.map { (500...599).contains($0) } ?? false
        case .failures:
            return event.statusCode == nil || event.labels.contains(.error)
        }
    }

    private func buildGaps(from events: [TimelineEvent]) -> [TimelineGap] {
        guard events.count > 1 else { return [] }

        var gaps: [TimelineGap] = []
        for pair in zip(events, events.dropFirst()) {
            let previous = pair.0
            let next = pair.1
            let gapDuration = next.startedAt.timeIntervalSince(previous.completedAt)
            guard gapDuration > 2.0 else {
                continue
            }

            let reason: TimelineGapReason
            let lane: TimelineLane?
            if previous.lane == .mediaSegments && next.lane == .mediaSegments {
                reason = .mediaSegmentGap
                lane = .mediaSegments
            } else if previous.labels.contains(.playbackAPI) || next.lane == .manifest || next.lane == .mediaSegments {
                reason = .playbackStartupGap
                lane = next.lane
            } else {
                reason = .idle
                lane = nil
            }

            gaps.append(
                TimelineGap(
                    id: UUID(),
                    lane: lane,
                    start: previous.completedAt,
                    duration: gapDuration,
                    previousSessionID: previous.sessionID,
                    nextSessionID: next.sessionID,
                    reason: reason,
                    severity: gapDuration >= 5 ? .high : .attention
                )
            )
        }
        return gaps
    }

    private func buildFindings(
        events: [TimelineEvent],
        gaps: [TimelineGap],
        mediaSummary: MediaTimelineSummary?
    ) -> [TimelineFinding] {
        var findings: [TimelineFinding] = []

        for gap in gaps.prefix(6) {
            findings.append(
                TimelineFinding(
                    id: UUID(),
                    title: "\(gap.reason.title): \(gap.duration.formattedAsSeconds())",
                    detail: "No matching timeline traffic was captured for \(gap.duration.formattedAsSeconds()).",
                    severity: gap.severity,
                    confidence: .observed,
                    evidenceSessionIDs: [gap.previousSessionID, gap.nextSessionID].compactMap { $0 },
                    evidenceRange: DateInterval(start: gap.start, duration: gap.duration)
                )
            )
        }

        if let mediaSummary {
            if let delay = mediaSummary.firstSegmentDelay,
               let start = eventStart(mediaSummary.playbackAPISessionID, in: events),
               delay > 2 {
                findings.append(
                    TimelineFinding(
                        id: UUID(),
                        title: "First segment delayed by \(delay.formattedAsSeconds())",
                        detail: "Likely playback startup risk: first media segment began \(delay.formattedAsSeconds()) after the playback API.",
                        severity: delay >= 5 ? .high : .attention,
                        confidence: .likely,
                        evidenceSessionIDs: [mediaSummary.playbackAPISessionID].compactMap { $0 } + Array(mediaSummary.mediaSegmentSessionIDs.prefix(1)),
                        evidenceRange: DateInterval(start: start, duration: delay)
                    )
                )
            }

            if let longestGap = mediaSummary.cadence?.longestSegmentGap,
               longestGap > 3,
               let firstSegmentID = mediaSummary.mediaSegmentSessionIDs.first,
               let start = eventStart(firstSegmentID, in: events) {
                findings.append(
                    TimelineFinding(
                        id: UUID(),
                        title: "Likely buffering risk",
                        detail: "Media segment cadence had a \(longestGap.formattedAsSeconds()) gap.",
                        severity: longestGap >= 6 ? .high : .attention,
                        confidence: .likely,
                        evidenceSessionIDs: Array(mediaSummary.mediaSegmentSessionIDs.prefix(6)),
                        evidenceRange: DateInterval(start: start, duration: longestGap)
                    )
                )
            }
        }

        return Array(findings.prefix(8))
    }

    private func eventStart(_ id: SessionRecord.ID?, in events: [TimelineEvent]) -> Date? {
        guard let id else { return nil }
        return events.first { $0.sessionID == id }?.startedAt
    }
}

struct TimelineCachedAnalysis: Equatable, Sendable {
    let events: [TimelineEvent]
    let classifiedCount: Int
    let reusedCount: Int
    let removedCount: Int
}

struct TimelineAnalysisCache: Sendable {
    private var entriesByID: [SessionRecord.ID: Entry] = [:]

    mutating func reset() {
        entriesByID = [:]
    }

    /// - Parameter dirtyIDs: When the caller tracks store changes precisely, the set of
    ///   session IDs whose records changed since the previous update. Clean sessions with
    ///   a cache entry then skip fingerprint computation (the per-session header sort)
    ///   entirely. Pass `nil` to fall back to fingerprint-based change detection.
    mutating func update(
        sessions: [SessionRecord],
        pins: [TimelinePin],
        dirtyIDs: Set<SessionRecord.ID>? = nil,
        analyzer: TimelineAnalyzer = TimelineAnalyzer()
    ) -> TimelineCachedAnalysis {
        update(sessions: sessions, pins: pins, dirtyIDs: dirtyIDs, analyzer: analyzer, checkCancellation: {})
    }

    /// Cancellation can leave this value partially updated; callers must discard it on error.
    mutating func update(
        sessions: [SessionRecord],
        pins: [TimelinePin],
        dirtyIDs: Set<SessionRecord.ID>? = nil,
        analyzer: TimelineAnalyzer = TimelineAnalyzer(),
        checkCancellation: () throws -> Void
    ) rethrows -> TimelineCachedAnalysis {
        try checkCancellation()
        let spState = CapturePerformanceSignposts.signposter.beginInterval("timeline-cache-update")
        defer { CapturePerformanceSignposts.signposter.endInterval("timeline-cache-update", spState) }
        let pinnedRequestIDs: Set<SessionRecord.ID> = Set(pins.compactMap {
            guard case .request(let id) = $0 else { return nil }
            return id
        })
        let liveIDs = Set(sessions.map(\.id))
        let removedCount = Array(entriesByID.keys).reduce(into: 0) { count, id in
            if !liveIDs.contains(id) {
                entriesByID[id] = nil
                count += 1
            }
        }

        var classifiedCount = 0
        var reusedCount = 0
        var events: [TimelineEvent] = []
        events.reserveCapacity(sessions.count)

        for session in sessions {
            try checkCancellation()
            let isPinned = pinnedRequestIDs.contains(session.id)

            if let dirtyIDs, !dirtyIDs.contains(session.id), let entry = entriesByID[session.id] {
                reusedCount += 1
                let event = Self.applyPinned(isPinned, to: entry.event)
                entriesByID[session.id] = Entry(fingerprint: entry.fingerprint, event: event)
                events.append(event)
                continue
            }

            let fingerprint = TimelineSessionFingerprint(session)
            if let entry = entriesByID[session.id], entry.fingerprint == fingerprint {
                reusedCount += 1
                let event = Self.applyPinned(isPinned, to: entry.event)
                entriesByID[session.id] = Entry(fingerprint: fingerprint, event: event)
                events.append(event)
            } else {
                classifiedCount += 1
                let event = analyzer.event(for: session, isPinned: isPinned)
                entriesByID[session.id] = Entry(fingerprint: fingerprint, event: event)
                events.append(event)
            }
        }

        try checkCancellation()
        events.sort {
            $0.startedAt == $1.startedAt ? $0.duration < $1.duration : $0.startedAt < $1.startedAt
        }
        try checkCancellation()
        return TimelineCachedAnalysis(
            events: events,
            classifiedCount: classifiedCount,
            reusedCount: reusedCount,
            removedCount: removedCount
        )
    }

    private static func applyPinned(_ isPinned: Bool, to event: TimelineEvent) -> TimelineEvent {
        var labels = event.labels
        if isPinned {
            labels.insert(.pinned)
        } else {
            labels.remove(.pinned)
        }
        return TimelineEvent(
            sessionID: event.sessionID,
            lane: event.lane,
            labels: labels,
            startedAt: event.startedAt,
            duration: event.duration,
            method: event.method,
            statusCode: event.statusCode,
            host: event.host,
            pathSummary: event.pathSummary,
            byteCount: event.byteCount,
            inspectionKind: event.inspectionKind,
            isPinned: isPinned,
            normalizedStart: event.normalizedStart,
            normalizedDuration: event.normalizedDuration
        )
    }

    private struct Entry: Equatable, Sendable {
        let fingerprint: TimelineSessionFingerprint
        let event: TimelineEvent
    }
}

private struct TimelineSessionFingerprint: Hashable, Sendable {
    let method: String
    let host: String
    let path: String
    let inspectionKind: SessionInspectionKind
    let state: SessionLifecycleState
    let startedAt: Date
    let duration: TimeInterval?
    let statusCode: Int?
    let requestBodySize: Int?
    let responseBodySize: Int?
    let requestHeaderSignature: String
    let responseHeaderSignature: String

    init(_ session: SessionRecord) {
        method = session.request.method
        host = session.request.host
        path = session.request.path
        inspectionKind = session.request.inspectionKind
        state = session.state
        startedAt = session.timing.startedAt
        duration = session.timing.duration
        statusCode = session.response?.statusCode
        requestBodySize = session.request.bodySize ?? session.request.bodyData?.count
        responseBodySize = session.response?.bodySize ?? session.response?.bodyData?.count
        requestHeaderSignature = Self.headerSignature(session.request.headers)
        responseHeaderSignature = Self.headerSignature(session.response?.headers ?? [])
    }

    private static func headerSignature(_ headers: [HTTPHeaderField]) -> String {
        headers
            .map { "\($0.name.lowercased()):\($0.value)" }
            .sorted()
            .joined(separator: "\u{1f}")
    }
}

struct MediaTimelineCorrelator: Sendable {
    func summarize(events: [TimelineEvent]) -> MediaTimelineSummary? {
        var playbackAPI: TimelineEvent?
        var manifests: [TimelineEvent] = []
        var licenses: [TimelineEvent] = []
        var segments: [TimelineEvent] = []

        for event in events {
            switch event.lane {
            case .manifest: manifests.append(event)
            case .drmLicense: licenses.append(event)
            case .mediaSegments: segments.append(event)
            default:
                if playbackAPI == nil && event.labels.contains(.playbackAPI) {
                    playbackAPI = event
                }
            }
        }

        guard playbackAPI != nil || !manifests.isEmpty || !segments.isEmpty || !licenses.isEmpty else {
            return nil
        }

        let anchor = playbackAPI?.startedAt ?? manifests.first?.startedAt ?? segments.first?.startedAt
        let firstManifestDelay = delay(from: anchor, to: manifests.first?.startedAt)
        let firstLicenseDelay = delay(from: anchor, to: licenses.first?.startedAt)
        let firstSegmentDelay = delay(from: anchor, to: segments.first?.startedAt)
        let cadence = segmentCadence(from: segments)

        return MediaTimelineSummary(
            playbackAPISessionID: playbackAPI?.sessionID,
            manifestSessionIDs: manifests.map(\.sessionID),
            licenseSessionIDs: licenses.map(\.sessionID),
            mediaSegmentSessionIDs: segments.map(\.sessionID),
            firstManifestDelay: firstManifestDelay,
            firstLicenseDelay: firstLicenseDelay,
            firstSegmentDelay: firstSegmentDelay,
            cadence: cadence
        )
    }

    private func delay(from start: Date?, to end: Date?) -> TimeInterval? {
        guard let start, let end else { return nil }
        return max(0, end.timeIntervalSince(start))
    }

    private func segmentCadence(from segments: [TimelineEvent]) -> SegmentCadenceSummary? {
        guard !segments.isEmpty else { return nil }

        let sorted = segments.sorted { $0.startedAt < $1.startedAt }
        let gaps = zip(sorted, sorted.dropFirst()).map {
            max(0, $1.startedAt.timeIntervalSince($0.completedAt))
        }

        return SegmentCadenceSummary(
            segmentCount: sorted.count,
            slowestSegmentDuration: sorted.map(\.duration).max(),
            longestSegmentGap: gaps.max(),
            failedSegmentCount: sorted.filter { $0.labels.contains(.error) || ($0.statusCode ?? 200) >= 400 }.count
        )
    }
}
