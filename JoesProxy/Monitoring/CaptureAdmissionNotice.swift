import SwiftUI

/// Samples aggregate counters without observing individual records.
struct CaptureAdmissionNotice: View {
    let budget: CaptureAdmissionBudget
    let store: any SessionStore
    @Binding var dismissedGap: UInt64?
    let openCapacitySettings: (() -> Void)?
    @Environment(\.appTextScale) private var textScale
    @State private var showsDetails = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let snapshot = budget.snapshot
            let gap = snapshot.gaps.last
            let showGap = snapshot.showsCapacityEpisode(dismissed: dismissedGap, historyResetAt: store.lastHistoryResetAt)
            let removedBodies = store.evictedBodyCount
            let removedSessions = store.droppedSessionCount
            if showGap || removedBodies > 0 || removedSessions > 0 {
                Button { showsDetails.toggle() } label: {
                    Text(showGap ? (snapshot.paused ? "Busy capture · Some evidence skipped" : "Capture recovered · Details") : "History limit reached · Details")
                        .appFont(.caption, scale: textScale)
                }
                .padding(6)
                .accessibilityIdentifier("captureAdmissionGap")
                .popover(isPresented: $showsDetails) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if showGap, let gap {
                                Text(snapshot.paused ? "Too much traffic to capture at once" : "Capture is back to normal")
                                    .appFont(.headline, scale: textScale)
                                Text("During this episode: \(gap.metadataOnlyCaptures ?? 0) response bodies skipped · \(gap.rejectedCaptures) requests not recorded.")
                                Text("Traffic continues. Capture recovers automatically. Lower Per-Response Body Cap or reduce parallel requests if this recurs.")
                                if !snapshot.paused {
                                    Button("Dismiss recovered episode") {
                                        dismissedGap = gap.id
                                        showsDetails = false
                                    }
                                }
                            }
                            if removedBodies > 0 {
                                Text("Older bodies removed to stay within your history limit: \(removedBodies). Increase the history budget or save earlier to keep future bodies.")
                            }
                            if removedSessions > 0 {
                                Text("Older sessions removed to keep the latest \(store.retentionPolicy.sessionLimit?.formatted() ?? "sessions"): \(removedSessions). Save earlier or increase the session limit.")
                            }
                            if let openCapacitySettings {
                                Button("Open Long Capture Storage Settings…", action: openCapacitySettings)
                            }
                        }
                        .appFont(.body, scale: textScale)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding()
                    }
                    .frame(width: 340, height: 280)
                }
            }
        }
    }
}
