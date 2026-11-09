import Foundation

struct InstrumentsCorrelatedDiagnosticEngine {

    static func analyze(
        targetName: String,
        durationSeconds: Double,
        tracePath: String,
        sessionStartTime: Date,
        capturedSessions: [SessionRecord],
        traceMetrics: InstrumentsMetricSummary
    ) -> InstrumentsCorrelatedAuditReport {
        var findings: [InstrumentsCausalCorrelationFinding] = []
        var totalBytes = 0

        // Calculate transfer size and inspect wire events
        for session in capturedSessions {
            let bodySize = session.response?.bodyData?.count ?? session.response?.bodySize ?? 0
            totalBytes += bodySize
        }

        // Pattern 1: Match large payload responses to subsequent main-thread hangs
        for hang in traceMetrics.detectedHangs {
            let hangStart = sessionStartTime.addingTimeInterval(hang.startTimeSeconds)

            // Look for a session that finished within 200ms before this hang started
            if let triggerSession = capturedSessions.first(where: { session in
                let duration = session.timing.duration ?? 0.0
                let responseTime = session.timing.startedAt.addingTimeInterval(duration)
                let deltaMs = hangStart.timeIntervalSince(responseTime) * 1000.0
                let bodySize = session.response?.bodyData?.count ?? session.response?.bodySize ?? 0
                return deltaMs >= -50.0 && deltaMs <= 250.0 && bodySize > 50_000 // >50KB
            }) {
                let bodySize = triggerSession.response?.bodyData?.count ?? triggerSession.response?.bodySize ?? 0
                let endpoint = "\(triggerSession.request.scheme.rawValue)://\(triggerSession.request.host)\(triggerSession.request.path)"
                findings.append(InstrumentsCausalCorrelationFinding(
                    severity: hang.severity.uppercased(),
                    title: "Main Thread Stalled by Response Payload Parsing",
                    description: "Main thread was blocked for \(Int(hang.durationMs))ms immediately after receiving \(bodySize / 1024) KB from \(triggerSession.request.path).",
                    timestampOffsetSeconds: hang.startTimeSeconds,
                    relatedEndpoint: endpoint,
                    relatedPayloadSizeBytes: bodySize,
                    relatedHangDurationMs: hang.durationMs,
                    rootCause: "Response body deserialization and view graph construction executed synchronously on the main thread.",
                    recommendation: "Move JSON decoding and heavy model mapping to a detached background task before publishing to @MainActor."
                ))
            }
        }

        // Pattern 2: Media Segment Delivery Stalls
        for session in capturedSessions {
            let path = session.request.path.lowercased()
            if path.hasSuffix(".ts") || path.hasSuffix(".m4s") {
                let duration = session.timing.duration ?? 0.0
                let statusCode = session.response?.statusCode ?? 0
                if duration > 1.5 || statusCode >= 400 {
                    let offset = max(0, session.timing.startedAt.timeIntervalSince(sessionStartTime))
                    let endpoint = "\(session.request.scheme.rawValue)://\(session.request.host)\(session.request.path)"
                    let bodySize = session.response?.bodyData?.count ?? session.response?.bodySize
                    findings.append(InstrumentsCausalCorrelationFinding(
                        severity: "WARNING",
                        title: "Media Segment Delivery Latency Starvation",
                        description: "Segment \(session.request.path) took \(String(format: "%.2f", duration))s to transfer with HTTP \(statusCode).",
                        timestampOffsetSeconds: offset,
                        relatedEndpoint: endpoint,
                        relatedPayloadSizeBytes: bodySize,
                        relatedHangDurationMs: nil,
                        rootCause: "Slow transport delivery or high server TTFB starved the player's forward decode buffer.",
                        recommendation: "Inspect CDN edge cache hit ratio and adaptive bitrate switching ladder."
                    ))
                }
            }
        }

        // Pattern 3: Hotspot Frame Analysis
        for hotspot in traceMetrics.topHotspots {
            if hotspot.symbol.lowercased().contains("json") || hotspot.symbol.lowercased().contains("decode") {
                findings.append(InstrumentsCausalCorrelationFinding(
                    severity: "NOTICE",
                    title: "High CPU Consumption in JSON Deserialization",
                    description: "Symbol '\(hotspot.symbol)' accounted for \(Int(hotspot.weightPercentage))% of CPU samples.",
                    timestampOffsetSeconds: 0.0,
                    relatedEndpoint: nil,
                    relatedPayloadSizeBytes: nil,
                    relatedHangDurationMs: nil,
                    rootCause: "Synchronous parsing of complex JSON payload trees.",
                    recommendation: "Optimize model keys or defer non-visible properties."
                ))
                break
            }
        }

        let markdown = renderMarkdownSummary(
            targetName: targetName,
            durationSeconds: durationSeconds,
            tracePath: tracePath,
            totalRequests: capturedSessions.count,
            totalBytes: totalBytes,
            traceMetrics: traceMetrics,
            findings: findings
        )

        return InstrumentsCorrelatedAuditReport(
            target: targetName,
            durationSeconds: durationSeconds,
            tracePath: tracePath,
            totalRequestsCaptured: capturedSessions.count,
            totalBytesTransferred: totalBytes,
            mutatedEndpointsCount: 0,
            hostHangsCount: traceMetrics.detectedHangs.count,
            peakCPUPercentage: traceMetrics.topHotspots.first?.weightPercentage,
            findings: findings,
            markdownSummary: markdown
        )
    }

    private static func renderMarkdownSummary(
        targetName: String,
        durationSeconds: Double,
        tracePath: String,
        totalRequests: Int,
        totalBytes: Int,
        traceMetrics: InstrumentsMetricSummary,
        findings: [InstrumentsCausalCorrelationFinding]
    ) -> String {
        var out = """
        === JoesProxy Correlated Performance Audit ===
        Target: \(targetName) | Duration: \(String(format: "%.1f", durationSeconds))s | Trace: \(tracePath)

        [Wire Delivery Overview]
        - Requests Captured: \(totalRequests)
        - Total Transferred: \(totalBytes / 1024) KB

        [Host Runtime Overview (\(traceMetrics.templateName))]
        - Detected Main-Thread Hangs: \(traceMetrics.detectedHangs.count)
        - Top CPU Hotspots:
        """

        for (idx, hotspot) in traceMetrics.topHotspots.prefix(3).enumerated() {
            out += "\n  \(idx + 1). \(hotspot.symbol) (\(hotspot.binaryName))"
        }

        out += "\n\n[Causal Correlation Findings]"
        if findings.isEmpty {
            out += "\n- No severe host-wire performance correlations detected."
        } else {
            for finding in findings {
                out += "\n- [\(finding.severity)] \(finding.title):"
                out += "\n  • Description: \(finding.description)"
                out += "\n  • Root Cause: \(finding.rootCause)"
                out += "\n  • Fix: \(finding.recommendation)"
            }
        }

        return out
    }
}
