//
//  SyntheticInjectionCardView.swift
//  JoesProxy
//
//  SwiftUI card view for managing in-flight collection injection plans
//  and binding local synthetic media assets.
//

import SwiftUI

/// One row in the "Synthetic Collection Injection" section of `ResponseOverridesSheet` — matches
/// `OpenAPIMockPackRow`/`HLSTestStreamExperimentRow`'s row shape (icon, name/detail column, status,
/// action) rather than `SyntheticInjectionCardView` above, whose card layout predates that sheet
/// gaining a management list for every other currently-active mechanism.
struct SyntheticInjectionPlanRow: View {
    @Environment(\.appTextScale) private var appTextScale
    let plan: SyntheticCollectionInjectionPlan
    var diagnostics: SyntheticInjectionDiagnostics? = nil
    let onToggle: (Bool) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: plan.isEnabled ? "syringe.fill" : "syringe")
                .foregroundStyle(plan.isEnabled ? .green : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(plan.name)
                    .appFont(.body, scale: appTextScale, weight: .semibold)
                Text(verbatim: "\(plan.urlPattern) · \(plan.collectionKeypath) · \(plan.position.title)")
                    .appFont(.caption2, scale: appTextScale)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: plan.clientScope.title)
                    .appFont(.caption2, scale: appTextScale)
                    .foregroundStyle(.secondary)
                Text(diagnostics?.lastReason?.rawValue ?? "No evaluation observed")
                    .appFont(.caption2, scale: appTextScale)
                    .accessibilityIdentifier("syntheticInjectionLastReason")
                if let diagnostics, let reason = diagnostics.lastReason {
                    Text(reason.recovery).appFont(.caption2, scale: appTextScale)
                    Text(verbatim: "Transformed: \(diagnostics.counts[SyntheticInjectionReason.transformed.rawValue, default: 0]) · Target outcome unknown")
                        .appFont(.caption2, scale: appTextScale)
                    if !diagnostics.receipts.isEmpty {
                        DisclosureGroup("Recent request receipts (up to 32)") {
                            ForEach(diagnostics.receipts.reversed(), id: \.requestID) { receipt in
                                Text(verbatim: "Request \(receipt.requestID) · \(receipt.reason.rawValue) · \(receipt.deliveryState.rawValue)\nCapture: \(receipt.sessionID?.uuidString ?? "unavailable")\nRegistration: \(receipt.registrationID)")
                                    .appFont(.caption2, scale: appTextScale)
                                    .textSelection(.enabled)
                            }
                            Text("Write success confirms proxy transport completion, not client rendering. Registration IDs are not authored bundle revisions.")
                                .appFont(.caption2, scale: appTextScale)
                        }
                        .accessibilityIdentifier("syntheticInjectionReceipts")
                    }
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { plan.isEnabled }, set: onToggle))
                .labelsHidden()
                .accessibilityLabel("\(plan.name) enabled")
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(plan.name)")
        }
    }
}

struct SyntheticInjectionCardView: View {
    let plans: [SyntheticCollectionInjectionPlan]
    var onTogglePlan: ((UUID, Bool) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header Row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Schema-Inferred Collection Injection")
                        .font(.headline)
                    Text("Injects synthetic items and local test media into wire JSON arrays")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("\(plans.filter(\.isEnabled).count) Active")
                    .font(.caption)
                    .fontWeight(.bold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.blue.opacity(0.12))
                    .foregroundColor(.blue)
                    .cornerRadius(4)
            }

            if plans.isEmpty {
                Text("No active collection injection plans configured.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 8) {
                    ForEach(plans) { plan in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(plan.name)
                                    .font(.system(size: 11, weight: .bold))

                                Spacer()

                                Text(plan.position.title)
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.purple.opacity(0.12))
                                    .foregroundColor(.purple)
                                    .cornerRadius(3)

                                Text(plan.clientScope.title)
                                    .font(.system(size: 9))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.06))
                                    .cornerRadius(3)
                            }

                            HStack {
                                Text("URL:")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.secondary)
                                Text(plan.urlPattern)
                                    .font(.system(size: 9, design: .monospaced))
                                    .lineLimit(1)

                                Spacer()

                                Text("Keypath:")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.secondary)
                                Text(plan.collectionKeypath)
                                    .font(.system(size: 9, design: .monospaced))
                            }

                            if let assetKind = plan.boundAssetKind {
                                HStack {
                                    Text("Bound Asset:")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(.secondary)
                                    Text(assetKind.rawValue)
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.green)
                                }
                            }
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.02))
                        .cornerRadius(6)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }
}
