import SwiftUI

/// On-demand legend explaining the session table's icon vocabulary (inspection state, scheme,
/// source, and media type). Presented from a `?` button rather than `.help()` tooltips, since
/// `.help()` attachments inside `Table` rows crash AppKit's row-constraint update when cells
/// recycle during a resize (see `ContentView.schemeBadge`).
struct SessionIconLegendView: View {
    private struct LegendItem: Identifiable {
        let icon: String
        let color: Color
        let label: String
        let detail: String

        var id: String { label }
    }

    private struct LegendSection: Identifiable {
        let title: String
        let items: [LegendItem]

        var id: String { title }
    }

    private let sections: [LegendSection] = [
        LegendSection(title: "Inspection", items: [
            LegendItem(icon: "globe", color: .secondary, label: "Plain HTTP", detail: "Not encrypted; fully visible."),
            LegendItem(icon: "lock.fill", color: .green, label: "HTTPS inspected", detail: "TLS intercepted; contents visible."),
            LegendItem(icon: "lock.slash", color: .orange, label: "HTTPS tunneled", detail: "TLS passed through; contents hidden.")
        ]),
        LegendSection(title: "Scheme", items: [
            LegendItem(icon: "capsule.fill", color: .orange, label: "HTTP pill", detail: "Unencrypted HTTP request.")
        ]),
        LegendSection(title: "Source (best-effort)", items: [
            LegendItem(icon: "desktopcomputer", color: .blue, label: "Mac", detail: "Mac-native client."),
            LegendItem(icon: "iphone.gen3", color: .teal, label: "Sim", detail: "iOS Simulator."),
            LegendItem(icon: "iphone", color: .green, label: "Device", detail: "Physical device on the network.")
        ]),
        LegendSection(title: "Media", items: [
            LegendItem(icon: "photo", color: .purple, label: "Image", detail: "Image response."),
            LegendItem(icon: "play.tv.fill", color: .blue, label: "HLS", detail: "HLS manifest."),
            LegendItem(icon: "sparkles.rectangle.stack.fill", color: .indigo, label: "Discovered", detail: "Manifest discovered from playback API."),
            LegendItem(icon: "square.stack.3d.forward.dottedline.fill", color: .orange, label: "DASH", detail: "DASH manifest."),
            LegendItem(icon: "film.fill", color: .pink, label: "Video", detail: "Video or media asset."),
            LegendItem(icon: "doc.text.fill", color: .mint, label: "Ad XML", detail: "VAST/VMAP ad XML response.")
        ])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session Icons")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(section.items) { item in
                        legendRow(item)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 260, alignment: .leading)
    }

    private func legendRow(_ item: LegendItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(item.color)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.label)
                    .font(.caption.weight(.medium))
                Text(item.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.label): \(item.detail)")
    }
}

#Preview {
    SessionIconLegendView()
}
