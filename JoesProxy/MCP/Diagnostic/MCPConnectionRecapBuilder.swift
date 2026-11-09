import Foundation

/// Sanitized, bounded per-connection activity summary from audit records (AJ-5).
enum MCPConnectionRecapBuilder {
    static let maxLines = 12

    struct Recap: Equatable, Sendable {
        var clientID: String
        var displayName: String
        var connectedDurationDescription: String
        var summaryLines: [String]
        var proseSummary: String
    }

    /// Builds a connection-scoped recap for one client within optional time bounds.
    static func build(
        clientID: String,
        displayName: String,
        events: [MCPAuditEvent],
        connectedAt: Date?,
        lastActivityAt: Date?,
        scenarioNamesByID: [String: String] = [:],
        now: Date = Date()
    ) -> Recap {
        let windowStart = connectedAt ?? events.first?.timestamp ?? now
        let windowEnd = lastActivityAt ?? events.last?.timestamp ?? now
        let filtered = events.filter { event in
            event.clientID == clientID
                && event.timestamp >= windowStart
                && event.timestamp <= windowEnd.addingTimeInterval(1)
        }

        var readSummaries = 0
        var bodyReads = 0
        var mutations = 0
        var throttleChanges = 0
        var scenarioNames: Set<String> = []

        for event in filtered {
            switch event.kind {
            case .resourceRead, .toolCall:
                if event.reasonCode.contains("body") {
                    bodyReads += 1
                } else {
                    readSummaries += 1
                }
            case .proposalApplied, .ruleEnabled, .ruleDisabled, .openWorldExecuted:
                mutations += 1
            case .throttleChanged:
                throttleChanges += 1
            default:
                break
            }
            if let detail = event.detail,
               detail.hasPrefix("scenario:"),
               let scenarioID = detail.split(separator: ":").dropFirst().first.map(String.init),
               let name = scenarioNamesByID[scenarioID] {
                scenarioNames.insert(name)
            }
        }

        var lines: [String] = []
        if readSummaries > 0 {
            lines.append("Read \(readSummaries) session summary tool call(s).")
        }
        if bodyReads > 0 {
            lines.append("Read \(bodyReads) response body field(s) (redacted per disclosure profile).")
        }
        if mutations > 0 {
            lines.append("Applied \(mutations) mutating MCP operation(s).")
        }
        if throttleChanges > 0 {
            lines.append("Changed network throttle \(throttleChanges) time(s).")
        }
        if !scenarioNames.isEmpty {
            lines.append("Scenarios: \(scenarioNames.sorted().joined(separator: ", ")).")
        }
        if lines.isEmpty {
            lines.append("No audited MCP activity in this connection window.")
        }
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            lines.append("… additional activity truncated.")
        }

        let duration = formattedDuration(from: windowStart, to: windowEnd)
        let prose = "\(displayName), connected \(duration): \(lines.joined(separator: " "))"

        return Recap(
            clientID: clientID,
            displayName: displayName,
            connectedDurationDescription: duration,
            summaryLines: lines,
            proseSummary: prose
        )
    }

    private static func formattedDuration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes) min"
        }
        return "\(minutes / 60) hr \(minutes % 60) min"
    }
}
