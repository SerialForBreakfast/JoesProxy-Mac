import Foundation

enum MCPDisclosurePreviewError: Error, Equatable, Sendable {
    case sessionNotFound
    case policyUnavailable
}

/// Serializer-only disclosure preview for the management panel (ADR Disclosure Preview).
///
/// Concurrency: `@MainActor` because it reads ``MCPPolicyStore`` and ``MCPSessionSnapshotService``.
@MainActor
struct MCPDisclosurePreviewEngine {
    enum Source: Equatable, Sendable {
        case syntheticFixture
        case capturedSession(SessionRecord.ID)
    }

    /// Sidecar metadata describing what the serializer removed or partially redacted.
    struct Envelope: Equatable, Sendable {
        var clientID: String
        var clientDisplayName: String
        var profileID: MCPDisclosureProfileID
        var profileTitle: String
        var policyRevision: MCPPolicyRevision
        var captureEpoch: MCPCaptureEpoch
        var sourceLabel: String
        var removedFieldClasses: [String]
        var partiallyRedactedFieldClasses: [String]
        var bodyTruncated: Bool
        var estimatedJSONBytes: Int
        var generatedAt: Date
        var activeTemporaryGrants: [MCPClientCapabilityGrantSummary]
        var summary: MCPSessionSummaryDTO
    }

    let policyStore: MCPPolicyStore
    let grantStore: MCPClientGrantStore
    let snapshotService: MCPSessionSnapshotService
    private let serializer = MCPDisclosureSerializer()

    init(
        policyStore: MCPPolicyStore,
        grantStore: MCPClientGrantStore? = nil,
        snapshotService: MCPSessionSnapshotService
    ) {
        self.policyStore = policyStore
        self.grantStore = grantStore ?? MCPClientGrantStore()
        self.snapshotService = snapshotService
    }

    func preview(client: MCPClientRecord, source: Source) throws -> Envelope {
        guard policyStore.isLoaded else {
            throw MCPDisclosurePreviewError.policyUnavailable
        }
        let profile = try policyStore.resolvedProfile(for: client.assignedProfileID)
        let record: SessionRecord
        let captureSequence: UInt64
        let sourceLabel: String

        switch source {
        case .syntheticFixture:
            record = Self.adversarialFixture()
            captureSequence = 42
            sourceLabel = "Synthetic adversarial fixture"
        case .capturedSession(let sessionID):
            guard let indexed = snapshotService.indexedSession(id: sessionID) else {
                throw MCPDisclosurePreviewError.sessionNotFound
            }
            record = indexed.record
            captureSequence = indexed.captureSequence
            sourceLabel = "Captured session \(sessionID.uuidString.prefix(8))…"
        }

        let summary = try serializer.sessionSummary(
            record: record,
            captureSequence: captureSequence,
            profile: profile
        )
        let encoded = try JSONEncoder().encode(summary)
        let removed = MCPPolicyFieldClass.allCases
            .filter { !profile.allowedFieldClasses.contains($0) }
            .map(\.rawValue)
            .sorted()
        let partiallyRedacted = Self.partiallyRedactedFieldClasses(summary: summary, profile: profile)
        let bodyTruncated = summary.bodyTruncated ?? false

        return Envelope(
            clientID: client.id,
            clientDisplayName: client.displayName,
            profileID: profile.id,
            profileTitle: profile.title,
            policyRevision: policyStore.policyRevision,
            captureEpoch: snapshotService.captureEpoch,
            sourceLabel: sourceLabel,
            removedFieldClasses: removed,
            partiallyRedactedFieldClasses: partiallyRedacted,
            bodyTruncated: bodyTruncated,
            estimatedJSONBytes: encoded.count,
            generatedAt: Date(),
            activeTemporaryGrants: grantStore.summaries(for: client.id),
            summary: summary
        )
    }

    private static func partiallyRedactedFieldClasses(
        summary: MCPSessionSummaryDTO,
        profile: MCPDisclosureProfileDocument
    ) -> [String] {
        var fields: [String] = []
        if profile.allowedFieldClasses.contains(.sanitizedHost),
           summary.sanitizedHost?.contains("<redacted>") == true {
            fields.append(MCPPolicyFieldClass.sanitizedHost.rawValue)
        }
        if profile.allowedFieldClasses.contains(.sanitizedPath),
           summary.sanitizedPath?.contains("<redacted>") == true {
            fields.append(MCPPolicyFieldClass.sanitizedPath.rawValue)
        }
        if profile.allowedFieldClasses.contains(.safeHeaders),
           summary.safeHeaders?.contains(where: { $0.redactedValue == "<redacted>" }) == true {
            fields.append(MCPPolicyFieldClass.safeHeaders.rawValue)
        }
        return fields.sorted()
    }

    /// Adversarial fixture with sensitive headers, opaque path segments, and truncated bodies.
    static func adversarialFixture() -> SessionRecord {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        return SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "api.example.com",
                port: 443,
                path: "/reset/confirm/\(jwt)?token=abc",
                headers: [
                    HTTPHeaderField(name: "Authorization", value: "Bearer secret"),
                    HTTPHeaderField(name: "Accept", value: "application/json"),
                    HTTPHeaderField(name: "X-Trace-Id", value: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6")
                ],
                bodyData: Data(repeating: 0x41, count: 512),
                bodySize: 512,
                bodyTruncated: true
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            state: .completed,
            timing: SessionTiming(
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                completedAt: Date(timeIntervalSince1970: 1_700_000_001)
            )
        )
    }
}
