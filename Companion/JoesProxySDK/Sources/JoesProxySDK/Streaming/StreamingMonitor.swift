import Foundation

/// Dispatches streaming-specific SDK events to registered handlers.
///
/// Obtain via `ProxySDK.shared.streamingMonitor`. Handlers are called on the main actor;
/// they are no-ops when `ProxySDK` is not connected.
///
/// All `StallRiskEvent` callbacks are heuristic signals — see `StallRiskEvent.recommendation`.
@MainActor
public final class StreamingMonitor: ObservableObject {
    public typealias SegmentHandler   = @Sendable (StreamingSegmentEvent) -> Void
    public typealias DRMHandler       = @Sendable (DRMLicenseEvent) -> Void
    public typealias ManifestHandler  = @Sendable (ManifestEvent) -> Void
    public typealias StallRiskHandler = @Sendable (StallRiskEvent) -> Void

    private var segmentHandlers:   [UUID: SegmentHandler]   = [:]
    private var drmHandlers:       [UUID: DRMHandler]       = [:]
    private var manifestHandlers:  [UUID: ManifestHandler]  = [:]
    private var stallRiskHandlers: [UUID: StallRiskHandler] = [:]

    /// Registers a handler called whenever a media segment delivery event arrives.
    /// Returns a handler ID that can be passed to `removeHandler(_:)`.
    @discardableResult
    public func onSegmentDelivered(_ handler: @escaping SegmentHandler) -> UUID {
        let id = UUID()
        segmentHandlers[id] = handler
        return id
    }

    /// Registers a handler called whenever a DRM license event arrives.
    /// `DRMLicenseEvent.relativeToPlaybackStartMs` is negative when the license
    /// precedes the `.markPlaybackStart()` marker — the common pre-fetch case.
    @discardableResult
    public func onDRMLicense(_ handler: @escaping DRMHandler) -> UUID {
        let id = UUID()
        drmHandlers[id] = handler
        return id
    }

    /// Registers a handler called whenever a manifest is fetched or refreshed.
    @discardableResult
    public func onManifestRefreshed(_ handler: @escaping ManifestHandler) -> UUID {
        let id = UUID()
        manifestHandlers[id] = handler
        return id
    }

    /// Registers a handler called when a heuristic stall-risk threshold is crossed.
    /// Always treat the event as best-effort — see `StallRiskEvent.recommendation`.
    @discardableResult
    public func onStallRisk(_ handler: @escaping StallRiskHandler) -> UUID {
        let id = UUID()
        stallRiskHandlers[id] = handler
        return id
    }

    /// Removes a previously registered handler.
    public func removeHandler(_ id: UUID) {
        segmentHandlers.removeValue(forKey: id)
        drmHandlers.removeValue(forKey: id)
        manifestHandlers.removeValue(forKey: id)
        stallRiskHandlers.removeValue(forKey: id)
    }

    // MARK: - Internal dispatch (called from ProxySDK)

    func dispatch(_ event: StreamingSegmentEvent) {
        segmentHandlers.values.forEach { $0(event) }
    }

    func dispatch(_ event: DRMLicenseEvent) {
        drmHandlers.values.forEach { $0(event) }
    }

    func dispatch(_ event: ManifestEvent) {
        manifestHandlers.values.forEach { $0(event) }
    }

    func dispatch(_ event: StallRiskEvent) {
        stallRiskHandlers.values.forEach { $0(event) }
    }
}
