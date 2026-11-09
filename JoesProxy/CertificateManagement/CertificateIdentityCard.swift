import SwiftUI

/// Compact identity card for the local JoesProxy CA instance (Phase A).
///
/// Shows short code, fingerprint, serial, validity, storage state, and optional nickname editing.
/// Copy / paste-compare actions keep fingerprint comparison honest without relying on hostnames.
struct CertificateIdentityCard: View {
    let metadata: CAInstanceMetadata?
    let identityStatus: CertificateIdentityStatus?
    let fingerprint: String?
    let serialNumber: String?
    let notBefore: Date?
    let notAfter: Date?
    let appTextScale: Double
    let onCopyFingerprint: () -> Void
    let onCopyShortCode: () -> Void
    let onAdoptLegacy: (() -> Void)?
    let onNicknameChange: ((String) -> Void)?
    @State private var nicknameDraft: String = ""
    @State private var comparePaste: String = ""
    @State private var actionMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Certificate Identity")
                    .appFont(.headline, scale: appTextScale, weight: .semibold)
                Spacer()
                if let identityStatus {
                    Text(identityStatus.title)
                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                        .foregroundStyle(statusColor(for: identityStatus))
                }
            }

            if identityStatus == .legacyIdentityUnknown {
                Text("This root has no stored CA instance ID yet. Adopt its identity once to assign a stable short code without rotating the certificate.")
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let onAdoptLegacy {
                    Button("Adopt this certificate's identity") {
                        onAdoptLegacy()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("certificateIdentityAdoptButton")
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Short code", metadata?.shortCode ?? "—")
                row("Nickname", metadata?.nickname ?? "—")
                row("Fingerprint", fingerprint.map { String($0.prefix(16)) + "…" } ?? "—")
                row("Serial", serialNumber ?? "—")
                row("Valid from", formatted(notBefore) ?? "—")
                row("Expires", formatted(notAfter) ?? "—")
                row("Storage", metadata?.storageState.rawValue ?? "—")
            }
            .appFont(.caption, scale: appTextScale)

            if metadata != nil, let onNicknameChange {
                HStack(spacing: 8) {
                    TextField("Nickname", text: $nicknameDraft)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("certificateIdentityNicknameField")
                    Button("Save") {
                        onNicknameChange(nicknameDraft)
                        actionMessage = "Nickname saved."
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 8) {
                Button("Copy fingerprint") {
                    onCopyFingerprint()
                    actionMessage = "Copied fingerprint."
                }
                .buttonStyle(.bordered)
                .disabled(fingerprint == nil)
                .accessibilityIdentifier("certificateIdentityCopyFingerprintButton")

                Button("Copy short code") {
                    onCopyShortCode()
                    actionMessage = "Copied short code."
                }
                .buttonStyle(.bordered)
                .disabled(metadata?.shortCode == nil)
                .accessibilityIdentifier("certificateIdentityCopyShortCodeButton")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Paste fingerprint to compare")
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
                TextField("sha256…", text: $comparePaste)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("certificateIdentityCompareField")
                if !normalizedCompare.isEmpty {
                    Text(compareResultText)
                        .appFont(.caption, scale: appTextScale, weight: .semibold)
                        .foregroundStyle(compareMatches ? .green : .orange)
                        .accessibilityIdentifier("certificateIdentityCompareResult")
                }
            }

            if let actionMessage {
                Text(actionMessage)
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("certificateIdentityCard")
        .onAppear {
            nicknameDraft = metadata?.nickname ?? ""
        }
        .onChange(of: metadata?.nickname) { _, newValue in
            nicknameDraft = newValue ?? ""
        }
    }

    private var normalizedCompare: String {
        comparePaste
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "")
            .lowercased()
    }

    private var compareMatches: Bool {
        guard let fingerprint else { return false }
        return normalizedCompare == fingerprint.lowercased()
            || normalizedCompare == String(fingerprint.prefix(normalizedCompare.count)).lowercased()
                && normalizedCompare.count >= 12
    }

    private var compareResultText: String {
        compareMatches ? "Matches this CA fingerprint." : "Does not match this CA fingerprint."
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func formatted(_ date: Date?) -> String? {
        guard let date else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func statusColor(for status: CertificateIdentityStatus) -> Color {
        switch status {
        case .valid:
            return .green
        case .expiringSoon:
            return .yellow
        case .expired, .invalidOrUnreadable, .missing:
            return .red
        case .legacyIdentityUnknown:
            return .orange
        }
    }
}
