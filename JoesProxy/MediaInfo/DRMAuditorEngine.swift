//
//  DRMAuditorEngine.swift
//  JoesProxy
//
//  Parser and auditor for DRM license exchanges, #EXT-X-KEY Content IDs,
//  PSSH box metadata, and handshake defect validation.
//

import Foundation

enum DRMAuditorEngine {

    /// Audits DRM configuration and license transactions across manifest, license, and media sessions.
    static func audit(
        manifestSessions: [SessionRecord] = [],
        licenseSessions: [SessionRecord] = [],
        mediaSessions: [SessionRecord] = []
    ) -> DRMAuditReport {
        var detectedKeyInfo: DRMKeyInfo? = nil
        var psshBoxes: [PSSHBoxInfo] = []
        var exchanges: [DRMLicenseExchange] = []
        var defects: [DRMHandshakeDefect] = []
        var totalLatencySeconds: Double = 0.0

        // 1. Inspect Manifests for #EXT-X-KEY
        for session in manifestSessions {
            if let bodyData = session.response?.bodyData, let text = String(data: bodyData, encoding: .utf8) {
                if let keyInfo = extractKeyInfo(from: text) {
                    detectedKeyInfo = keyInfo
                    break
                }
            }
        }

        // 2. Inspect Binary Media / Init Segments for PSSH Boxes
        for session in mediaSessions {
            if let bodyData = session.response?.bodyData, !bodyData.isEmpty {
                let boxes = extractPSSHBoxes(from: bodyData)
                if !boxes.isEmpty {
                    psshBoxes.append(contentsOf: boxes)
                }
            }
        }

        // 3. Inspect DRM License Exchange Sessions
        for session in licenseSessions {
            if let exchange = auditLicenseSession(session, defects: &defects) {
                exchanges.append(exchange)
                totalLatencySeconds += exchange.durationSeconds
            }
        }

        // 4. Determine Active DRM System
        var activeSystem: DRMSystem = .unknown("Unspecified")
        if let keyInfo = detectedKeyInfo {
            if let kf = keyInfo.keyFormat {
                activeSystem = DRMSystem.from(systemID: kf)
            } else if let uri = keyInfo.uri, uri.contains("skd://") {
                activeSystem = .fairPlay
            }
        } else if let firstBox = psshBoxes.first {
            activeSystem = DRMSystem.from(systemID: firstBox.systemID)
        } else if let firstEx = exchanges.first {
            activeSystem = firstEx.drmSystem
        }

        // 5. Cross-Reference Manifest Content ID with License Exchange Content IDs
        if let manifestCID = detectedKeyInfo?.contentID, !manifestCID.isEmpty {
            for exchange in exchanges {
                if let licCID = exchange.contentID, !licCID.isEmpty, licCID != manifestCID {
                    defects.append(.contentIDMismatch(manifestContentID: manifestCID, licenseContentID: licCID))
                }
            }
        }

        // 6. Check for Missing IV in SAMPLE-AES
        if let key = detectedKeyInfo, key.method == "SAMPLE-AES", key.iv == nil {
            defects.append(.missingIVForSampleAES)
        }

        // 7. Check for Missing PSSH in CENC Encrypted Assets
        if let key = detectedKeyInfo, (key.method == "SAMPLE-AES-CTR" || key.keyFormat?.contains("urn:uuid:edef8ba9") == true), psshBoxes.isEmpty, !mediaSessions.isEmpty {
            defects.append(.missingPsshInEncryptedAsset)
        }

        // Calculate Quality Score
        var score: Double = 100.0
        for defect in defects {
            score -= defect.isCritical ? 25.0 : 10.0
        }
        let qualityScore = max(0.0, min(100.0, score))

        let avgLatencyMs = exchanges.isEmpty ? nil : (totalLatencySeconds / Double(exchanges.count)) * 1000.0
        let isHealthy = !defects.contains(where: \.isCritical)

        return DRMAuditReport(
            drmSystem: activeSystem,
            keyInfo: detectedKeyInfo,
            psshBoxes: psshBoxes,
            licenseExchanges: exchanges,
            defects: defects,
            handshakeLatencyMs: avgLatencyMs,
            qualityScore: qualityScore,
            isHandshakeHealthy: isHealthy
        )
    }

