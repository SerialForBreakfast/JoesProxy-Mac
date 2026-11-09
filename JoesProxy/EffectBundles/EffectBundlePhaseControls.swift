import SwiftUI

struct EffectBundlePhaseControls: View {
    @Environment(\.appTextScale) private var textScale
    let bundleID: UUID
    @ObservedObject var coordinator: EffectBundleActivationCoordinator
    @State private var failure: String?
    @State private var advancing = false

    var body: some View {
        if let supervision = try? coordinator.supervision(id: bundleID) {
            if let lab = supervision.labReadiness {
                Text(lab.compatibility == "scopedMediaConfigured" ? "Media lab: client scope configured" : "Media lab: client scope needs review")
                    .appFont(.caption, scale: textScale)
                    .accessibilityIdentifier("effectBundleLabReadiness")
                Text(lab.nextAction).appFont(.caption, scale: textScale)
            }
            ForEach(supervision.blockers, id: \.rawValue) { blocker in
                Text(blocker.explanation).appFont(.caption, scale: textScale)
                    .accessibilityIdentifier("effectBundleReadiness-\(blocker.rawValue)")
            }
            if supervision.liveCollectionEffectCount > 0 {
                Text(supervision.evidenceScope).appFont(.caption, scale: textScale)
            }
            ForEach(supervision.media, id: \.substitutionID) { media in
                Text(media.active ? (media.completedAt == nil ? "HLS publishing" : "HLS completed · media retained until Stop or expiry") : "HLS inactive")
                    .appFont(.caption, scale: textScale)
                    .accessibilityIdentifier("effectBundleMedia-\(media.substitutionID.uuidString)")
                Text(media.scope).appFont(.caption, scale: textScale)
            }
        }
        if let phase = coordinator.phaseSnapshots[bundleID] {
            VStack(alignment: .leading) {
                Text("Phase \(phase.phaseIndex + 1) of \(phase.phaseCount): \(phase.label)")
                Text("Phase deadline: \(phase.phaseDeadline.formatted(date: .omitted, time: .standard))")
                Button(phase.phaseIndex + 1 == phase.phaseCount ? "Finish Sequence" : "Advance to Next Phase") {
                    advancing = true
                    Task { @MainActor in
                        defer { advancing = false }
                        do {
                            _ = try await coordinator.advanceFromLocalUI(id: bundleID,
                                activationID: phase.activationID, expectedPhaseID: phase.phaseID)
                            failure = nil
                        } catch { failure = error.localizedDescription }
                    }
                }
                .disabled(advancing)
                .accessibilityIdentifier("effectBundleAdvance-\(bundleID.uuidString)")
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .appFont(.caption, scale: textScale)
        }
    }
}
