//
//  WebVTTEngine.swift
//  JoesProxy
//
//  Parser, sync drift calculator, and defect auditor for WebVTT subtitle and caption tracks.
//

import Foundation

enum WebVTTEngine {

    /// Parses WebVTT document text and performs comprehensive defect validation and sync drift analysis.
    static func parse(
        vttText: String,
        videoPTSOffsetSeconds: Double? = nil,
        isHlsSegment: Bool = false
    ) -> WebVTTTrackReport {
        var header = WebVTTHeader(rawHeader: "")
        var cues: [WebVTTCue] = []
        var defects: [WebVTTDefect] = []

        let normalized = vttText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var inHeader = true
        var currentCueID: String? = nil
        var currentStartTime: Double? = nil
        var currentEndTime: Double? = nil
        var currentSettings: String? = nil
        var currentTextLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Header Parsing
            if inHeader {
                if trimmed.hasPrefix("WEBVTT") {
                    header.rawHeader = trimmed
                    continue
                }
                if trimmed.hasPrefix("X-TIMESTAMP-MAP") {
                    parseTimestampMap(trimmed, into: &header)
                    continue
                }
                if trimmed.isEmpty {
                    inHeader = false
                    continue
                }
                continue
            }

            // Cue Block Parsing
            if trimmed.isEmpty {
                // End of current cue block
                if let start = currentStartTime, let end = currentEndTime {
                    let fullText = currentTextLines.joined(separator: "\n")
                    let cue = WebVTTCue(
                        id: currentCueID ?? "cue-\(cues.count + 1)",
                        cueIdentifier: currentCueID,
                        startTimeSeconds: start,
                        endTimeSeconds: end,
                        settings: currentSettings,
                        text: fullText,
                        lines: currentTextLines
                    )
                    cues.append(cue)
                }

                currentCueID = nil
                currentStartTime = nil
                currentEndTime = nil
                currentSettings = nil
                currentTextLines = []
                continue
            }

            // Check if line is a timestamp line (e.g. "00:00:01.000 --> 00:00:04.000")
            if line.contains("-->") {
                let parts = line.components(separatedBy: "-->")
                if parts.count >= 2 {
                    let startStr = parts[0].trimmingCharacters(in: .whitespaces)
                    let rest = parts[1].trimmingCharacters(in: .whitespaces)
                    let restTokens = rest.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

                    currentStartTime = parseTimestamp(startStr)
                    if let endStr = restTokens.first {
                        currentEndTime = parseTimestamp(endStr)
                    }
                    if restTokens.count > 1 {
                        currentSettings = restTokens.dropFirst().joined(separator: " ")
                    }
                }
            } else if currentStartTime == nil {
                // Line before timestamp is cue identifier
                currentCueID = trimmed
            } else {
                // Line after timestamp is cue payload text
                currentTextLines.append(line)
            }
        }

        // Final pending cue if file doesn't end with newline
        if let start = currentStartTime, let end = currentEndTime {
            let fullText = currentTextLines.joined(separator: "\n")
            let cue = WebVTTCue(
                id: currentCueID ?? "cue-\(cues.count + 1)",
                cueIdentifier: currentCueID,
                startTimeSeconds: start,
                endTimeSeconds: end,
                settings: currentSettings,
                text: fullText,
                lines: currentTextLines
            )
            cues.append(cue)
        }

        // Run Defect Validation Rules
        defects = auditDefects(
            cues: cues,
            header: header,
            isHlsSegment: isHlsSegment,
            videoPTSOffsetSeconds: videoPTSOffsetSeconds
        )

        // Calculate Sync Drift
        var syncDriftMs: Double? = nil
        if let expectedPTS = videoPTSOffsetSeconds, let mpegts = header.mpegtsOffset {
            let headerPtsSeconds = Double(mpegts) / 90000.0
            let localSeconds = header.localOffsetSeconds ?? 0.0
            let calculatedSubtitlePTS = headerPtsSeconds - localSeconds
            syncDriftMs = (calculatedSubtitlePTS - expectedPTS) * 1000.0
        }

        // Calculate Quality Score
        var score: Double = 100.0
        for defect in defects {
            score -= defect.isCritical ? 20.0 : 5.0
        }
        let qualityScore = max(0.0, min(100.0, score))

        let totalDuration = cues.last?.endTimeSeconds ?? 0.0
        let isSyncSafe = !defects.contains(where: \.isCritical)

