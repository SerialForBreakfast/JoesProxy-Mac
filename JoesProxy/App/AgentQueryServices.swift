import Foundation

/// Canonical query owners, independent of selection, filtered rows and Inspector lifetime.
/// Consumers share these instances; this facade adds no indexes, caches or background work.
@MainActor
final class AgentQueryServices {
    let snapshots: MCPSessionSnapshotService
    let media: MCPMediaInspectionService

    init(sessionStore: any SessionStore) {
        let snapshots = MCPSessionSnapshotService(sessionStore: sessionStore)
        self.snapshots = snapshots
        self.media = MCPMediaInspectionService(sessionStore: sessionStore, snapshotService: snapshots)
    }
}
