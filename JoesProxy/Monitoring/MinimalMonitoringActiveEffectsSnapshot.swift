import Foundation

/// Every currently-applied mechanism that can make a proxied request/response differ from what the
/// real upstream would have returned, or change which network a Mac's own traffic reaches — the
/// full picture, not a hand-picked subset. Origin-agnostic: counts a rule whether a person created
/// it in the UI or an MCP client proposed and had it approved; this is not the MCP-only effect
/// journal (`MCPEffectInventoryBuilder`) used for agent cleanup/attribution, which deliberately
/// excludes human-authored rules.
///
/// Matches `MinimalMonitoringSnapshot`'s own "aggregate-only, already maintained elsewhere"
/// contract — see `memlog/Research/ADR-Minimal-Monitoring-Mode.md` §2a. Adding a mechanism here
/// means adding a field here and a case in `MinimalMonitoringViewModel.rawActiveEffectsDescriptors`,
/// the same two-step extension the ADR already describes for the main tile set.
struct TrafficModificationSnapshot: Equatable, Sendable {
    /// Enabled `ResponseOverrideRule`s whose `sourceKind` serves a local response
    /// (`capturedResponse`/`inlineText`/`localFile`/`fixtureRun`/`localDirectory`) —
    /// `MCPEffectInventoryBuilder.effectKind(for:) == .mapLocal`.
    var activeMapLocalCount: Int
    /// Enabled `ResponseOverrideRule`s with `sourceKind == .mapRemote`.
    var activeMapRemoteCount: Int
    /// Enabled `ResponseOverrideRule`s with `sourceKind == .block`.
    var activeBlockCount: Int
    /// Enabled bookmark response-field rewrites (`Bookmark.responseRewrites`), across all bookmarks.
    var activeBookmarkRewriteCount: Int
    /// Enabled `ResponseOverrideRule`s with `sourceKind == .liveResponseRewrite`.
    var activeLiveRewriteCount: Int
    var isThrottlingEnabled: Bool
    /// Active `HLSSubstitutionExperiment`s (`isActive`) — a distinct list from `responseOverrides`,
    /// not a subset of the Map Local count above.
    var activeHLSSubstitutionCount: Int
    /// `OpenAPIMockPack`s currently `isServing`.
    var activeOpenAPIMockPackCount: Int
    /// Enabled plans registered with `SyntheticCollectionInjectionEngine` — JSON collection items
    /// injected into live responses independent of any `ResponseOverrideRule`.
    var activeSyntheticInjectionCount: Int
    /// The live state of macOS's system-wide network proxy actually pointing at JoesProxy right
    /// now (`SystemProxyController.status == .active`) — not just the "management enabled"
    /// preference, which can be on while routing itself is inactive/pending.
    var isSystemProxyTunnelingActive: Bool

    static let empty = TrafficModificationSnapshot(
        activeMapLocalCount: 0,
        activeMapRemoteCount: 0,
        activeBlockCount: 0,
        activeBookmarkRewriteCount: 0,
        activeLiveRewriteCount: 0,
        isThrottlingEnabled: false,
        activeHLSSubstitutionCount: 0,
        activeOpenAPIMockPackCount: 0,
        activeSyntheticInjectionCount: 0,
        isSystemProxyTunnelingActive: false
    )

    /// Excludes system routing: routing changes where traffic flows, but does not alter the
    /// response and must remain active during an emergency return-to-pass-through action.
    var activeModificationCount: Int {
        activeMapLocalCount + activeMapRemoteCount + activeBlockCount +
        activeBookmarkRewriteCount + activeLiveRewriteCount +
        (isThrottlingEnabled ? 1 : 0) + activeHLSSubstitutionCount +
        activeOpenAPIMockPackCount + activeSyntheticInjectionCount
    }
}

typealias MinimalMonitoringActiveEffectsSnapshot = TrafficModificationSnapshot

struct TrafficModificationResetResult: Equatable, Sendable {
    let disabledCount: Int
    let remainingCount: Int

    var isComplete: Bool { remainingCount == 0 }
}