        return WebVTTTrackReport(
            cueCount: cues.count,
            totalDurationSeconds: totalDuration,
            header: header,
            hasTimestampMap: header.mpegtsOffset != nil,
            mpegtsOffsetPTS: header.mpegtsOffset,
            syncDriftMs: syncDriftMs,
            defects: defects,
            cues: cues,
            qualityScore: qualityScore,
            isSyncSafe: isSyncSafe
        )
    }

    // MARK: - Timestamp Parsing

    static func parseTimestamp(_ str: String) -> Double? {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        let mainParts = trimmed.components(separatedBy: ":")
        guard !mainParts.isEmpty else { return nil }

        if mainParts.count == 3 {
            // HH:MM:SS.mmm
            guard let h = Double(mainParts[0]), let m = Double(mainParts[1]), let s = Double(mainParts[2]) else { return nil }
            return (h * 3600.0) + (m * 60.0) + s
        } else if mainParts.count == 2 {
            // MM:SS.mmm
            guard let m = Double(mainParts[0]), let s = Double(mainParts[1]) else { return nil }
            return (m * 60.0) + s
        }
        return nil
    }

    // MARK: - Header Parsing

    private static func parseTimestampMap(_ line: String, into header: inout WebVTTHeader) {
        // e.g. X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000
        let parts = line.replacingOccurrences(of: "X-TIMESTAMP-MAP=", with: "").components(separatedBy: ",")
        for part in parts {
            let kv = part.components(separatedBy: ":")
            if kv.count >= 2 {
                let key = kv[0].trimmingCharacters(in: .whitespaces).uppercased()
                let val = kv.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                if key == "MPEGTS", let num = Int(val) {
                    header.mpegtsOffset = num
                } else if key == "LOCAL" {
                    header.localOffsetSeconds = parseTimestamp(val) ?? 0.0
                }
            }
        }
    }

    // MARK: - Defect Validation

    private static func auditDefects(
        cues: [WebVTTCue],
        header: WebVTTHeader,
        isHlsSegment: Bool,
        videoPTSOffsetSeconds: Double?
    ) -> [WebVTTDefect] {
        var defects: [WebVTTDefect] = []

        // 1. Missing X-TIMESTAMP-MAP in HLS Segment
        if isHlsSegment && header.mpegtsOffset == nil {
            defects.append(.missingTimestampMapHeader)
        }

        // 2. Video Sync Drift Check
        if let videoPTS = videoPTSOffsetSeconds, let mpegts = header.mpegtsOffset {
            let subtitleStartPTS = Double(mpegts) / 90000.0
            let drift = abs(subtitleStartPTS - videoPTS) * 1000.0
            if drift > 150.0 {
                defects.append(
                    .syncDriftFromVideo(
                        driftMs: (subtitleStartPTS - videoPTS) * 1000.0,
                        expectedPtsSeconds: videoPTS,
                        actualCueStartSeconds: subtitleStartPTS
                    )
                )
            }
        }

        for (idx, cue) in cues.enumerated() {
            // 3. Zero or Negative Duration
            if cue.durationSeconds <= 0.0 {
                defects.append(
                    .zeroOrNegativeDuration(
                        cueIndex: idx,
                        durationMs: (cue.endTimeSeconds - cue.startTimeSeconds) * 1000.0
                    )
                )
            }

            // 4. Excessive Duration (> 8.0s)
            if cue.durationSeconds > 8.0 {
                defects.append(
                    .excessiveDuration(
                        cueIndex: idx,
                        durationSeconds: cue.durationSeconds
                    )
                )
            }

            // 5. Overlapping Cues
            if idx > 0 {
                let prev = cues[idx - 1]
                if cue.startTimeSeconds < (prev.endTimeSeconds - 0.005) {
                    let overlap = (prev.endTimeSeconds - cue.startTimeSeconds) * 1000.0
                    defects.append(
                        .overlappingCues(
                            cueIndexA: idx - 1,
                            cueIndexB: idx,
                            overlapMs: overlap
                        )
                    )
                }
            }

            // 6. Broadcast Line Length Violation (> 42 characters)
            for line in cue.lines {
                let cleanLine = stripHTMLTags(line)
                if cleanLine.count > 42 {
                    defects.append(
                        .excessiveLineLength(
                            cueIndex: idx,
                            maxChars: cleanLine.count,
                            limit: 42
                        )
                    )
                    break
                }
            }

            // 7. Excessive Line Count (> 3 lines)
            if cue.lines.count > 3 {
                defects.append(
                    .excessiveLineCount(
                        cueIndex: idx,
                        count: cue.lines.count,
                        limit: 3
                    )
                )
            }

            // 8. Empty Cue Payload
            let strippedText = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if strippedText.isEmpty {
                defects.append(.emptyCuePayload(cueIndex: idx))
            }

            // 9. Unclosed or Malformed Tags
            if let tag = detectUnclosedTags(cue.text) {
                defects.append(.unclosedOrMalformedTag(cueIndex: idx, tag: tag))
            }

            // 10. Character Encoding Issues (mojibake)
            if let snippet = detectMojibake(cue.text) {
                defects.append(.characterEncodingIssue(cueIndex: idx, snippet: snippet))
            }
        }

        return defects
    }

    private static func stripHTMLTags(_ str: String) -> String {
        str.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private static func detectUnclosedTags(_ text: String) -> String? {
        let tagTypes = ["i", "b", "u", "c", "v", "ruby", "rt", "lang"]
        for tag in tagTypes {
            let openCount = text.components(separatedBy: "<\(tag)").count - 1
            let closeCount = text.components(separatedBy: "</\(tag)>").count - 1
            if openCount > closeCount {
                return "<\(tag)> without closing </\(tag)>"
            }
        }
        return nil
    }

    private static func detectMojibake(_ text: String) -> String? {
        if text.contains("\u{FFFD}") {
            return "Unicode Replacement Character (U+FFFD)"
        }
        let suspiciousPatterns = ["Ã©", "Ã¨", "Ã ", "Ã¢", "Ã®", "Ã´", "Ã»", "â€™", "â€œ", "â€", "â€“"]
        for pattern in suspiciousPatterns {
            if text.contains(pattern) {
                return pattern
            }
        }
        return nil
    }
}
