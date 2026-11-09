import SwiftUI

struct ArtifactPairReviewView: View {
    @ObservedObject var registry: ArtifactSourceRegistry
    let requestID: String
    let deny: () -> Void
    @Environment(\.appTextScale) private var scale
    @State private var failure: String?

    var body: some View {
        if let review = registry.pairReviews[requestID] {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "Compare saved responses for " + review.clientName).appFont(.headline, scale: scale)
                selection("Baseline", review.baselineLabel, review.query.baseline)
                selection("Candidate", review.candidateLabel, review.query.candidate)
                Text(verbatim: review.query.pointer.isEmpty ? "Whole response" : "JSON path " + review.query.pointer)
                    .accessibilityIdentifier("artifactPairPointer")
                Text("Links these observations and shares field names, paths, counts, types and whether the response bytes match.")
                if let failure { Text(verbatim: failure) }
                Button("Compare once") {
                    do { try registry.approvePair(id: requestID) }
                    catch { failure = "This comparison is no longer available." }
                }.accessibilityIdentifier("artifactPairApprove")
                Button("Deny", role: .destructive, action: deny).accessibilityIdentifier("artifactPairDeny")
            }.appFont(.body, scale: scale)
        }
    }

    private func selection(_ role: String, _ name: String, _ side: SavedResponsePair.Side) -> some View {
        Text(verbatim: "\(role): \(name) · record \(side.recordIndex) · snapshot \(side.snapshotRevision)")
            .accessibilityIdentifier("artifactPair" + role)
    }
}
