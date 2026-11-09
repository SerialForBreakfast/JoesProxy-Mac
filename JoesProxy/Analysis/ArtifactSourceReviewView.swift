import AppKit
import SwiftUI

@MainActor
final class ArtifactSourceFileCoordinator {
    enum Selection: Sendable { case file(URL), synthetic(Data) }
    private let syntheticSelection: Data?

    init(syntheticSelection: Data? = nil) { self.syntheticSelection = syntheticSelection }

    func select(kind: ArtifactSourceKind) async -> Selection? {
        if let syntheticSelection { return .synthetic(syntheticSelection) }
        let panel = NSOpenPanel()
        panel.title = "Select a source to review"
        panel.prompt = "Prepare for Review"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = kind == .effectBundle
        panel.canChooseFiles = kind != .effectBundle
        panel.resolvesAliases = false
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        return response == .OK ? panel.url.map(Selection.file) : nil
    }
}

struct ArtifactSourceReviewView: View {
    @ObservedObject var registry: ArtifactSourceRegistry
    let requestID: String
    @Environment(\.appTextScale) private var textScale
    @State private var choosing = false
    @State private var failure: String?

    var body: some View {
        if let request = registry.request(id: requestID) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Share one temporary copy with this client")
                    .appFont(.headline, scale: textScale)
                Text(request.scopes.contains("calculations-v1")
                    ? "Allows counts, grouping, numerical summaries and selected scalar values. Does not allow raw file downloads."
                    : "Allows file kind, size and coverage metadata.")
                    .appFont(.body, scale: textScale)
                    .accessibilityIdentifier("artifactSourceScope")
                if request.scopes.contains("brief-v1") {
                    Text("Allows response field names, nested paths, types and counts. These can reveal sensitive attributes, even without the field values.")
                        .appFont(.body, scale: textScale)
                        .accessibilityIdentifier("artifactSourceBriefConsent")
                }
                if request.scopes.contains("search-v1") {
                    Text("Allows record metadata, exact match counts and locations. Repeated searches can reveal whether sensitive text is present.")
                        .appFont(.body, scale: textScale)
                        .accessibilityIdentifier("artifactSourceSearchConsent")
                }
                Text("Expires after \(request.ttl % 60 == 0 ? "\(request.ttl / 60) minutes" : "\(request.ttl) seconds") once registered. Later edits or deletion of the original do not change this copy. Revoke it here to end access.")
                    .appFont(.caption, scale: textScale)
                Button(choosing ? "Choosing source…" : "Select source…") {
                    choosing = true
                    Task {
                        let selection = await registry.fileCoordinator.select(kind: request.kind)
                        choosing = false
                        if let selection { registry.prepare(id: requestID, selection: selection) }
                    }
                }
                .disabled(choosing || request.state == "preparing")
                .accessibilityIdentifier("artifactSourceSelect")
                if request.state == "preparing" {
                    ProgressView("Preparing a private copy for your review…")
                        .accessibilityIdentifier("artifactSourceProgress")
                }
                if let name = request.localName {
                    Text(verbatim: name).appFont(.body, scale: textScale)
                        .accessibilityIdentifier("artifactSourceLocalName")
                }
                if let path = request.localPath {
                    Text(verbatim: path).appFont(.caption, scale: textScale)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("artifactSourceLocalPath")
                }
                if let snapshot = request.snapshot {
                    Text(verbatim: "\(snapshot.kind.rawValue) · \(snapshot.byteCount) bytes · \(snapshot.records.count) records")
                        .appFont(.body, scale: textScale)
                        .accessibilityIdentifier("artifactSourcePreview")
                    Text(snapshot.warnings.isEmpty ? "No format coverage warnings." : snapshot.warnings.joined(separator: ", "))
                        .appFont(.caption, scale: textScale)
                        .accessibilityIdentifier("artifactSourceCoverage")
                }
                if let message = failure ?? request.localFailure {
                    Text("Preparation unavailable: \(message). Select another source or cancel.")
                        .appFont(.caption, scale: textScale)
                        .accessibilityIdentifier("artifactSourceResult")
                }
                HStack {
                    Button("Share snapshot") {
                        do { try registry.share(id: requestID); failure = nil }
                        catch { failure = "source_unavailable" }
                    }
                    .disabled(request.state != "review" || request.snapshot == nil || request.reservedBytes > 0)
                    .accessibilityIdentifier("artifactSourceShare")
                    Button("Cancel", role: .cancel) { registry.retire(id: requestID) }
                        .accessibilityIdentifier("artifactSourceCancel")
                }
                Text("Review deadline: \(request.deadline.formatted())")
                    .appFont(.caption, scale: textScale)
                    .accessibilityIdentifier("artifactSourceExpiry")
            }
            .accessibilityElement(children: .contain)
            .onExitCommand { registry.retire(id: requestID) }
        }
    }
}

struct ArtifactActiveSharesView: View {
    @ObservedObject var registry: ArtifactSourceRegistry
    @Environment(\.appTextScale) private var textScale

    var body: some View {
        let active = registry.requests.filter { $0.state == "ready" || $0.state == "approved_awaiting_retry" }
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Shared artifact copies").appFont(.headline, scale: textScale)
                ForEach(active) { request in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(verbatim: request.localName ?? request.kind.rawValue).appFont(.body, scale: textScale)
                            Text("Client \(request.owner.clientID) · \(request.state)").appFont(.caption, scale: textScale)
                            if let expiry = request.expiresAt { Text("Expires \(expiry.formatted())").appFont(.caption, scale: textScale) }
                        }
                        Spacer()
                        Button("Revoke") { registry.retire(id: request.id, reason: "revoked") }
                            .accessibilityLabel("Revoke shared copy for client \(request.owner.clientID)")
                            .accessibilityIdentifier("artifactSourceRevoke")
                    }
                }
                Button("Revoke all shared copies") { registry.revokeAll() }
                    .accessibilityIdentifier("artifactSourceRevokeAll")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("artifactSourceActiveShares")
        }
    }
}
