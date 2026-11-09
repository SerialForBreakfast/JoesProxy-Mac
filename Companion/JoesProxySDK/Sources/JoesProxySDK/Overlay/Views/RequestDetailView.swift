#if os(iOS) && DEBUG
import SwiftUI
import UIKit

struct RequestDetailView: View {
    let event: NetworkEvent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                urlSection
                timingSection
                connectionSection
                if event.cacheStatus != nil { cacheSection }
                if event.redirectCount > 0 || event.retryCount > 0 { retriesSection }
                if !event.annotations.isEmpty { annotationsSection }
                deepLinkSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Request Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    private var urlSection: some View {
        Section("Request") {
            LabeledContent("Method") {
                Text(event.method.uppercased())
                    .font(.body.bold())
                    .foregroundStyle(methodColor)
            }
            LabeledContent("URL") {
                Text(event.url.absoluteString)
                    .font(.caption.monospaced())
                    .multilineTextAlignment(.trailing)
                    .lineLimit(4)
            }
            if let code = event.statusCode {
                LabeledContent("Status") {
                    Text(verbatim: "\(code)")
                        .font(.body.bold().monospacedDigit())
                        .foregroundStyle(statusColor(for: code))
                }
            }
            LabeledContent("Phase") {
                Text(event.phase.rawValue.capitalized)
            }
        }
    }

    private var timingSection: some View {
        Section("Timing") {
            TimingBreakdownView(timing: event.timing)
                .frame(height: 60)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))

            timingRow("TTFB",     ms: event.timing.ttfb)
            timingRow("Transfer", ms: event.timing.transfer)
            timingRow("Total",    ms: event.timing.total, bold: true)
            if let dns = event.timing.dns { timingRow("DNS",  ms: dns) }
            if let tcp = event.timing.tcp { timingRow("TCP",  ms: tcp) }
            if let tls = event.timing.tls { timingRow("TLS",  ms: tls) }
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            LabeledContent("Protocol") { Text(event.connectionInfo.httpProtocol) }
            LabeledContent("Reused") {
                Text(event.connectionInfo.isConnectionReused ? "Yes" : "No")
            }
            if let region = event.connectionInfo.cdnRegion {
                LabeledContent("CDN Region") { Text(region) }
            }
            LabeledContent("Sizes") {
                Text("\(formatBytes(event.sizes.responseBytes)) ↓  \(formatBytes(event.sizes.requestBytes)) ↑")
                    .font(.caption.monospaced())
            }
        }
    }

    private var cacheSection: some View {
        Section("Cache") {
            if let status = event.cacheStatus {
                LabeledContent("Status") {
                    Text(status.rawValue.capitalized)
                        .font(.body.bold())
                        .foregroundStyle(cacheColor(status))
                }
            }
        }
    }

    private var retriesSection: some View {
        Section("Reliability") {
            if event.retryCount > 0 {
                LabeledContent("Retries") {
                    Text(verbatim: "\(event.retryCount)")
                        .foregroundStyle(.red)
                }
            }
            if event.redirectCount > 0 {
                LabeledContent("Redirects") { Text(verbatim: "\(event.redirectCount)") }
            }
        }
    }

    private var annotationsSection: some View {
        Section("Annotations") {
            ForEach(event.annotations, id: \.self) { label in
                Text(label).font(.caption)
            }
        }
    }

    private var deepLinkSection: some View {
        Section {
            Button {
                let urlStr = "joesproxy://session/\(event.sessionID)"
                if let url = URL(string: urlStr) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open in JoesProxy", systemImage: "macwindow.badge.plus")
            }
        }
    }

    // MARK: - Helpers

    private func timingRow(_ label: String, ms: Double, bold: Bool = false) -> some View {
        LabeledContent(label) {
            Text(String(format: "%.1fms", ms * 1000))
                .font(bold ? .body.bold().monospacedDigit() : .body.monospacedDigit())
        }
    }

    private var methodColor: Color {
        switch event.method.uppercased() {
        case "GET":     return .blue
        case "POST":    return .green
        case "PUT":     return .orange
        case "DELETE":  return .red
        case "PATCH":   return .purple
        default:        return .gray
        }
    }

    private func statusColor(for code: Int) -> Color {
        switch code {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return Color(red: 0.9, green: 0.6, blue: 0.1)
        case 500...:    return .red
        default:        return .gray
        }
    }

    private func cacheColor(_ status: CDNCacheStatus) -> Color {
        switch status {
        case .hit:     return .green
        case .miss:    return .red
        case .stale:   return Color(red: 0.9, green: 0.6, blue: 0.1)
        default:       return .gray
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        if bytes < 1024 * 1024 { return String(format: "%.1fKB", Double(bytes) / 1024) }
        return String(format: "%.1fMB", Double(bytes) / (1024 * 1024))
    }
}

// MARK: - Timing Breakdown Bar

struct TimingBreakdownView: View {
    let timing: NetworkTiming

    private struct Segment: Identifiable {
        let id: String
        let label: String
        let value: Double
        let color: Color
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        if let dns = timing.dns, dns > 0 { result.append(.init(id: "dns", label: "DNS", value: dns, color: .purple)) }
        if let tcp = timing.tcp, tcp > 0 { result.append(.init(id: "tcp", label: "TCP", value: tcp, color: .blue)) }
        if let tls = timing.tls, tls > 0 { result.append(.init(id: "tls", label: "TLS", value: tls, color: .teal)) }
        let known = (timing.dns ?? 0) + (timing.tcp ?? 0) + (timing.tls ?? 0)
        let wait = max(0, timing.ttfb - known)
        if wait > 0 { result.append(.init(id: "wait", label: "Wait", value: wait, color: .orange)) }
        if timing.transfer > 0 { result.append(.init(id: "xfer", label: "Xfer", value: timing.transfer, color: Color(.systemGray3))) }
        return result
    }

    var body: some View {
        GeometryReader { geo in
            let total = timing.total > 0 ? timing.total : 1
            VStack(alignment: .leading, spacing: 4) {
                // Bar
                HStack(spacing: 1) {
                    ForEach(segments) { seg in
                        Rectangle()
                            .fill(seg.color)
                            .frame(width: max(1, geo.size.width * CGFloat(seg.value / total)))
                    }
                }
                .frame(height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                // Labels
                HStack(spacing: 0) {
                    ForEach(segments) { seg in
                        Text("\(seg.label) \(String(format: "%.0f", seg.value * 1000))ms")
                            .font(.system(size: 9))
                            .foregroundStyle(seg.color)
                            .frame(width: max(1, geo.size.width * CGFloat(seg.value / total)), alignment: .leading)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}
#endif