    // MARK: - Manifest #EXT-X-KEY Parsing

    static func extractKeyInfo(from manifestText: String) -> DRMKeyInfo? {
        let lines = manifestText.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXT-X-KEY:") {
                return parseKeyTag(trimmed)
            }
        }
        return nil
    }

    private static func parseKeyTag(_ tag: String) -> DRMKeyInfo {
        let attributes = tag.replacingOccurrences(of: "#EXT-X-KEY:", with: "")
        var method = "UNKNOWN"
        var keyFormat: String? = nil
        var uri: String? = nil
        var iv: String? = nil
        var contentID: String? = nil

        let pairs = parseAttributeList(attributes)
        for (key, val) in pairs {
            let uKey = key.uppercased()
            let cleanVal = val.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            switch uKey {
            case "METHOD":
                method = cleanVal
            case "KEYFORMAT":
                keyFormat = cleanVal
            case "URI":
                uri = cleanVal
                if cleanVal.hasPrefix("skd://") {
                    contentID = extractContentIDFromSKD(cleanVal)
                }
            case "IV":
                iv = cleanVal
            case "KEYID":
                contentID = cleanVal
            default:
                break
            }
        }

        return DRMKeyInfo(
            method: method,
            keyFormat: keyFormat,
            contentID: contentID,
            uri: uri,
            iv: iv,
            keyID: contentID
        )
    }

    private static func extractContentIDFromSKD(_ skdURI: String) -> String {
        let clean = skdURI.replacingOccurrences(of: "skd://", with: "")
        if let last = clean.components(separatedBy: "/").last, !last.isEmpty {
            return last
        }
        return clean
    }

    private static func parseAttributeList(_ attrString: String) -> [(String, String)] {
        var results: [(String, String)] = []
        var currentKey = ""
        var currentVal = ""
        var inQuotes = false
        var readingValue = false

        for char in attrString {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "=" && !inQuotes && !readingValue {
                readingValue = true
                continue
            } else if char == "," && !inQuotes {
                if !currentKey.isEmpty {
                    results.append((currentKey.trimmingCharacters(in: .whitespaces), currentVal.trimmingCharacters(in: .whitespaces)))
                }
                currentKey = ""
                currentVal = ""
                readingValue = false
                continue
            }

            if readingValue {
                currentVal.append(char)
            } else {
                currentKey.append(char)
            }
        }

        if !currentKey.isEmpty {
            results.append((currentKey.trimmingCharacters(in: .whitespaces), currentVal.trimmingCharacters(in: .whitespaces)))
        }

        return results
    }

    // MARK: - PSSH Box Extraction (ISO Base Media File Format)

    static func extractPSSHBoxes(from data: Data) -> [PSSHBoxInfo] {
        var boxes: [PSSHBoxInfo] = []
        var offset = 0
        let count = data.count

        while offset + 8 <= count {
            let size = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            guard size >= 8, offset + size <= count else { break }

            let typeData = data.subdata(in: (offset + 4)..<(offset + 8))
            let fourCC = String(data: typeData, encoding: .isoLatin1) ?? ""

            if fourCC == "pssh" && size >= 32 {
                let psshPayload = data.subdata(in: (offset + 8)..<(offset + size))
                if let psshInfo = parsePSSHPayload(psshPayload, boxSize: size) {
                    boxes.append(psshInfo)
                }
            }

            offset += size
        }

        return boxes
    }

    private static func parsePSSHPayload(_ payload: Data, boxSize: Int) -> PSSHBoxInfo? {
        guard payload.count >= 24 else { return nil }

        let version = Int(payload[0])
        // Flags: payload[1...3]
        let systemIDBytes = payload.subdata(in: 4..<20)
        let systemIDHex = systemIDBytes.map { String(format: "%02x", $0) }.joined()
        let formattedGUID = formatGUID(systemIDHex)
        let drmSystem = DRMSystem.from(systemID: formattedGUID)

        var keyIDs: [String] = []
        var curOffset = 20

        if version > 0 && payload.count >= curOffset + 4 {
            let kidCount = Int(payload[curOffset]) << 24 | Int(payload[curOffset + 1]) << 16 | Int(payload[curOffset + 2]) << 8 | Int(payload[curOffset + 3])
            curOffset += 4
            for _ in 0..<min(kidCount, 8) {
                if curOffset + 16 <= payload.count {
                    let kidBytes = payload.subdata(in: curOffset..<(curOffset + 16))
                    keyIDs.append(formatGUID(kidBytes.map { String(format: "%02x", $0) }.joined()))
                    curOffset += 16
                }
            }
        }

        return PSSHBoxInfo(
            systemID: formattedGUID,
            systemName: drmSystem.shortName,
            version: version,
            keyIDs: keyIDs,
            dataSize: boxSize
        )
    }

    private static func formatGUID(_ hex: String) -> String {
        guard hex.count == 32 else { return hex }
        let p1 = hex.prefix(8)
        let p2 = hex.dropFirst(8).prefix(4)
        let p3 = hex.dropFirst(12).prefix(4)
        let p4 = hex.dropFirst(16).prefix(4)
        let p5 = hex.dropFirst(20).prefix(12)
        return "\(p1)-\(p2)-\(p3)-\(p4)-\(p5)"
    }

    // MARK: - License Session Auditing

    private static func auditLicenseSession(_ session: SessionRecord, defects: inout [DRMHandshakeDefect]) -> DRMLicenseExchange? {
        let urlStr = MediaDetector.absoluteURL(for: session.request)?.absoluteString ?? session.request.path
        let isHTTPS = urlStr.lowercased().hasPrefix("https://")

        // 1. Insecure transport check
        if !isHTTPS {
            defects.append(.insecureTransport(url: urlStr))
        }

        // 2. Authorization header check
        let hasAuth = session.request.headers.contains(where: {
            let name = $0.name.lowercased()
            return name == "authorization" || name.contains("token") || name.contains("custom-data")
        })
        if !hasAuth {
            defects.append(.missingAuthorizationHeader(url: urlStr))
        }

        // 3. Latency check (> 1,500ms)
        let duration = session.timing.duration ?? 0.0
        let latencyMs = duration * 1000.0
        if latencyMs > 1500.0 {
            defects.append(.excessiveLicenseLatency(latencyMs: latencyMs, thresholdMs: 1500.0))
        }

        // 4. HTTP 200 masked error check
        if let statusCode = session.response?.statusCode, statusCode == 200, let bodyData = session.response?.bodyData {
            if let text = String(data: bodyData, encoding: .utf8), text.contains("\"error\"") || text.contains("\"errorCode\"") || text.contains("\"status\":\"error\"") {
                defects.append(.http200ErrorEnvelope(message: "License response contained error JSON body with HTTP 200 OK"))
            }
        }

        // Extract content ID if present in query parameters
        var contentID: String? = nil
        if let query = URLComponents(string: urlStr)?.queryItems {
            contentID = query.first(where: {
                let n = $0.name.lowercased()
                return n == "contentid" || n == "content_id" || n == "kid" || n == "assetid"
            })?.value
        }

        let drmSystem = DRMSystem.from(systemID: urlStr)

        return DRMLicenseExchange(
            id: session.id.uuidString,
            requestURL: urlStr,
            drmSystem: drmSystem,
            requestMethod: session.request.method,
            statusCode: session.response?.statusCode ?? 0,
            durationSeconds: duration,
            contentID: contentID,
            hasAuthToken: hasAuth,
            isHTTPS: isHTTPS
        )
    }
}
