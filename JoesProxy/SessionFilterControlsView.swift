//
//  SessionFilterControlsView.swift
//  JoesProxy
//
//  Filter bar displayed above the session table and explorer. Includes the
//  search field, domain filter, and the four picker options (method, scheme,
//  status, inspection). The companion filter-option enums (MethodFilterOption,
//  SchemeFilterOption, StatusFilterOption, InspectionFilterOption) live here too.
//

import SwiftUI

struct SessionFilterControlsView: View {
    @Binding var searchText: String
    @Binding var domainFilterText: String
    @Binding var methodFilter: MethodFilterOption
    @Binding var schemeFilter: SchemeFilterOption
    @Binding var inspectionFilter: InspectionFilterOption
    @Binding var statusFilter: StatusFilterOption
    @Binding var sourceFilter: SourceFilterOption
    @Binding var deviceFilterIP: String?
    var discoveredDevices: [DiscoveredDevice] = []
    var onManageDevices: (() -> Void)? = nil

    let controlSize: ControlSize
    let searchFieldMinimumWidth: CGFloat
    let searchFieldIdealWidth: CGFloat
    let searchFieldMaximumWidth: CGFloat
    let domainFilterMinimumWidth: CGFloat
    let domainFilterIdealWidth: CGFloat
    let domainFilterMaximumWidth: CGFloat
    let methodFilterWidth: CGFloat
    let schemeFilterWidth: CGFloat
    let inspectionFilterWidth: CGFloat
    let statusFilterWidth: CGFloat
    let sourceFilterWidth: CGFloat

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                sessionSearchField
                sessionDomainFilterField
                sessionFilterMenus
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    sessionSearchField
                    sessionDomainFilterField
                }

                sessionFilterMenus
            }

            VStack(alignment: .leading, spacing: 8) {
                sessionSearchField
                sessionDomainFilterField

                HStack(spacing: 8) {
                    methodFilterPicker
                    schemeFilterPicker
                }

                HStack(spacing: 8) {
                    inspectionFilterPicker
                    statusFilterPicker
                }

                HStack(spacing: 8) {
                    sourceFilterPicker
                    deviceFilterPicker
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                sessionSearchField
                sessionFilterMenusIconOnly
            }
        }
    }

    private var sessionSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search host, path, method, status, or headers", text: $searchText)
                .textFieldStyle(.plain)
                .help("Search captured sessions by host, path, method, status, headers, and inspection reason.")
                .accessibilityLabel("Search captured sessions")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .frame(
            minWidth: searchFieldMinimumWidth,
            idealWidth: searchFieldIdealWidth,
            maxWidth: searchFieldMaximumWidth
        )
        .accessibilityIdentifier("sessionSearchField")
    }

    private var sessionDomainFilterField: some View {
        TextField("Domain", text: $domainFilterText)
            .textFieldStyle(.roundedBorder)
            .frame(
                minWidth: domainFilterMinimumWidth,
                idealWidth: domainFilterIdealWidth,
                maxWidth: domainFilterMaximumWidth
            )
            .help("Filter visible sessions to hosts containing this text.")
            .accessibilityLabel("Domain filter")
            .accessibilityIdentifier("domainFilterField")
    }

    private var sessionFilterMenus: some View {
        HStack(spacing: 4) {
            methodFilterPicker
            schemeFilterPicker
            inspectionFilterPicker
            statusFilterPicker
            sourceFilterPicker
            deviceFilterPicker
        }
    }

    private func compactFilterLabel(systemImage: String, isActive: Bool) -> some View {
        Image(systemName: systemImage)
            .symbolVariant(isActive ? .fill : .none)
            .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            .frame(width: 22, height: 22)
    }

    private var sessionFilterMenusIconOnly: some View {
        HStack(spacing: 4) {
            Menu {
                Picker("Method", selection: $methodFilter) {
                    ForEach(MethodFilterOption.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.inline)
            } label: {
                compactFilterLabel(systemImage: "arrow.left.arrow.right", isActive: methodFilter != .all)
            }
            .help("Method: \(methodFilter.title)")
            .accessibilityLabel("Method filter")
            .accessibilityIdentifier("methodFilterPickerCompact")

            Menu {
                Picker("Scheme", selection: $schemeFilter) {
                    ForEach(SchemeFilterOption.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.inline)
            } label: {
                compactFilterLabel(systemImage: "lock", isActive: schemeFilter != .all)
            }
            .help("Scheme: \(schemeFilter.title)")
            .accessibilityLabel("Scheme filter")
            .accessibilityIdentifier("schemeFilterPickerCompact")

            Menu {
                Picker("Inspection", selection: $inspectionFilter) {
                    ForEach(InspectionFilterOption.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.inline)
            } label: {
                compactFilterLabel(systemImage: "eye", isActive: inspectionFilter != .all)
            }
            .help("Inspection: \(inspectionFilter.title)")
            .accessibilityLabel("Inspection filter")
            .accessibilityIdentifier("inspectionFilterPickerCompact")

            Menu {
                Picker("Status", selection: $statusFilter) {
                    ForEach(StatusFilterOption.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.inline)
            } label: {
                compactFilterLabel(systemImage: "checkmark.circle", isActive: statusFilter != .all)
            }
            .help("Status: \(statusFilter.title)")
            .accessibilityLabel("Status filter")
            .accessibilityIdentifier("statusFilterPickerCompact")

            Menu {
                Picker("Source", selection: $sourceFilter) {
                    ForEach(SourceFilterOption.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.inline)
            } label: {
                compactFilterLabel(systemImage: "antenna.radiowaves.left.and.right", isActive: sourceFilter != .all)
            }
            .help("Source: \(sourceFilter.title)")
            .accessibilityLabel("Source filter")
            .accessibilityIdentifier("sourceFilterPickerCompact")

            Menu {
                Button("All Devices") {
                    deviceFilterIP = nil
                }
                if !discoveredDevices.isEmpty {
                    Divider()
                    ForEach(discoveredDevices) { device in
                        Button {
                            deviceFilterIP = device.ipAddress
                        } label: {
                            Text(device.displayName)
                        }
                    }
                }
                if let onManageDevices {
                    Divider()
                    Button("Manage Device Aliases...") {
                        onManageDevices()
                    }
                }
            } label: {
                compactFilterLabel(systemImage: "network", isActive: deviceFilterIP != nil)
            }
            .help("Device: \(activeDeviceDisplayName)")
            .accessibilityLabel("Device filter")
            .accessibilityIdentifier("deviceFilterPickerCompact")
        }
    }

    @ViewBuilder
    private func filterMenuLabel(_ category: String, isActive: Bool, activeValue: String) -> some View {
        if isActive {
            Text(activeValue).foregroundStyle(Color.accentColor)
        } else {
            Text(category).foregroundStyle(.secondary)
        }
    }

    private var methodFilterPicker: some View {
        Menu {
            Picker("Method", selection: $methodFilter) {
                ForEach(MethodFilterOption.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            filterMenuLabel("Method", isActive: methodFilter != .all, activeValue: methodFilter.title)
        }
        .controlSize(controlSize)
        .help("Filter visible sessions by HTTP method.")
        .accessibilityLabel("Method filter")
        .accessibilityValue(methodFilter.title)
        .accessibilityIdentifier("methodFilterPicker")
    }

    private var schemeFilterPicker: some View {
        Menu {
            Picker("Scheme", selection: $schemeFilter) {
                ForEach(SchemeFilterOption.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            filterMenuLabel("Scheme", isActive: schemeFilter != .all, activeValue: schemeFilter.title)
        }
        .controlSize(controlSize)
        .help("Filter visible sessions by URL scheme.")
        .accessibilityLabel("Scheme filter")
        .accessibilityValue(schemeFilter.title)
        .accessibilityIdentifier("schemeFilterPicker")
    }

    private var inspectionFilterPicker: some View {
        Menu {
            Picker("Inspection", selection: $inspectionFilter) {
                ForEach(InspectionFilterOption.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            filterMenuLabel("Inspection", isActive: inspectionFilter != .all, activeValue: inspectionFilter.title)
        }
        .controlSize(controlSize)
        .help("Filter visible sessions by inspection mode, including tunneled HTTPS traffic.")
        .accessibilityLabel("Inspection filter")
        .accessibilityValue(inspectionFilter.title)
        .accessibilityIdentifier("inspectionFilterPicker")
    }

    private var statusFilterPicker: some View {
        Menu {
            Picker("Status", selection: $statusFilter) {
                ForEach(StatusFilterOption.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            filterMenuLabel("Status", isActive: statusFilter != .all, activeValue: statusFilter.title)
        }
        .controlSize(controlSize)
        .help("Filter by HTTP status (2xx–5xx) or Conn. Failed for upstream connection errors.")
        .accessibilityLabel("Status filter")
        .accessibilityValue(statusFilter.title)
        .accessibilityIdentifier("statusFilterPicker")
    }

    private var sourceFilterPicker: some View {
        Menu {
            Picker("Source", selection: $sourceFilter) {
                ForEach(SourceFilterOption.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            filterMenuLabel("Source", isActive: sourceFilter != .all, activeValue: sourceFilter.title)
        }
        .controlSize(controlSize)
        .help("Filter visible sessions by traffic source (Mac, Simulator, or Device). Best-effort; tunneled HTTPS is Unknown.")
        .accessibilityLabel("Source filter")
        .accessibilityValue(sourceFilter.title)
        .accessibilityIdentifier("sourceFilterPicker")
    }

    private var activeDeviceDisplayName: String {
        guard let deviceFilterIP else {
            return "All"
        }
        if let dev = discoveredDevices.first(where: { $0.ipAddress == deviceFilterIP }) {
            return dev.displayName
        }
        return deviceFilterIP
    }

    private var deviceFilterPicker: some View {
        Menu {
            Button("All Devices") {
                deviceFilterIP = nil
            }
            if !discoveredDevices.isEmpty {
                Divider()
                ForEach(discoveredDevices) { device in
                    Button {
                        deviceFilterIP = device.ipAddress
                    } label: {
                        HStack {
                            Text(device.displayName)
                            if device.displayName != device.ipAddress {
                                Text("(\(device.ipAddress))")
                            }
                        }
                    }
                }
            }
            if let onManageDevices {
                Divider()
                Button("Manage Device Aliases...") {
                    onManageDevices()
                }
            }
        } label: {
            filterMenuLabel("Device", isActive: deviceFilterIP != nil, activeValue: activeDeviceDisplayName)
        }
        .controlSize(controlSize)
        .help("Filter visible sessions to traffic from a specific client IP address or alias.")
        .accessibilityLabel("Device filter")
        .accessibilityValue(activeDeviceDisplayName)
        .accessibilityIdentifier("deviceFilterPicker")
    }
}

enum MethodFilterOption: String, CaseIterable, Identifiable {
    case all
    case get
    case post
    case put
    case patch
    case delete

    var id: String { rawValue }

    init(method: String?) {
        guard let method,
              let option = Self(rawValue: method.lowercased()) else {
            self = .all
            return
        }
        self = option
    }

    var title: String {
        switch self {
        case .all:
            return "Any"
        default:
            return rawValue.uppercased()
        }
    }

    var method: String? {
        switch self {
        case .all:
            return nil
        default:
            return rawValue.uppercased()
        }
    }
}

enum SchemeFilterOption: String, CaseIterable, Identifiable {
    case all
    case http
    case https

    var id: String { rawValue }

    init(scheme: SessionScheme?) {
        switch scheme {
        case .http:
            self = .http
        case .https:
            self = .https
        case nil:
            self = .all
        }
    }

    var title: String {
        switch self {
        case .all:
            return "Any"
        case .http:
            return "HTTP"
        case .https:
            return "HTTPS"
        }
    }

    var scheme: SessionScheme? {
        switch self {
        case .all:
            return nil
        case .http:
            return .http
        case .https:
            return .https
        }
    }
}

enum StatusFilterOption: String, CaseIterable, Identifiable {
    case all
    case successful
    case redirect
    case clientError
    case serverError
    case failedConnections

    var id: String { rawValue }

    init(match: SessionFilterCriteria.StatusMatch?) {
        switch match {
        case .range(200...299):
            self = .successful
        case .range(300...399):
            self = .redirect
        case .range(400...499):
            self = .clientError
        case .range(500...599):
            self = .serverError
        case .failedConnection:
            self = .failedConnections
        default:
            self = .all
        }
    }

    var title: String {
        switch self {
        case .all:
            return "Any"
        case .successful:
            return "2xx"
        case .redirect:
            return "3xx"
        case .clientError:
            return "4xx"
        case .serverError:
            return "5xx"
        case .failedConnections:
            return "Conn. Failed"
        }
    }

    var match: SessionFilterCriteria.StatusMatch? {
        switch self {
        case .all:
            return nil
        case .successful:
            return .range(200...299)
        case .redirect:
            return .range(300...399)
        case .clientError:
            return .range(400...499)
        case .serverError:
            return .range(500...599)
        case .failedConnections:
            return .failedConnection
        }
    }
}

enum InspectionFilterOption: String, CaseIterable, Identifiable {
    case all
    case http
    case inspected
    case notTunneled
    case tunneled

    var id: String { rawValue }

    init(inspectionMatch: SessionFilterCriteria.InspectionMatch?) {
        switch inspectionMatch {
        case .exact(.plain):
            self = .http
        case .exact(.interceptedTLS):
            self = .inspected
        case .exact(.tunneledTLS):
            self = .tunneled
        case .notTunneled:
            self = .notTunneled
        case nil:
            self = .all
        }
    }

    var title: String {
        switch self {
        case .all:
            return "Any"
        case .http:
            return "HTTP"
        case .inspected:
            return "Inspected"
        case .notTunneled:
            return "Not Tunneled"
        case .tunneled:
            return "Tunneled"
        }
    }

    var inspectionMatch: SessionFilterCriteria.InspectionMatch? {
        switch self {
        case .all:
            return nil
        case .http:
            return .exact(.plain)
        case .inspected:
            return .exact(.interceptedTLS)
        case .notTunneled:
            return .notTunneled
        case .tunneled:
            return .exact(.tunneledTLS)
        }
    }
}

enum SourceFilterOption: String, CaseIterable, Identifiable {
    case all
    case mac
    case simulator
    case device
    case unknown

    var id: String { rawValue }

    init(source: TrafficSource?) {
        switch source {
        case .mac: self = .mac
        case .simulator: self = .simulator
        case .device: self = .device
        case .unknown: self = .unknown
        case nil: self = .all
        }
    }

    var title: String {
        switch self {
        case .all: return "Any"
        case .mac: return "Mac"
        case .simulator: return "Simulator"
        case .device: return "Device"
        case .unknown: return "Unknown"
        }
    }

    var source: TrafficSource? {
        switch self {
        case .all: return nil
        case .mac: return .mac
        case .simulator: return .simulator
        case .device: return .device
        case .unknown: return .unknown
        }
    }
}
