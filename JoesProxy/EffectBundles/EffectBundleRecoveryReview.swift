import SwiftUI

struct EffectBundleRecoveryReview: Identifiable {
    let id: UUID
    let bundleID: UUID
    let title: String
    let text: String
    var assetTarget: EffectBundleAssetRecoveryTarget?

    init(receipt: EffectBundleDeliveryReceipt, action: EffectBundleRecoveryAction,
         effect: EffectBundleResponseEffect?, request: CapturedRequest?) {
        id = receipt.id
        bundleID = receipt.resource.bundleID
        title = action.label
        func bounded(_ value: String?) -> String {
            guard let value else { return "Unavailable" }
            return value.count > 1000 ? String(value.prefix(1000)) + "… (truncated)" : value
        }
        var lines = ["Inspection is read-only. Only explicitly choosing Stop bundle changes serving state; it does not change the revision.",
            "Revision: \(receipt.resource.revisionID)", "Resource: \(receipt.resource.assetID)"]
        if action == .reviewIntegrity {
            lines += ["Reviewed SHA256: \(receipt.resource.expectedSHA256)",
                "Served SHA256: \(receipt.servedSHA256 ?? "Not served")",
                "Rendering remains unconfirmed. Recovery that changes assets requires a new reviewed revision."]
        } else if let effect {
            lines += ["Configured method: \(bounded(effect.requestMethod))",
                "Configured scheme: \(effect.requestScheme.rawValue)", "Configured host: \(bounded(effect.host))",
                "Configured port: \(effect.port.map { String($0) } ?? "Scheme default")",
                "Configured path: \(bounded(effect.path))", "Match mode: \(effect.matchMode.rawValue)",
                "Configured client: \(bounded(effect.sourceClientAddress ?? "No client-address restriction"))",
                "GraphQL operation condition: \(bounded(effect.graphQLOperationName))",
                "Query condition: \(bounded(effect.matchQueryKey)) = \(bounded(effect.matchQueryValue))",
                "Header condition: \(bounded(effect.matchHeaderName)) = \(bounded(effect.matchHeaderValue))"]
            if let request {
                lines += ["Observed method: \(bounded(request.method))", "Observed scheme: \(request.scheme.rawValue)",
                    "Observed host: \(bounded(request.host))", "Observed path: \(bounded(request.path))",
                    "Observed port: \(request.port.map { String($0) } ?? "Scheme default")",
                    "Observed client: \(bounded(request.clientAddress))"]
            } else { lines.append("Captured request unavailable. Do not infer its values from the current selection.") }
            lines.append("A sibling-path miss may be expected. Changing a matcher or client scope requires separate review.")
            lines.append("Use Inspect request for predicate details beyond the metadata shown here. No request body is read by this review.")
        }
        text = lines.joined(separator: "\n\n")
    }
}

struct EffectBundleRecoveryReviewView: View {
    @Environment(\.appTextScale) private var textScale
    @Environment(\.dismiss) private var dismiss
    let review: EffectBundleRecoveryReview
    var stopBundle: (() async -> String)?
    var selectedSource: (id: String, label: String)?
    var sourceOptions: [(id: String, label: String)] = []
    var beginReplacement: ((String) -> String?)?
    @State private var replacementSourceID = ""
    @State private var replacementMessage: String?
    @State private var checking = false
    @State private var stopping = false
    @State private var result: String?
    @State private var checkTask: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(review.title).appFont(.title3, scale: textScale, weight: .semibold)
            ScrollView {
              VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: review.text).appFont(.body, scale: textScale)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let target = review.assetTarget {
                Button(checking ? "Checking retained asset…" : "Check retained asset") {
                    guard !checking else { return }
                    checking = true
                    result = nil
                    checkTask = Task {
                        defer { checking = false }
                        do { result = try await EffectBundleAssetRecoveryCheck.run(target).message }
                        catch { result = "Asset check cancelled. No files or active revisions were changed." }
                    }
                }.disabled(checking || stopping)
                .accessibilityIdentifier("recoveryCheckRetainedAsset")
                if checking {
                    ProgressView().accessibilityLabel("Checking retained asset")
                    Button("Cancel check") { checkTask?.cancel() }
                }
                if let result { Text(result).appFont(.body, scale: textScale).textSelection(.enabled) }
            }
            Text("Replacement requires explicitly selecting the original captured JSON response and an image in Append JSON + Image. Saved revisions retain a source digest, not the original source or draft. An image receipt cannot supply either. Prepare, review and save a new inactive revision, then activate separately. Existing drafts and active bundles are not changed here. Use the bundle’s Stop action if you choose to stop serving it.")
                .appFont(.caption, scale: textScale)
                if let beginReplacement {
                    DisclosureGroup("Choose source for a replacement draft") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Choose the original JSON capture, not the image request. JSON structure is validated at Prepare. Existing typed draft edits are retained; choosing a source invalidates any prepared preview. Choose the replacement image in the editor.")
                                .appFont(.caption, scale: textScale)
                            TextField("Captured JSON request UUID", text: $replacementSourceID)
                                .appFont(.body, scale: textScale)
                                .accessibilityIdentifier("recoveryReplacementSourceID")
                            if let selectedSource {
                                Text(selectedSource.label).appFont(.caption, scale: textScale).lineLimit(3)
                                Button("Choose selected request") { replacementSourceID = selectedSource.id }
                                    .accessibilityIdentifier("recoveryChooseSelectedSource")
                            }
                            Menu("Choose from captured GET responses (up to 50)") {
                                ForEach(sourceOptions, id: \.id) { source in
                                    Button(source.label) { replacementSourceID = source.id }
                                }
                            }.disabled(sourceOptions.isEmpty)
                                .accessibilityIdentifier("recoveryChooseCapturedSource")
                            Button("Open replacement draft") {
                                replacementMessage = beginReplacement(replacementSourceID)
                            }.disabled(checking || stopping || replacementSourceID.isEmpty)
                                .accessibilityIdentifier("recoveryOpenReplacementDraft")
                            if let replacementMessage {
                                Text(replacementMessage).appFont(.body, scale: textScale)
                                    .accessibilityIdentifier("recoveryReplacementError")
                            }
                        }
                    }.accessibilityIdentifier("recoveryReplacementDisclosure")
                }
                if let stopBundle {
                    Button(stopping ? "Stopping bundle…" : "Stop bundle", role: .destructive) {
                        guard !stopping else { return }
                        stopping = true
                        Task {
                            result = await stopBundle()
                            stopping = false
                        }
                    }.disabled(stopping || checking)
                    .accessibilityIdentifier("recoveryStopBundle")
                }
              }
            }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding().frame(minWidth: 420, idealWidth: 560, minHeight: 360, idealHeight: 520)
        .onDisappear { checkTask?.cancel() }
    }
}
