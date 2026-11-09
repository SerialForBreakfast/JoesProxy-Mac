//
//  CMCDEngine.swift
//  JoesProxy
//
//  Parser and validator for CTA-5004 CMCD and CTA-5006 CMSD media telemetry.
//

import Foundation

enum CMCDEngine {

    /// Parses CMCD and CMSD telemetry from HTTP request/response headers and query strings.
    static func parse(
        requestHeaders: [HTTPHeaderField],
        responseHeaders: [HTTPHeaderField] = [],
        urlString: String,
        responseDurationSeconds: Double? = nil,
        sessionID: UUID = UUID()
    ) -> CMCDSessionReport? {
        var cmcd = CMCDTelemetry()
        var hasHeaders = false
        var hasQuery = false

        // 1. Parse Request Headers
        for header in requestHeaders {
            let name = header.name.lowercased()
            if name == "cmcd-request" || name == "cmcd-object" || name == "cmcd-status" || name == "cmcd-session" {
                hasHeaders = true
                parseStructuredField(header.value, into: &cmcd)
            }
        }

        // 2. Parse URL Query Parameters
        if let url = URL(string: urlString), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let queryItems = components.queryItems ?? []
            for item in queryItems {
                let name = item.name.lowercased()
                if name == "cmcd" {
                    hasQuery = true
                    if let val = item.value {
                        parseStructuredField(val, into: &cmcd)
                    }
                } else if name == "cmcd-request" || name == "cmcd-object" || name == "cmcd-status" || name == "cmcd-session" {
                    hasQuery = true
                    if let val = item.value {
                        parseStructuredField(val, into: &cmcd)
                    }
                } else if isCMCDKey(name) {
                    hasQuery = true
                    parseSingleKeyValue(key: name, value: item.value, into: &cmcd)
                }
            }
        }

        if cmcd.isEmpty {
            return nil
        }

        let transportMethod: CMCDTransportMethod
        if hasHeaders && hasQuery {
            transportMethod = .mixed
        } else if hasHeaders {
            transportMethod = .header
        } else {
            transportMethod = .queryString
        }

        // 3. Parse CMSD Response Headers
        var cmsd = CMSDTelemetry()
        for header in responseHeaders {
            let name = header.name.lowercased()
            if name == "cmsd-static" || name == "cmsd-dynamic" {
                parseCMSDStructuredField(header.value, into: &cmsd)
            }
        }
        let cmsdOptional = cmsd.isEmpty ? nil : cmsd

        // 4. Run QoE Anomaly Evaluation
        let anomalies = evaluateAnomalies(
            cmcd: cmcd,
            responseDurationSeconds: responseDurationSeconds
        )

        // 5. Calculate Health Score
        var score: Double = 100.0
        for anomaly in anomalies {
            if anomaly.isCritical {
                score -= 30.0
            } else {
                score -= 10.0
            }
        }
        let healthScore = max(0.0, min(100.0, score))

        let path = URL(string: urlString)?.path ?? urlString

