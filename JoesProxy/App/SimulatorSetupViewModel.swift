import AppKit
import CryptoKit
import Foundation
import os

@MainActor
final class SimulatorSetupViewModel: ObservableObject {
    enum DiscoveryState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    enum InstallState: Equatable {
        case idle
        case installing
        case succeeded(SimulatorSetupCommandResult)
        case failed(message: String, fallbackCommand: SimulatorSetupCommandResult?)
    }

    @Published private(set) var devices: [SimulatorDevice] = []
    @Published private(set) var discoveryState: DiscoveryState = .idle
    @Published private(set) var installState: InstallState = .idle
    @Published private(set) var verificationResult: SimulatorVerificationResult = .ready
    @Published var selectedDeviceID: SimulatorDevice.ID?
    /// Only booted simulators can receive `simctl openurl` / route traffic, so default to showing them.
    @Published var showBootedOnly: Bool = true
    /// Best-effort JoesProxy Root CA install status per simulator UDID (booted devices only).
    @Published private(set) var certInstallStatusByUDID: [String: SimulatorCertInstallStatus] = [:]
    @Published var manualSimulatorUDID = ""
    @Published private(set) var manualSimulatorSelectionError: String?

    let proxyPort: UInt16

    private let discoveryService: any SimulatorDiscovering
    private let certificateInstaller: any SimulatorCertificateInstalling
    private let verificationService: any SimulatorVerifying
    private let certificateAuthority: any CertificateAuthorityProviding
    private let configuration: AppConfiguration?
    private let trustStoreReader: any SimulatorTrustStoreReading
    private let logger = Logger(subsystem: "com.JoesProxyApp.SimulatorSetup", category: "ViewModel")

    init(
        proxyPort: UInt16,
        discoveryService: any SimulatorDiscovering,
        certificateInstaller: any SimulatorCertificateInstalling,
        verificationService: any SimulatorVerifying,
        certificateAuthority: any CertificateAuthorityProviding,
        configuration: AppConfiguration? = nil,
        trustStoreReader: any SimulatorTrustStoreReading = FileSimulatorTrustStoreReader()
    ) {
        self.proxyPort = proxyPort
        self.discoveryService = discoveryService
        self.certificateInstaller = certificateInstaller
        self.verificationService = verificationService
        self.certificateAuthority = certificateAuthority
        self.configuration = configuration
        self.trustStoreReader = trustStoreReader
    }

    /// Drives the mode-aware consent alert. Set when the user first tries to enable routing and has
    /// not yet acknowledged the risk.
    @Published var pendingRoutingConsent = false

    /// Backs Step 3's routing toggle. Mirrors the Settings preference so enabling it here arms the
    /// system-proxy auto-routing that makes Simulator traffic reach JoesProxy when the proxy runs.
    /// The first enable is gated behind a consent alert (see `pendingRoutingConsent`).
    var isSystemProxyRoutingEnabled: Bool {
        get { configuration?.isSystemProxyManagementEnabled ?? false }
        set {
            objectWillChange.send()
            if newValue, configuration?.hasAcknowledgedSystemProxyRouting != true {
                pendingRoutingConsent = true
                return
            }
            configuration?.isSystemProxyManagementEnabled = newValue
            logger.info("Simulator setup: system proxy routing toggle set to \(newValue, privacy: .public)")
        }
    }

    /// Whether strict (fail-closed) capture is selected. Affects the consent copy.
    var isSystemProxyStrictCapture: Bool {
        configuration?.systemProxyStrictCapture ?? false
    }

    /// Mode-aware consent message shown before routing is first enabled.
    var systemProxyConsentMessage: String {
        SystemProxyRoutingCopy.consentMessage(strictCapture: isSystemProxyStrictCapture)
    }

    func confirmRoutingConsent() {
        configuration?.hasAcknowledgedSystemProxyRouting = true
        pendingRoutingConsent = false
        isSystemProxyRoutingEnabled = true
    }

