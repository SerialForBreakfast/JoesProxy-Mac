#if os(iOS) && DEBUG
import SwiftUI

struct OverlayRootView: View {
    @ObservedObject private var store = OverlayEventStore.shared
    @ObservedObject private var sdk = ProxySDK.shared
    @State private var selectedEvent: NetworkEvent?

    var body: some View {
        VStack(spacing: 0) {
            OverlayHeaderView(
                store: store,
                connectionState: sdk.connectionState,
                onClose: { ProxySDK.shared.hideOverlay() }
            )

            if !store.authCascadeGroups.isEmpty {
                OverlayCascadeChipsView(groups: store.authCascadeGroups)
            }

            Divider()

            if store.events.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.events) { event in
                            OverlayEventRow(event: event)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedEvent = event }
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(
            .rect(
                topLeadingRadius: 16,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 16
            )
        )
        .frame(maxWidth: .infinity)
        .frame(height: UIScreen.main.bounds.height * 0.45)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(edges: .bottom)
        .sheet(item: $selectedEvent) { event in
            RequestDetailView(event: event)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "network")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No requests captured yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OverlayHeaderView: View {
    @ObservedObject var store: OverlayEventStore
    let connectionState: ProxySDKConnectionState
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            connectionPill
            Spacer()
            thirdPartyBadges
            clearButton
            closeButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var connectionPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(connectionColor)
                .frame(width: 7, height: 7)
            Text(connectionLabel)
                .font(.caption.bold())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(connectionColor.opacity(0.15)))
    }

    private var connectionColor: Color {
        switch connectionState {
        case .connected: return .green
        case .connecting, .discovering: return .yellow
        case .rejected, .failed: return .red
        case .disconnected: return .gray
        }
    }

    private var connectionLabel: String {
        switch connectionState {
        case .connected(let host, _, _): return host
        case .connecting: return "Connecting…"
        case .discovering: return "Discovering…"
        case .rejected(_, let compatibility):
            switch compatibility?.compatibilityResolution {
            case .updateJoesProxy: return "Update JoesProxy"
            case .updateSDK: return "Update SDK"
            case .unknown, nil: return "Rejected"
            }
        case .failed: return "Failed"
        case .disconnected: return "Disconnected"
        }
    }

    @ViewBuilder
    private var thirdPartyBadges: some View {
        let summary = store.thirdPartySummary
        if !summary.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(summary.prefix(3)), id: \.key) { name, count in
                    Text("\(name) \(count)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                        .foregroundStyle(Color.orange)
                }
                if summary.count > 3 {
                    Text("+\(summary.count - 3)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var clearButton: some View {
        Button {
            store.clear()
        } label: {
            Image(systemName: "trash")
                .font(.caption.bold())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

private struct OverlayCascadeChipsView: View {
    let groups: [OverlayEventStore.AuthCascadeGroup]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(groups) { group in
                    HStack(spacing: 5) {
                        Image(systemName: "key.horizontal")
                        Text("\(group.cascade.count) req held \(group.holdDurationMs)ms · auth refresh?")
                    }
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.yellow.opacity(0.2)))
                    .foregroundStyle(Color.yellow)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }
}
#endif
