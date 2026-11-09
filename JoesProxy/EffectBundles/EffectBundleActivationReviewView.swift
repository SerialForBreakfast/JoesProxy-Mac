import SwiftUI

struct EffectBundleActivationReviewView: View {
    @Environment(\.appTextScale) private var textScale
    let record: EffectBundleRecord
    let onActivate: (TimeInterval) -> Void
    let onCancel: () -> Void
    @State private var duration: TimeInterval = 1_800

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review Activation").appFont(.title2, scale: textScale, weight: .semibold)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(record.manifest.name).appFont(.headline, scale: textScale)
                    Text("Bundle ID: \(record.id.uuidString)").textSelection(.enabled)
                        .accessibilityIdentifier("effectBundleReviewIdentity")
                    Text("Owner: \(record.owner.ownerID)").textSelection(.enabled)
                        .accessibilityIdentifier("effectBundleReviewOwner")
                    Text("Your local review can activate this bundle and you can Advance or Stop it, regardless of its owner. Ownership and agent permissions do not change.")
                        .accessibilityIdentifier("effectBundleLocalControlAuthority")
                    if let authoring = record.manifest.authoring {
                        Text("Revision: \(authoring.revisionID.uuidString)").textSelection(.enabled)
                            .accessibilityIdentifier("effectBundleReviewRevision")
                    }
                    Text("Response rule clients: \(EffectBundlePresentation.clientScopes(record).joined(separator: ", "))")
                        .accessibilityIdentifier("effectBundleReviewClients")
                    Text("\(record.manifest.responseEffects.count) response rules · \(record.manifest.assets.count) assets · \(record.manifest.hlsSubstitutions.count) HLS substitutions")
                        .accessibilityIdentifier("effectBundleReviewCounts")
                    if let phases = record.manifest.phases {
                        Text("Reviewed sequence · \(phases.count) phases. Advance moves forward only and never extends expiry. Sleep ends the run.")
                        ForEach(phases) { phase in
                            Text("\(phase.label): \(phase.durationSeconds.formatted()) seconds · \(phase.responseEffectIDs.count) responses · \(phase.hlsSubstitutionIDs.count) HLS resources")
                            ForEach(phase.completeHLSSubstitutionIDs ?? [], id: \.self) { id in
                                Text("Complete live HLS \(id.uuidString): freeze the current playlist with ENDLIST; retain media until Stop or expiry.")
                            }
                            ForEach(phase.timestampBindings) { binding in
                                Text("ISO-8601 UTC · \(binding.jsonPointer) · activation start plus \(binding.offsetSeconds.formatted()) seconds · response \(binding.responseEffectID.uuidString)")
                                    .textSelection(.enabled)
                            }
                        }
                        Text("Timestamp bindings replace existing static JSON strings using one activation anchor. Live collection phases preserve fresh upstream data; admitted requests may finish under their original phase. Stop invalidates unfinished mutations.")
                            .foregroundStyle(.secondary)
                        ForEach(EffectBundlePresentation.phaseBlockers(record.manifest), id: \.rawValue) { blocker in
                            Text(blocker.explanation).foregroundStyle(.orange)
                        }
                    }
                    ForEach(record.manifest.responseEffects) { effect in
                        VStack(alignment: .leading) {
                            Text("\(effect.requestMethod) \(effect.host)\(effect.path)").textSelection(.enabled)
                                .accessibilityIdentifier("effectBundleReviewResponse-\(effect.id)")
                            Text("Status \(effect.statusCode) · Client: \(effect.sourceClientAddress ?? "All clients")")
                                .accessibilityIdentifier("effectBundleReviewResponseScope-\(effect.id)")
                        }
                    }
                    ForEach(record.manifest.hlsSubstitutions) { effect in
                        VStack(alignment: .leading) {
                            Text("HLS: \(effect.origin.displayString)").textSelection(.enabled)
                            Text("\(effect.scope.displayName) · Profile: \(effect.profileID)")
                            if case .selectedPlaylist(let path) = effect.scope {
                                Text(path).textSelection(.enabled)
                            }
                            if let target = effect.replacesSubstitutionID {
                                Text("Prepared replacement for \(target.uuidString); switches at the next unpublished segment with a discontinuity.")
                            }
                            Text(effect.requestPolicy?.summary ?? HLSRequestPolicy.legacySummary)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Activation changes matching traffic. This package remains inactive after restart. Stopping it does not stop capture.")
                        .accessibilityIdentifier("effectBundleReviewWarning")
                    Text("Previous delivery evidence does not confirm the outcome of this activation.")
                        .foregroundStyle(.secondary)
                }
                .appFont(.body, scale: textScale)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Picker("Active for", selection: $duration) {
                Text("15 minutes").tag(TimeInterval(900))
                Text("30 minutes").tag(TimeInterval(1_800))
                Text("1 hour").tag(TimeInterval(3_600))
            }
            .accessibilityIdentifier("effectBundleActivationDuration")
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("effectBundleCancelActivation")
                Spacer()
                Button("Activate Reviewed Bundle") { onActivate(duration) }
                    .disabled(!EffectBundlePresentation.phaseBlockers(record.manifest).isEmpty)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("effectBundleConfirmActivation")
            }
        }
        .padding(24)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 460, idealHeight: 580)
    }
}
