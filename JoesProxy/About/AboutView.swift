//
//  AboutView.swift
//  JoesProxy
//
//  Custom About sheet displayed via the Apple menu. Shows version info, links,
//  and open source acknowledgments required by bundled library licenses.
//

import SwiftUI
import AppKit

// MARK: - Acknowledged library model

/// A bundled open source dependency and its license type.
private struct AcknowledgedLibrary: Identifiable {
    let id = UUID()
    let name: String
    let license: String
    let url: URL
}

private let acknowledgments: [AcknowledgedLibrary] = [
    AcknowledgedLibrary(
        name: "SwiftNIO",
        license: "Apache 2.0",
        url: URL(string: "https://github.com/apple/swift-nio")!
    ),
    AcknowledgedLibrary(
        name: "SwiftNIO SSL",
        license: "Apache 2.0",
        url: URL(string: "https://github.com/apple/swift-nio-ssl")!
    ),
    AcknowledgedLibrary(
        name: "Swift Atomics",
        license: "Apache 2.0",
        url: URL(string: "https://github.com/apple/swift-atomics")!
    ),
    AcknowledgedLibrary(
        name: "Swift Collections",
        license: "Apache 2.0",
        url: URL(string: "https://github.com/apple/swift-collections")!
    ),
    AcknowledgedLibrary(
        name: "Swift System",
        license: "Apache 2.0",
        url: URL(string: "https://github.com/apple/swift-system")!
    ),
    AcknowledgedLibrary(
        name: "Sparkle",
        license: "MIT",
        url: URL(string: "https://github.com/sparkle-project/Sparkle")!
    ),
]

// MARK: - AboutView

/// Main content of the About sheet.
struct AboutView: View {
    @Binding var isPresented: Bool
    @Environment(\.appTextScale) private var textScale

    private let repoURL = URL(string: "https://github.com/SerialForBreakfast/JoesProxy-Mac")!
    private let issuesURL = URL(string: "https://github.com/SerialForBreakfast/JoesProxy-Mac/issues")!
    private let privacyURL = URL(string: "https://github.com/SerialForBreakfast/JoesProxy-Mac/blob/main/docs/PRIVACY.md")!

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            linksSection
            Divider()
            acknowledgementsSection
            Divider()
            dismissButton
        }
        // The window sizes to content; widen with enlarged text instead of truncating.
        .frame(width: 400 * max(1, textScale))
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

            Text(Bundle.main.appName)
                .appFont(.title2, scale: textScale, weight: .bold)

            let version = Bundle.main.marketingVersion
            let build = Bundle.main.buildNumber
            Text("Version \(version) (\(build))")
                .appFont(.subheadline, scale: textScale)
                .foregroundStyle(.secondary)

            Text(Bundle.main.humanReadableCopyright)
                .appFont(.caption, scale: textScale)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    private var linksSection: some View {
        HStack(spacing: 24) {
            linkButton(label: "GitHub", systemImage: "chevron.left.forwardslash.chevron.right", url: repoURL)
            linkButton(label: "Support", systemImage: "bubble.right", url: issuesURL)
            linkButton(label: "Privacy", systemImage: "lock.shield", url: privacyURL)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }

    private var acknowledgementsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open Source Acknowledgments")
                .appFont(.headline, scale: textScale, weight: .semibold)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 20)
                .padding(.top, 14)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(acknowledgments) { library in
                        acknowledgmentRow(library)
                        if library.id != acknowledgments.last?.id {
                            Divider().padding(.leading, 20)
                        }
                    }
                }
            }
            .frame(height: 180 * max(1, textScale))
        }
    }

    private var dismissButton: some View {
        HStack {
            Spacer()
            Button("Close") { isPresented = false }
                .keyboardShortcut(.cancelAction)
                .padding(.trailing, 20)
        }
        .padding(.vertical, 12)
    }

    // MARK: - Row builders

    private func linkButton(label: String, systemImage: String, url: URL) -> some View {
        Link(destination: url) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .imageScale(.large)
                Text(label)
                    .appFont(.caption, scale: textScale)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .accessibilityLabel(label)
    }

    private func acknowledgmentRow(_ library: AcknowledgedLibrary) -> some View {
        Link(destination: library.url) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(library.name)
                        .appFont(.subheadline, scale: textScale)
                        .foregroundStyle(.primary)
                    Text(library.license)
                        .appFont(.caption, scale: textScale)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