    func cancelRoutingConsent() {
        pendingRoutingConsent = false
        objectWillChange.send()
    }

    /// The URL JoesProxy opens in the simulator to verify routing.
    var verificationURLString: String {
        SimulatorVerificationService.verificationURL.absoluteString
    }

    /// The Root CA's expiry date, parsed from the current certificate.
    var rootCertificateExpiry: Date? {
        guard let data = certificateAuthority.currentRootCertificate()?.certificateData else { return nil }
        return CertificateValidity.dates(fromDER: data)?.notAfter
    }

    /// Human-readable Root CA validity for display in the walkthrough.
    var rootCertificateExpiryDescription: String {
        guard let expiry = rootCertificateExpiry else {
            return "Root CA validity unavailable."
        }
        let formatted = Self.expiryDateFormatter.string(from: expiry)
        let now = Date()
        if expiry <= now {
            return "⚠️ Root CA expired on \(formatted). Reset the certificate, then reinstall it in the simulator."
        }
        let days = Calendar.current.dateComponents([.day], from: now, to: expiry).day ?? 0
        if days <= 30 {
            return "⚠️ Root CA expires in \(days) day\(days == 1 ? "" : "s") (\(formatted))."
        }
        return "Root CA valid until \(formatted)."
    }

    private static let expiryDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var selectedDevice: SimulatorDevice? {
        guard let selectedDeviceID else { return nil }
        return devices.first { $0.id == selectedDeviceID }
    }

    /// Devices after applying the booted-only filter.
    var filteredDevices: [SimulatorDevice] {
        showBootedOnly ? devices.filter(\.isBooted) : devices
    }

    /// True when the booted-only filter is hiding shutdown simulators that exist.
    var bootedFilterHidesDevices: Bool {
        showBootedOnly && !devices.isEmpty && devices.allSatisfy { !$0.isBooted }
    }

    var devicesByPlatform: [(platform: SimulatorPlatform, devices: [SimulatorDevice])] {
        let visible = filteredDevices
        return SimulatorPlatform.allCases.compactMap { platform in
            let matching = visible.filter { $0.platform == platform }
            return matching.isEmpty ? nil : (platform, matching)
        }
    }

    var installCommandText: String? {
        selectedDevice.map { certificateInstaller.installCommand(for: $0).commandText }
    }

    var verificationCommandText: String? {
        selectedDevice.map { verificationService.verificationCommand(for: $0).commandText }
    }

    var simulatorListCommandText: String {
        "/usr/bin/xcrun simctl list devices"
    }

    var canInstallCertificate: Bool {
        selectedDevice?.isSelectable == true && installState != .installing
    }

    var canVerifyRouting: Bool {
        selectedDevice?.isSelectable == true && verificationResult != .openingURL
    }

    func refreshDevices() {
        Task {
            await refreshDevicesNow()
        }
    }

