import Foundation

/// Installs and removes scoped observation watches. AN-3 owns the real index; tests may stub this.
protocol DiagnosticRunWatchInstalling: AnyObject {
    /// Installs watches for every scope. Must be atomic from the caller's perspective: any throw
    /// after partial success is followed by `removeWatches` on the returned IDs.
    func installWatches(
        runID: DiagnosticRunID,
        ownerID: String,
        scopes: [DiagnosticRunScope]
    ) async throws -> [UUID]

    /// Removes previously installed watches. Idempotent.
    func removeWatches(_ watchIDs: [UUID]) async
}

/// Default installer: records successful installs without publishing observations.
@MainActor
final class NoOpDiagnosticRunWatchInstaller: DiagnosticRunWatchInstalling {
    private(set) var installed: [UUID: DiagnosticRunID] = [:]

    func installWatches(
        runID: DiagnosticRunID,
        ownerID: String,
        scopes: [DiagnosticRunScope]
    ) async throws -> [UUID] {
        _ = ownerID
        let ids = scopes.map { _ in UUID() }
        for id in ids {
            installed[id] = runID
        }
        return ids
    }

    func removeWatches(_ watchIDs: [UUID]) async {
        for id in watchIDs {
            installed.removeValue(forKey: id)
        }
    }
}

/// Live-state answer from an existing effect subsystem.
enum DiagnosticEffectLiveState: Equatable, Sendable {
    case notFound
    case inactive(ownerID: String?)
    case live(ownerID: String?)
}

/// Result of a risk-reducing stop/disable/cancel request.
struct DiagnosticCleanupActionResult: Equatable, Sendable {
    var cleaned: Bool
    var conflictReasonCode: String?
}

/// Resolves and cleans referenced effects without duplicating their stores (AN-2).
protocol DiagnosticRunEffectResolving: AnyObject {
    func liveState(
        kind: DiagnosticReferenceKind,
        opaqueID: String
    ) async -> DiagnosticEffectLiveState

    func requestRiskReducingCleanup(
        kind: DiagnosticReferenceKind,
        opaqueID: String,
        requestingOwnerID: String
    ) async -> DiagnosticCleanupActionResult
}

/// Default resolver: unknown effects are not found; evidence-only kinds are never live.
@MainActor
final class NoOpDiagnosticRunEffectResolver: DiagnosticRunEffectResolving {
    var states: [String: DiagnosticEffectLiveState] = [:]

    private func key(_ kind: DiagnosticReferenceKind, _ id: String) -> String {
        "\(kind.rawValue):\(id)"
    }

    func liveState(kind: DiagnosticReferenceKind, opaqueID: String) async -> DiagnosticEffectLiveState {
        switch kind {
        case .captureMarker, .proposal, .operation:
            return .inactive(ownerID: nil)
        case .overrideRule, .scenario, .fixtureRun, .hlsSubstitution, .openAPIMockPack:
            return states[key(kind, opaqueID)] ?? .notFound
        }
    }

    func requestRiskReducingCleanup(
        kind: DiagnosticReferenceKind,
        opaqueID: String,
        requestingOwnerID: String
    ) async -> DiagnosticCleanupActionResult {
        let state = await liveState(kind: kind, opaqueID: opaqueID)
        switch state {
        case .notFound, .inactive:
            return DiagnosticCleanupActionResult(cleaned: true, conflictReasonCode: nil)
        case .live(let ownerID):
            guard ownerID == nil || ownerID == requestingOwnerID else {
                return DiagnosticCleanupActionResult(cleaned: false, conflictReasonCode: "not_owner")
            }
            states[key(kind, opaqueID)] = .inactive(ownerID: ownerID)
            return DiagnosticCleanupActionResult(cleaned: true, conflictReasonCode: nil)
        }
    }
}
