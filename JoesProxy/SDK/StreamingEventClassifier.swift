import Foundation

/// Classifies a captured session as a streaming-relevant event kind for M3 broadcast.
/// Built on top of `TimelineClassificationService`, which already distinguishes manifest,
/// segment, and DRM-license lanes/labels for the Timeline UI.
struct StreamingEventClassifier: Sendable {
    enum StreamingEventKind: Equatable {
        case segment
        /// `format` is "HLS" or "DASH".
        case manifest(format: String)
        /// `system` is "FairPlay", "Widevine", "ClearKey", "PlayReady", or nil when unrecognized.
        case drmLicense(system: String?)
    }

    private let classifier: any TimelineClassifying

    init(classifier: any TimelineClassifying = TimelineClassificationService()) {
        self.classifier = classifier
    }

    func classify(session: SessionRecord) -> StreamingEventKind? {
        let classification = classifier.classify(session)

        if classification.labels.contains(.drmLicense) {
            return .drmLicense(system: drmSystem(for: session))
        }
        if classification.lane == .manifest {
            return .manifest(format: classification.labels.contains(.dash) ? "DASH" : "HLS")
        }
        if classification.lane == .mediaSegments {
            return .segment
        }
        return nil
    }

    /// R2 DRM URL pattern matching. Longest/most-specific patterns first.
    private func drmSystem(for session: SessionRecord) -> String? {
        let host = session.request.host.lowercased()
        let path = session.request.path.lowercased()
        let combined = "\(host) \(path)"

        if combined.contains("fairplay") || combined.contains("/ckc") || combined.contains("/spc") {
            return "FairPlay"
        }
        if combined.contains("widevine") {
            return "Widevine"
        }
        if combined.contains("clearkey") {
            return "ClearKey"
        }
        if combined.contains("playready") || combined.contains("mspr") {
            return "PlayReady"
        }
        return nil
    }
}
