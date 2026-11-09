import SwiftUI

struct EffectBundleEvidenceView: View {
    @Environment(\.appTextScale) private var textScale
    @State private var evidence: EffectBundleDeliveryEvidence?
    @State private var observationStart: UInt64?
    @State private var actionMessage: String?
    @State private var isExpanded = false
    @State private var expandedReceiptIDs: Set<UUID> = []
    let bundleID: UUID
    var gate: EffectBundleActivationGate = .shared
    var availability: (EffectBundleDeliveryReceipt) -> EffectBundleRecoveryAvailability = { _ in
        .init(receiptExists: true, resourceExists: false, captureExists: false, bundleServing: false)
    }
    var performRecovery: (EffectBundleRecoveryAction, EffectBundleDeliveryReceipt) -> String? = { _, _ in
        "This destination is not available in the current workspace."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                Label("Resource delivery evidence", systemImage: isExpanded ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("effectBundleEvidenceToggle")
            if isExpanded {
            Button("Refresh evidence") { refresh() }
                .accessibilityIdentifier("effectBundleRefreshEvidence")
            Button("Observe next request") { startObservation() }
                .accessibilityIdentifier("effectBundleObserveNextRequest")
            if observationStart != nil {
                Text("Observation window started. Perform one action in the target, then refresh. No traffic is generated here.")
                    .appFont(.caption2, scale: textScale)
                Button("Show retained history") { observationStart = nil; refresh() }
                    .accessibilityIdentifier("effectBundleShowHistory")
            }
            if let actionMessage { Text(actionMessage).appFont(.caption2, scale: textScale) }
            if let evidence {
                Text(evidence.scope).appFont(.caption2, scale: textScale)
                ForEach(evidence.observations.filter { $0.authored == nil }) { item in
                    observationRow(item)
                }
                if evidence.receipts.isEmpty && evidence.observations.isEmpty {
                    Text("No retained request observations.").appFont(.caption2, scale: textScale)
                }
                if evidence.retentionGap {
                    Text("Earlier observations are unavailable; do not infer a cache hit.")
                        .appFont(.caption2, scale: textScale)
                }
                if evidence.hasMore {
                    Button("Next evidence page") {
                        expandedReceiptIDs.removeAll()
                        self.evidence = gate.evidence(bundleID: bundleID, after: evidence.nextMarker)
                    }.accessibilityIdentifier("effectBundleNextEvidencePage")
                }
                ForEach(evidence.receipts) { receipt in
                    receiptRow(receipt)
                }
            }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("effectBundleEvidenceDisclosure")
    }

    private func refresh() {
        expandedReceiptIDs.removeAll()
        evidence = gate.evidence(bundleID: bundleID, after: observationStart ?? 0)
    }

    private func observationRow(_ observation: EffectBundleObservation) -> some View {
        let presentation = EffectBundleObservationPresentation(observation)
        return VStack(alignment: .leading, spacing: 6) {
            Text(presentation.title).appFont(.body, scale: textScale, weight: .semibold)
            Text(presentation.explanation).appFont(.caption, scale: textScale)
            if let track = presentation.trackSummary {
                Text(track).appFont(.caption, scale: textScale)
                    .accessibilityIdentifier("effectBundleObservation-\(observation.id)-track")
            }
            Button("Technical details") {
                if !expandedReceiptIDs.insert(observation.id).inserted {
                    expandedReceiptIDs.remove(observation.id)
                }
            }
            .accessibilityValue(expandedReceiptIDs.contains(observation.id) ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("effectBundleObservation-\(observation.id)-details")
            if expandedReceiptIDs.contains(observation.id) {
                Text(verbatim: presentation.technicalDetails)
                    .appFont(.caption2, scale: textScale).textSelection(.enabled)
                    .accessibilityIdentifier("effectBundleObservation-\(observation.id)-technicalText")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("effectBundleObservation-\(observation.id)")
    }

    private func startObservation() {
        guard gate.allows(bundleID: bundleID) else {
            actionMessage = "This bundle is not serving. Existing receipt history remains available."
            return
        }
        observationStart = gate.observationMarker()
        actionMessage = nil
        refresh()
    }

    private func execute(_ action: EffectBundleRecoveryAction, receipt: EffectBundleDeliveryReceipt) {
        if action == .refreshEvidence { refresh(); return }
        if action == .observeNextRequest { startObservation(); return }
        guard let current = gate.retainedReceipt(id: receipt.id, bundleID: bundleID) else {
            actionMessage = "This receipt is no longer retained. Refresh evidence to continue."
            return
        }
        let choice = EffectBundleRecoveryPolicy.choice(action, receipt: current, availability: availability(current))
        guard choice.isEnabled else { actionMessage = choice.unavailableReason; return }
        actionMessage = performRecovery(action, current)
    }

    private func receiptRow(_ receipt: EffectBundleDeliveryReceipt) -> some View {
        let presentation = EffectBundleRecoveryPolicy.resolve(receipt, availability: availability(receipt))
        return VStack(alignment: .leading, spacing: 6) {
            Text(presentation.title).appFont(.body, scale: textScale, weight: .semibold)
            Text(verbatim: "Asset: \(receipt.resource.assetID)").appFont(.caption2, scale: textScale)
            Text(presentation.explanation).appFont(.caption2, scale: textScale)
            ViewThatFits(in: .horizontal) {
                HStack { recoveryButton(presentation.primary, receipt: receipt); additionalActions(presentation, receipt: receipt) }
                VStack(alignment: .leading) { recoveryButton(presentation.primary, receipt: receipt); additionalActions(presentation, receipt: receipt) }
            }
            if let reason = presentation.primary.unavailableReason {
                Text(reason).appFont(.caption2, scale: textScale)
            }
            Button("Technical details") {
                if !expandedReceiptIDs.insert(receipt.id).inserted {
                    expandedReceiptIDs.remove(receipt.id)
                }
            }
            .accessibilityValue(expandedReceiptIDs.contains(receipt.id) ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("effectBundleReceipt-\(receipt.id)-details")
            if expandedReceiptIDs.contains(receipt.id) {
                if let digest = receipt.resource.materializedSHA256 {
                    Text(verbatim: "Activation-rendered SHA256: \(digest) · Rendered bytes match: \(receipt.matchesMaterializedAsset.map { String($0) } ?? "not observed")")
                        .appFont(.caption2, scale: textScale).textSelection(.enabled)
                }
                Text(verbatim: "\(receipt.evaluation.rawValue) · \(receipt.delivery.rawValue)\nRevision: \(receipt.resource.revisionID)\nCapture: \(receipt.sessionID?.uuidString ?? "unavailable")\nSHA256: \(receipt.servedSHA256 ?? "not served") · Reviewed bytes match: \(receipt.matchesReviewedAsset.map { String($0) } ?? "not applicable")\nObserved: \(receipt.observedAt.formatted())")
                    .appFont(.caption2, scale: textScale).textSelection(.enabled)
                    .accessibilityIdentifier("effectBundleReceipt-\(receipt.id)-technicalText")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("effectBundleReceipt-\(receipt.id)")
    }

    private func recoveryButton(_ choice: EffectBundleRecoveryChoice, receipt: EffectBundleDeliveryReceipt) -> some View {
        Button(choice.action.label) { execute(choice.action, receipt: receipt) }
            .disabled(!choice.isEnabled)
            .help(choice.unavailableReason ?? choice.action.label)
            .accessibilityHint(choice.unavailableReason ?? "Read-only recovery action")
            .accessibilityIdentifier("effectBundleReceipt-\(receipt.id)-\(choice.action.rawValue)")
    }

    private func additionalActions(_ presentation: EffectBundleRecoveryPresentation, receipt: EffectBundleDeliveryReceipt) -> some View {
        Menu("Additional actions") {
            ForEach(presentation.secondary) { choice in
                recoveryButton(choice, receipt: receipt)
                if let reason = choice.unavailableReason { Text(reason) }
            }
        }.accessibilityIdentifier("effectBundleReceipt-\(receipt.id)-additionalActions")
    }
}

/// In-memory UI fixture: never registers a route or activates a bundle.
struct EffectBundleEvidenceUITestView: View {
    private static let bundleID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    @State private var gate: EffectBundleActivationGate

    init(captions: Bool = false) {
        let gate = EffectBundleActivationGate()
        for index in 0..<40 {
            if captions {
                let identity = EffectBundleObservation.Identity(bundleID: Self.bundleID,
                    revisionID: Self.bundleID, activationID: Self.bundleID, resourceID: UUID())
                let track = HLSWebVTTFixture.TrackIdentity(id: "es", language: "es", role: "subtitles", sourceRevision: "synthetic-text-v1")
                let id = gate.observe(identity: identity, kind: index == 2 ? .liveCollection : .hlsSegment,
                    outcome: index == 2 ? "capacityLimited" : "http_200", segmentSequence: index,
                    textTrack: index == 2 ? nil : track)
                if index != 0 { gate.completeReceipt(id: id, succeeded: index != 1) }
                continue
            }
            let resource = EffectBundleResourceIdentity(bundleID: Self.bundleID, revisionID: Self.bundleID,
                activationID: Self.bundleID, resourceID: UUID(), assetID: "fixture-\(index)", expectedSHA256: "synthetic-hash")
            _ = gate.observe(resource: resource, servedSHA256: nil, evaluation: .assetReadFailed)
        }
        _gate = State(initialValue: gate)
    }
    var body: some View {
        ScrollView { EffectBundleEvidenceView(bundleID: Self.bundleID, gate: gate).padding() }
            .frame(width: 720, height: 560)
            .background(UITestPrimaryScreenWindowConfigurator().frame(width: 0, height: 0))
    }
}