    func refreshDevicesNow() async {
        logger.info("Simulator setup: refreshing device list")
        discoveryState = .loading
        do {
            let discovered = try await discoveryService.discoverSimulators()
            devices = discovered
            if selectedDeviceID == nil || !discovered.contains(where: { $0.id == selectedDeviceID }) {
                // Prefer a booted, selectable simulator since only booted ones can route traffic.
                selectedDeviceID = discovered.first(where: { $0.isSelectable && $0.isBooted })?.id
                    ?? discovered.first(where: \.isSelectable)?.id
            }
            discoveryState = .loaded
            logger.info("Simulator setup: device list loaded count=\(discovered.count, privacy: .public) selected=\(self.selectedDeviceID ?? "none", privacy: .public)")
            refreshCertInstallStatuses()
        } catch {
            devices = []
            selectedDeviceID = nil
            discoveryState = .failed(error.localizedDescription)
            logger.error("Simulator setup: device discovery failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func selectManualSimulator() {
        let udid = manualSimulatorUDID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !udid.isEmpty else {
            manualSimulatorSelectionError = "Enter a simulator UDID."
            return
        }

        manualSimulatorUDID = udid
        manualSimulatorSelectionError = nil

        if let existingDevice = devices.first(where: { $0.udid == udid }) {
            selectedDeviceID = existingDevice.id
            return
        }

        let device = SimulatorDevice(
            udid: udid,
            name: "Manual Simulator",
            state: "Booted",
            runtimeIdentifier: "Manual UDID",
            runtimeName: nil,
            platform: .unknown,
            supportTier: .limited,
            availability: SimulatorAvailability(isAvailable: true, error: nil)
        )
        devices.append(device)
        selectedDeviceID = device.id
    }

    func certInstallStatus(for device: SimulatorDevice) -> SimulatorCertInstallStatus? {
        certInstallStatusByUDID[device.udid]
    }

    /// Evaluates JoesProxy Root CA install status for every booted device, off the main actor.
    func refreshCertInstallStatuses() {
        guard let certificateData = certificateAuthority.currentRootCertificate()?.certificateData else {
            certInstallStatusByUDID = [:]
            return
        }
        let sha256 = Data(SHA256.hash(data: certificateData))
        let bootedUDIDs = devices.filter(\.isBooted).map(\.udid)
        let reader = trustStoreReader

        Task { [weak self] in
            var results: [String: SimulatorCertInstallStatus] = [:]
            for udid in bootedUDIDs {
                results[udid] = await Task.detached(priority: .utility) {
                    reader.certInstallStatus(udid: udid, certificateSHA256: sha256)
                }.value
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.certInstallStatusByUDID = results
                let installed = results.values.filter { $0 == .installed }.count
                self.logger.info("Simulator setup: cert install status evaluated booted=\(bootedUDIDs.count, privacy: .public) installed=\(installed, privacy: .public)")
            }
        }
    }

    func installCertificateInSelectedSimulator() {
        Task {
            await installCertificateInSelectedSimulatorNow()
        }
    }

    func installCertificateInSelectedSimulatorNow() async {
        guard let selectedDevice else { return }
        installState = .installing
        do {
            let result = try await certificateInstaller.installCertificate(on: selectedDevice)
            installState = .succeeded(result)
            refreshCertInstallStatuses()
        } catch {
            logger.error("Simulator setup: install via app failed, exposing fallback command: \(error.localizedDescription, privacy: .public)")
            installState = .failed(
                message: error.localizedDescription,
                fallbackCommand: certificateInstaller.installCommand(for: selectedDevice)
            )
        }
    }

    func verifySelectedSimulatorRouting() {
        Task {
            await verifySelectedSimulatorRoutingNow()
        }
    }

    func verifySelectedSimulatorRoutingNow() async {
        guard let selectedDevice else { return }
        verificationResult = .openingURL
        verificationResult = await verificationService.verifyHTTPRouting(on: selectedDevice)
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Logs that the user began dragging the certificate icon. Called even when the URL fails so a
    /// drag attempt is always observable in the log.
    func logCertificateDragInitiated() {
        logger.info("Simulator setup: certificate drag initiated")
    }

    /// Writes the root CA to a stable temp file (.cer) and returns its URL for drag-out.
    /// Returns nil if the certificate cannot be loaded or written.
    func rootCertificateDragURL() -> URL? {
        guard let identity = try? certificateAuthority.loadOrCreateRootCertificate() else {
            logger.error("Simulator setup: certificate drag failed — could not load or create Root CA")
            return nil
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("JoesProxy Root CA")
            .appendingPathExtension("cer")
        do {
            try identity.certificateData.write(to: url, options: [.atomic])
            logger.info("Simulator setup: certificate drag file written to \(url.path, privacy: .public)")
            return url
        } catch {
            logger.error("Simulator setup: certificate drag file write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func isSandboxError(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("App Sandbox")
    }
}
