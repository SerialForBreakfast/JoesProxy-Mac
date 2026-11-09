import SwiftUI

/// Samples only aggregate admission state; never subscribes to captured records.
struct CaptureAdmissionNotice: View {
    let budget: CaptureAdmissionBudget
    @Environment(\.appTextScale) private var textScale
    @State private var showsDetails = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let snapshot = budget.snapshot
            if snapshot.rejectedCaptures > 0 || snapshot.metadataOnlyCaptures > 0 {
                Button { showsDetails.toggle() } label: {
                    Label(snapshot.paused ? "Capture reduced · Details" : "Capture recovered · Details",
                          systemImage: snapshot.paused ? "exclamationmark.circle" : "info.circle")
                        .appFont(.caption, scale: textScale)
                }
                .buttonStyle(.plain)
                .foregroundStyle(snapshot.paused ? Color.orange : Color.secondary)
                .padding(8)
                .accessibilityIdentifier("captureAdmissionGap")
                .accessibilityHint("Shows current capture capacity and previous missing evidence. Does not change device routing.")
                .popover(isPresented: $showsDetails) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(snapshot.paused ? "Saving fewer bodies" : "Body capture available")
                            .appFont(.headline, scale: textScale)
                        Text("Capture does not wait for memory. Under pressure, response bodies are skipped first; request details are kept when capacity allows. Recovery is automatic.")
                            .appFont(.caption, scale: textScale)
                        Text(verbatim: "Since launch: \(snapshot.metadataOnlyCaptures) response bodies skipped · \(snapshot.rejectedCaptures) requests not recorded.")
                            .appFont(.caption, scale: textScale)
                        Text(verbatim: "\(snapshot.pendingCaptures) pending · \(ByteCountFormatter.string(fromByteCount: Int64(snapshot.reservedBytes), countStyle: .memory)) reserved of \(ByteCountFormatter.string(fromByteCount: Int64(snapshot.byteLimit), countStyle: .memory)).")
                            .appFont(.caption, scale: textScale)
                        Text("Unlimited applies to history, not in-flight memory. Missing evidence cannot be recovered. This status does not diagnose playback failures.")
                            .appFont(.caption, scale: textScale)
                    }
                    .padding()
                    .frame(maxWidth: 340)
                }
            }
        }
    }
}
