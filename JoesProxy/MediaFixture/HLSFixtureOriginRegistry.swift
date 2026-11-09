import Foundation

/// In-process registry of active HLS fixture runs, keyed by their reserved virtual-origin hostname
/// (e.g. `fixture-<runID>.hls.joesproxy.invalid`). `ProxyConnectionHandler` consults this before any
/// upstream/Map Local dispatch — the same "serve locally, never contact upstream" principle Map
/// Local already implements at `responseOverrideStore.ruleDecision(for:)`, just for an entire
/// fixture file tree plus a computed sliding playlist instead of one fixed body.
///
/// Owned and driven by `HLSFixtureRunStore` (P2-04), which registers/unregisters an
/// `HLSFixtureServer` here as runs start and stop. Empty (and therefore inert) until P2-04 lands.
actor HLSFixtureOriginRegistry {
    struct Entry {
        let runID: UUID
        let server: HLSFixtureServer
        let permitsDirectAccess: Bool
    }

    private var entriesByHost: [String: Entry] = [:]
    /// Second index onto the same entries, keyed by run ID instead of reserved host. Added for
    /// fixture-backed Map Local dispatch (`ProxyRuleDecision.fixtureRedirect`), which looks up a
    /// run by the ID a rule was authored against — the real request host is the app's own real
    /// external host, not the fixture's reserved host, so `activeEntry(forHost:)` cannot serve
    /// this lookup. Kept in exact sync with `entriesByHost` by `register`/`unregister`.
    private var entriesByRunID: [UUID: Entry] = [:]

    func register(host: String, runID: UUID, server: HLSFixtureServer, permitsDirectAccess: Bool = true) {
        let entry = Entry(runID: runID, server: server, permitsDirectAccess: permitsDirectAccess)
        entriesByHost[host.lowercased()] = entry
        entriesByRunID[runID] = entry
    }

    func unregister(host: String, runID: UUID) {
        entriesByHost.removeValue(forKey: host.lowercased())
        entriesByRunID.removeValue(forKey: runID)
    }

    func activeEntry(forHost host: String) -> Entry? {
        entriesByHost[host.lowercased()]
    }

    /// Looks up a live fixture entry by run ID, for fixture-backed Map Local dispatch against a
    /// real external host+path rather than the fixture's own reserved host.
    func activeEntry(forRunID runID: UUID) -> Entry? {
        entriesByRunID[runID]
    }
}
