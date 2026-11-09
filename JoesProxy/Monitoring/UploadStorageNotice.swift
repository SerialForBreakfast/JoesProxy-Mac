import SwiftUI

/// Samples only storage health, independently of captured records and workspace composition.
struct UploadStorageNotice: View {
    let service: UploadSpoolService
    @Environment(\.appTextScale) private var textScale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            if service.needsCleanup {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Upload storage needs attention")
                        .appFont(.caption, scale: textScale, weight: .semibold)
                    Text("Check disk space and storage permissions, then restart capture to retry recovery. Affected uploads fail explicitly; other traffic can continue.")
                        .appFont(.caption, scale: textScale)
                }
                .foregroundStyle(.orange)
                .padding(8)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("uploadStorageRecoveryNotice")
            }
        }
    }
}
