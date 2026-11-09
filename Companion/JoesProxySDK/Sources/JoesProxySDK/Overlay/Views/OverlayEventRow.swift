#if os(iOS) && DEBUG
import SwiftUI

struct OverlayEventRow: View {
    let event: NetworkEvent

    var body: some View {
        HStack(spacing: 10) {
            methodBadge
            hostPath
            Spacer(minLength: 4)
            trailingInfo
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var methodBadge: some View {
        Text(event.method.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(methodColor))
            .fixedSize()
    }

    private var hostPath: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(event.url.host ?? "")
                .font(.caption.bold())
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text(event.url.path.isEmpty ? "/" : event.url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var trailingInfo: some View {
        HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 1) {
                statusView
                Text(String(format: "%.0fms", event.timing.total * 1000))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            durationBar
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if let code = event.statusCode {
            Text(verbatim: "\(code)")
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(statusColor(for: code))
        } else {
            ProgressView()
                .scaleEffect(0.6)
        }
    }

    private var durationBar: some View {
        let fraction = min(event.timing.total / 3.0, 1.0)
        let width = max(2, CGFloat(fraction) * 40)
        let color: Color = event.statusCode.map(statusColor) ?? .gray
        return RoundedRectangle(cornerRadius: 2)
            .fill(color.opacity(0.8))
            .frame(width: width, height: 22)
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
}
#endif
