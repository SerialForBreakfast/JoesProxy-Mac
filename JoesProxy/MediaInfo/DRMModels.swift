//
//  DRMModels.swift
//  JoesProxy
//
//  Domain models for FairPlay, Widevine, PlayReady, and ClearKey DRM
//  license exchanges, #EXT-X-KEY inspection, and PSSH box metadata.
//

import Foundation

/// Supported Digital Rights Management (DRM) system schemes.
enum DRMSystem: Codable, Equatable, Sendable {
    case fairPlay
    case widevine
    case playReady
    case clearKey
    case unknown(String)

    var title: String {
        switch self {
        case .fairPlay: return "FairPlay Streaming (Apple)"
        case .widevine: return "Widevine Modular (Google)"
        case .playReady: return "PlayReady (Microsoft)"
        case .clearKey: return "ClearKey (W3C EME)"
        case .unknown(let raw): return "DRM (\(raw))"
        }
    }

    var shortName: String {
        switch self {
        case .fairPlay: return "FairPlay"
        case .widevine: return "Widevine"
        case .playReady: return "PlayReady"
        case .clearKey: return "ClearKey"
        case .unknown(let raw): return raw
        }
    }

    var systemID: String {
        switch self {
        case .fairPlay: return "94ce86fb-07ff-4f43-adb8-93d2fa968ca2"
        case .widevine: return "edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"
        case .playReady: return "9a04f079-9840-4286-ab92-e65be0885f95"
        case .clearKey: return "e2719d58-a985-b3c9-781a-b030af78d30e"
        case .unknown(let raw): return raw
        }
    }

    static func from(systemID: String) -> DRMSystem {
        let clean = systemID.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.contains("edef8ba9") || clean.contains("widevine") {
            return .widevine
        } else if clean.contains("94ce86fb") || clean.contains("29701fe4") || clean.contains("fairplay") || clean.contains("streamingkeydelivery") {
            return .fairPlay
        } else if clean.contains("9a04f079") || clean.contains("playready") {
            return .playReady
        } else if clean.contains("e2719d58") || clean.contains("f239e769") || clean.contains("clearkey") {
            return .clearKey
        }
        return .unknown(systemID)
    }
}

/// Parsed DRM key parameters from manifest tags (e.g. #EXT-X-KEY).
struct DRMKeyInfo: Codable, Equatable, Sendable {
    var method: String // e.g. "SAMPLE-AES", "SAMPLE-AES-CTR", "AES-128"
    var keyFormat: String? // e.g. "com.apple.streamingkeydelivery", "urn:uuid:edef8ba9-..."
    var contentID: String? // e.g. "asset-9872" from skd://
    var uri: String?
    var iv: String?
    var keyID: String?
}

/// Extracted Common Encryption (CENC) PSSH (Protection System Specific Header) box.
struct PSSHBoxInfo: Identifiable, Codable, Equatable, Sendable {
    var id: String { "\(systemID)-\(keyIDs.joined(separator: ","))" }
    var systemID: String
    var systemName: String
    var version: Int
    var keyIDs: [String]
    var dataSize: Int
}

/// Captured DRM license or certificate exchange transaction.
struct DRMLicenseExchange: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var requestURL: String
    var drmSystem: DRMSystem
    var requestMethod: String
    var statusCode: Int
    var durationSeconds: Double
    var contentID: String?
    var hasAuthToken: Bool
    var isHTTPS: Bool
}

/// Defect or anomaly identified during DRM handshake validation.
enum DRMHandshakeDefect: Codable, Equatable, Sendable {
    case contentIDMismatch(manifestContentID: String, licenseContentID: String)
    case http200ErrorEnvelope(message: String)
    case insecureTransport(url: String)
    case missingAuthorizationHeader(url: String)
    case missingIVForSampleAES
    case excessiveLicenseLatency(latencyMs: Double, thresholdMs: Double)
    case missingPsshInEncryptedAsset

    var userFacingMessage: String {
        switch self {
        case .contentIDMismatch(let manifestID, let licenseID):
            return "Content ID mismatch: manifest requests '\(manifestID)' but license challenge requested '\(licenseID)'."
        case .http200ErrorEnvelope(let msg):
            return "Masked DRM error in HTTP 200 response: \(msg)."
        case .insecureTransport(let url):
            return "Insecure DRM key transport: cleartext HTTP used for '\(url)' (HTTPS is mandatory)."
        case .missingAuthorizationHeader(let url):
            return "Missing DRM authorization token: no Bearer or custom token header in license request to '\(url)'."
        case .missingIVForSampleAES:
            return "Missing Initialization Vector (IV): #EXT-X-KEY specifies SAMPLE-AES without an explicit IV."
        case .excessiveLicenseLatency(let latencyMs, let thresholdMs):
            return "High DRM license latency: acquisition took \(String(format: "%.0fms", latencyMs)) (threshold is \(String(format: "%.0fms", thresholdMs))), causing startup delay."
        case .missingPsshInEncryptedAsset:
            return "Missing PSSH box: asset uses CENC encryption but initialization segment contains no PSSH metadata."
        }
    }

    var isCritical: Bool {
        switch self {
        case .contentIDMismatch, .http200ErrorEnvelope, .insecureTransport, .missingAuthorizationHeader:
            return true
        case .missingIVForSampleAES, .excessiveLicenseLatency, .missingPsshInEncryptedAsset:
            return false
        }
    }
}

/// Comprehensive inspection report for DRM license exchange and key handshake.
struct DRMAuditReport: Codable, Equatable, Sendable {
    var drmSystem: DRMSystem
    var keyInfo: DRMKeyInfo?
    var psshBoxes: [PSSHBoxInfo]
    var licenseExchanges: [DRMLicenseExchange]
    var defects: [DRMHandshakeDefect]
    var handshakeLatencyMs: Double?
    var qualityScore: Double // 0 to 100
    var isHandshakeHealthy: Bool

    var criticalDefectsCount: Int {
        defects.filter(\.isCritical).count
    }
}
