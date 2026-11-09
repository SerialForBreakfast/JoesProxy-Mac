import SwiftUI

/// Management sheet allowing developers to view discovered client devices, assign friendly aliases,
/// and inspect live traffic counts per device (Workstream DL).
struct DeviceAliasManagerView: View {
    @Environment(\.appTextScale) private var appTextScale
    @Environment(\.dismiss) private var dismiss
    let devices: [DiscoveredDevice]
    let onSaveAlias: (String, String?) -> Void

    @State private var aliasDrafts: [String: String] = [:]
    @State private var searchText: String = ""

    var filteredDevices: [DiscoveredDevice] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return devices
        }
        let query = searchText.lowercased()
        return devices.filter { device in
            device.ipAddress.lowercased().contains(query) ||
            (device.customAlias?.lowercased().contains(query) ?? false) ||
            device.displayName.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            if devices.isEmpty {
                emptyStateView
            } else {
                searchBar
                deviceListView
            }

            Divider()

            footerView
        }
        .frame(minWidth: 520, minHeight: 400)
        .onAppear {
            for device in devices {
                aliasDrafts[device.ipAddress] = device.customAlias ?? ""
            }
        }
    }

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Discovered Devices & Aliases")
                    .appFont(.headline, scale: appTextScale, weight: .semibold)
                Text("Assign friendly names to devices on your local network that route traffic through JoesProxy.")
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search by IP or alias...", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(6)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var deviceListView: some View {
        List {
            ForEach(filteredDevices) { device in
                HStack(spacing: 12) {
                    Image(systemName: device.systemImageName)
                        .appFont(.title3, scale: appTextScale)
                        .foregroundStyle(device.isLoopback ? Color.accentColor : Color.secondary)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(device.ipAddress)
                                .appFont(.body, scale: appTextScale, weight: .semibold, design: .monospaced)

                            if device.isLoopback {
                                Text("This Mac")
                                    .appFont(.caption2, scale: appTextScale)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.12))
                                    .foregroundStyle(Color.accentColor)
                                    .cornerRadius(4)
                            }
                        }

                        Text("Sessions: \(device.sessionCount) · Last seen: \(device.lastSeen.formatted(date: .omitted, time: .standard))")
                            .appFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    TextField("Alias (e.g. Lab Streaming Device)", text: bindingForIP(device.ipAddress))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onSubmit {
                            saveAlias(for: device.ipAddress)
                        }
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.inset)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "network")
                .appFont(.title2, scale: appTextScale)
                .foregroundStyle(.secondary)
            Text("No Client Devices Discovered Yet")
                .appFont(.headline, scale: appTextScale, weight: .semibold)
            Text("Route traffic from a device, simulator, or container to see it appear here.")
                .appFont(.subheadline, scale: appTextScale)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    private var footerView: some View {
        HStack {
            Text("\(devices.count) device(s) registered")
                .appFont(.caption, scale: appTextScale)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") {
                // Save all pending drafts
                for (ip, alias) in aliasDrafts {
                    let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSaveAlias(ip, trimmed.isEmpty ? nil : trimmed)
                }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    private func bindingForIP(_ ip: String) -> Binding<String> {
        Binding(
            get: { aliasDrafts[ip] ?? "" },
            set: { aliasDrafts[ip] = $0 }
        )
    }

    private func saveAlias(for ip: String) {
        let alias = aliasDrafts[ip]?.trimmingCharacters(in: .whitespacesAndNewlines)
        onSaveAlias(ip, alias?.isEmpty == true ? nil : alias)
    }
}
