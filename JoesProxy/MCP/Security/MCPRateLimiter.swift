import CryptoKit
import Foundation

enum MCPRequestRateClass: Sendable, Equatable {
    case substantive
    case controlPlane
}

enum MCPRequestRateClassifier {
    private static let controlPlaneTools: Set<String> = [
        "approval_status",
        "approvals_list",
        "client_cleanup_status",
        "operation_status",
        "runtime_status"
    ]

    static func rateClass(httpMethod: String, body: Data) -> MCPRequestRateClass {
        guard httpMethod == "POST",
              let parsed = try? MCPJSONParsing.parseJSONObject(from: body),
              let object = parsed as? [String: Any],
              let rpcMethod = object["method"] as? String else {
            return .substantive
        }
        switch rpcMethod {
        case "initialize", "notifications/initialized", "tools/list", "resources/list",
             "resources/subscribe", "resources/unsubscribe", "prompts/list", "prompts/get":
            return .controlPlane
        case "resources/read":
            let params = object["params"] as? [String: Any]
            return params?["uri"] as? String == "joesproxy://server/status"
                ? .controlPlane
                : .substantive
        case "tools/call":
            let params = object["params"] as? [String: Any]
            let name = params?["name"] as? String
            return name.map(controlPlaneTools.contains) == true ? .controlPlane : .substantive
        default:
            return .substantive
        }
    }
}

/// Pre-auth and post-auth rate-limit buckets for MCP transport requests.
struct MCPRateLimiter: Sendable {
    struct Configuration: Sendable {
        var globalRequestsPerMinute = MCPServerLimits.globalRequestRatePerMinute
        var clientRequestsPerMinute = MCPServerLimits.requestRatePerClientPerMinute
        var controlPlaneGlobalRequestsPerMinute = MCPServerLimits.controlPlaneGlobalRequestRatePerMinute
        var controlPlaneClientRequestsPerMinute = MCPServerLimits.controlPlaneRequestRatePerClientPerMinute
        var window: TimeInterval = 60
    }

    private struct Bucket {
        var timestamps: [Date] = []
        var lastSeen: Date = .distantPast
    }

    /// Upper bound on distinct tracked fingerprints/clients. `fingerprintBuckets` is keyed by a
    /// hash of whatever bearer token a caller sends, *before* authentication succeeds — without a
    /// cap, a client (or attacker) sending many distinct bogus tokens grows this dictionary without
    /// bound even though each individual bucket is itself rate-limited.
    private static let maxTrackedFingerprints = 2_048
    private static let maxTrackedClients = 512

    private var globalBucket = Bucket()
    private var controlPlaneGlobalBucket = Bucket()
    private var clientBuckets: [String: Bucket] = [:]
    private var controlPlaneClientBuckets: [String: Bucket] = [:]
    private var fingerprintBuckets: [String: Bucket] = [:]
    private var controlPlaneFingerprintBuckets: [String: Bucket] = [:]
    private let configuration: Configuration
    private let now: @Sendable () -> Date

    init(
        configuration: Configuration = Configuration(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.now = now
    }

    var activeConfiguration: Configuration { configuration }

    mutating func allowGlobalRequest(
        rateClass: MCPRequestRateClass = .substantive,
        at suppliedDate: Date? = nil
    ) -> Bool {
        let date = suppliedDate ?? now()
        var bucket = rateClass == .controlPlane ? controlPlaneGlobalBucket : globalBucket
        let limit = rateClass == .controlPlane
            ? configuration.controlPlaneGlobalRequestsPerMinute
            : configuration.globalRequestsPerMinute
        let allowed = allowRequest(in: &bucket, limit: limit, at: date)
        bucket.lastSeen = date
        if rateClass == .controlPlane {
            controlPlaneGlobalBucket = bucket
        } else {
            globalBucket = bucket
        }
        return allowed
    }

    mutating func allowClientRequest(
        clientID: String,
        rateClass: MCPRequestRateClass = .substantive,
        at suppliedDate: Date? = nil
    ) -> Bool {
        let date = suppliedDate ?? now()
        var buckets = rateClass == .controlPlane ? controlPlaneClientBuckets : clientBuckets
        evictStaleBuckets(in: &buckets, cap: Self.maxTrackedClients, at: date)
        var bucket = buckets[clientID, default: Bucket()]
        let limit = rateClass == .controlPlane
            ? configuration.controlPlaneClientRequestsPerMinute
            : configuration.clientRequestsPerMinute
        let allowed = allowRequest(in: &bucket, limit: limit, at: date)
        bucket.lastSeen = date
        buckets[clientID] = bucket
        if rateClass == .controlPlane {
            controlPlaneClientBuckets = buckets
        } else {
            clientBuckets = buckets
        }
        return allowed
    }

    mutating func allowFingerprintRequest(
        _ fingerprint: String,
        rateClass: MCPRequestRateClass = .substantive,
        at suppliedDate: Date? = nil
    ) -> Bool {
        let date = suppliedDate ?? now()
        var buckets = rateClass == .controlPlane ? controlPlaneFingerprintBuckets : fingerprintBuckets
        evictStaleBuckets(in: &buckets, cap: Self.maxTrackedFingerprints, at: date)
        var bucket = buckets[fingerprint, default: Bucket()]
        let limit = rateClass == .controlPlane
            ? configuration.controlPlaneClientRequestsPerMinute
            : configuration.clientRequestsPerMinute
        let allowed = allowRequest(in: &bucket, limit: limit, at: date)
        bucket.lastSeen = date
        buckets[fingerprint] = bucket
        if rateClass == .controlPlane {
            controlPlaneFingerprintBuckets = buckets
        } else {
            fingerprintBuckets = buckets
        }
        return allowed
    }

    static func fingerprint(for bearerToken: String) -> String {
        let digest = SHA256.hash(data: Data(bearerToken.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private mutating func allowRequest(in bucket: inout Bucket, limit: Int, at date: Date) -> Bool {
        let cutoff = date.addingTimeInterval(-configuration.window)
        bucket.timestamps.removeAll { $0 < cutoff }
        guard bucket.timestamps.count < limit else { return false }
        bucket.timestamps.append(date)
        return true
    }

    /// Drops buckets that have had no activity within the rate-limit window — pure memory overhead
    /// once idle — and, if still at capacity (a burst of many distinct keys within one window),
    /// evicts the least-recently-seen entries down to `cap` so the dictionary never grows without
    /// bound regardless of how many distinct fingerprints or clients are seen.
    private func evictStaleBuckets(in buckets: inout [String: Bucket], cap: Int, at date: Date) {
        let cutoff = date.addingTimeInterval(-configuration.window)
        buckets = buckets.filter { $0.value.lastSeen >= cutoff }
        guard buckets.count >= cap else { return }
        let overflow = buckets.count - cap + 1
        let staleKeys = buckets
            .sorted { $0.value.lastSeen < $1.value.lastSeen }
            .prefix(overflow)
            .map(\.key)
        for key in staleKeys {
            buckets.removeValue(forKey: key)
        }
    }
}