        return CMCDSessionReport(
            id: sessionID,
            requestPath: path,
            transportMethod: transportMethod,
            cmcd: cmcd,
            cmsd: cmsdOptional,
            anomalies: anomalies,
            healthScore: healthScore
        )
    }

    // MARK: - Structured Field Parsing

    private static func parseStructuredField(_ field: String, into cmcd: inout CMCDTelemetry) {
        // Split by commas, handling potential quoted strings
        let pairs = field.split(separator: ",")
        for pair in pairs {
            let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let val = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
            parseSingleKeyValue(key: key, value: val, into: &cmcd)
        }
    }

    private static func parseSingleKeyValue(key: String, value: String?, into cmcd: inout CMCDTelemetry) {
        let cleanKey = key.lowercased()
        let cleanVal: String?
        if let v = value {
            let stripped = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if stripped.hasPrefix("\"") && stripped.hasSuffix("\"") && stripped.count >= 2 {
                cleanVal = String(stripped.dropFirst().dropLast())
            } else {
                cleanVal = stripped
            }
        } else {
            cleanVal = nil
        }

        switch cleanKey {
        case "br":
            if let v = cleanVal, let num = Int(v) { cmcd.encodedBitrateKbps = num }
        case "d":
            if let v = cleanVal, let num = Int(v) { cmcd.objectDurationMs = num }
        case "ot":
            if let v = cleanVal, let type = CMCDObjectType(rawValue: v) { cmcd.objectType = type }
        case "tb":
            if let v = cleanVal, let num = Int(v) { cmcd.topBitrateKbps = num }
        case "bl":
            if let v = cleanVal, let num = Int(v) { cmcd.bufferLengthMs = num }
        case "dl":
            if let v = cleanVal, let num = Int(v) { cmcd.deadlineMs = num }
        case "mtp":
            if let v = cleanVal, let num = Int(v) { cmcd.measuredThroughputKbps = num }
        case "rtp":
            if let v = cleanVal, let num = Int(v) { cmcd.requestedThroughputKbps = num }
        case "bs":
            cmcd.bufferStarvation = cleanVal == nil || cleanVal == "true" || cleanVal == "1"
        case "su":
            cmcd.isStartup = cleanVal == nil || cleanVal == "true" || cleanVal == "1"
        case "nor":
            cmcd.nextObjectRequest = cleanVal
        case "nrr":
            cmcd.nextRangeRequest = cleanVal
        case "sid":
            cmcd.sessionID = cleanVal
        case "cid":
            cmcd.contentID = cleanVal
        case "pr":
            if let v = cleanVal, let num = Double(v) { cmcd.playbackRate = num }
        case "sf":
            if let v = cleanVal, let fmt = CMCDStreamingFormat(rawValue: v) { cmcd.streamingFormat = fmt }
        case "st":
            if let v = cleanVal, let type = CMCDStreamType(rawValue: v) { cmcd.streamType = type }
        case "v":
            if let v = cleanVal, let num = Int(v) { cmcd.version = num }
        default:
            cmcd.rawCustomKeys[key] = cleanVal ?? "true"
        }
    }

    private static func parseCMSDStructuredField(_ field: String, into cmsd: inout CMSDTelemetry) {
        let pairs = field.split(separator: ",")
        for pair in pairs {
            let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let val = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""

            switch key {
            case "etp":
                if let num = Int(val) { cmsd.estimatedThroughputKbps = num }
            case "rd":
                if let num = Int(val) { cmsd.responseDelayMs = num }
            case "rtt":
                if let num = Int(val) { cmsd.roundTripTimeMs = num }
            case "mb":
                if let num = Int(val) { cmsd.maxBitrateKbps = num }
            default:
                cmsd.rawCustomKeys[key] = val
            }
        }
    }

    private static func isCMCDKey(_ key: String) -> Bool {
        let standardKeys = ["br", "d", "ot", "tb", "bl", "dl", "mtp", "rtp", "bs", "su", "nor", "nrr", "sid", "cid", "pr", "sf", "st", "v"]
        return standardKeys.contains(key.lowercased())
    }

    // MARK: - Anomaly Evaluation

    private static func evaluateAnomalies(
        cmcd: CMCDTelemetry,
        responseDurationSeconds: Double?
    ) -> [CMCDQoEAnomaly] {
        var anomalies: [CMCDQoEAnomaly] = []

        // 1. Critical Buffer Drop (< 2,000ms safety threshold)
        if let bl = cmcd.bufferLengthMs, bl < 2000 {
            anomalies.append(.criticalBufferDrop(bufferLengthMs: bl, thresholdMs: 2000))
        }

        // 2. Throughput Underflow (measured throughput < requested segment bitrate)
        if let mtp = cmcd.measuredThroughputKbps, let br = cmcd.encodedBitrateKbps, mtp < br {
            anomalies.append(.throughputUnderflow(measuredThroughputKbps: mtp, requestedBitrateKbps: br))
        }

        // 3. Playback Starvation Reported
        if cmcd.bufferStarvation == true {
            anomalies.append(.playbackStarvationReported)
        }

        // 4. Deadline Missed
        if let dl = cmcd.deadlineMs, let dur = responseDurationSeconds {
            let actualMs = Int(dur * 1000.0)
            if actualMs > dl {
                anomalies.append(.deadlineMissed(deadlineMs: dl, actualDownloadTimeMs: actualMs))
            }
        }

        return anomalies
    }
}
