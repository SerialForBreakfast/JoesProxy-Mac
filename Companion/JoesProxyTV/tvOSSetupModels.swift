import Foundation

/// Ordered setup screens for the tvOS companion app.
enum TVOSSetupStep: Int, CaseIterable, Identifiable, Codable, Sendable {
    case welcome
    case findMac
    case checkReachability
    case openHiddenProfilesMenu
    case installProfile
    case trustCertificate
    case verifyTraffic
    case troubleshooting

    var id: Int { rawValue }

    /// Linear setup steps excluding welcome and troubleshooting.
    static var progressSteps: [TVOSSetupStep] {
        allCases.filter { $0 != .welcome && $0 != .troubleshooting }
    }

    var title: String {
        switch self {
        case .welcome:
            return "Welcome"
        case .findMac:
            return "Find Your Mac"
        case .checkReachability:
            return "Check Connection"
        case .openHiddenProfilesMenu:
            return "Open Profiles Menu"
        case .installProfile:
            return "Install Profile"
        case .trustCertificate:
            return "Trust Certificate"
        case .verifyTraffic:
            return "Verify Traffic"
        case .troubleshooting:
            return "Troubleshooting"
        }
    }

    var railTitle: String {
        switch self {
        case .welcome:
            return "Welcome"
        case .findMac:
            return "Find Mac"
        case .checkReachability:
            return "Check Route"
        case .openHiddenProfilesMenu:
            return "Profiles Menu"
        case .installProfile:
            return "Install Profile"
        case .trustCertificate:
            return "Trust Cert"
        case .verifyTraffic:
            return "Verify Traffic"
        case .troubleshooting:
            return "Troubleshoot"
        }
    }

    var railSubtitle: String {
        switch self {
        case .welcome:
            return "Start here"
        case .findMac:
            return "Discover the Mac"
        case .checkReachability:
            return "Confirm profile URL"
        case .openHiddenProfilesMenu:
            return "Open hidden screen"
        case .installProfile:
            return "Add local profile"
        case .trustCertificate:
            return "Enable root trust"
        case .verifyTraffic:
            return "Confirm capture"
        case .troubleshooting:
            return "Fix blockers"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome:
            return "JoesProxy runs on your Mac. This app guides Apple TV setup."
        case .findMac:
            return "Enter or discover the Mac running JoesProxy."
        case .checkReachability:
            return "Confirm the Apple TV can reach the profile server."
        case .openHiddenProfilesMenu:
            return "Use the hidden tvOS Profiles screen."
        case .installProfile:
            return "Install the local JoesProxy profile."
        case .trustCertificate:
            return "Enable trust for the JoesProxy root CA."
        case .verifyTraffic:
            return "Confirm traffic appears in JoesProxy."
        case .troubleshooting:
            return "Fix common setup blockers."
        }
    }
}

/// User-visible status for each setup step.
enum TVOSSetupStepStatus: Equatable, Sendable {
    case notStarted
    case inProgress
    case passed
    case manualConfirmed
    case blocked(TVOSSetupIssue)

    var isComplete: Bool {
        switch self {
        case .passed, .manualConfirmed:
            return true
        case .notStarted, .inProgress, .blocked:
            return false
        }
    }
}

/// Setup blockers the companion can explain without pretending to fix tvOS Settings directly.
enum TVOSSetupIssue: Equatable, Sendable {
    case macNotFound
    case invalidMacHost
    case profileServerUnavailable
    case firewallLikelyBlocking
    case differentNetworkLikely
    case certificateTrustMissing
    case appLikelyPinned

    var title: String {
        switch self {
        case .macNotFound:
            return "Mac not found"
        case .invalidMacHost:
            return "Host is invalid"
        case .profileServerUnavailable:
            return "Profile server unavailable"
        case .firewallLikelyBlocking:
            return "Firewall may be blocking"
        case .differentNetworkLikely:
            return "Different network likely"
        case .certificateTrustMissing:
            return "Certificate trust missing"
        case .appLikelyPinned:
            return "App may use certificate pinning"
        }
    }

    var recovery: String {
        switch self {
        case .macNotFound:
            return "Start JoesProxy on your Mac and keep the Apple TV on the same local network."
        case .invalidMacHost:
            return "Enter a Mac IP address or Bonjour name, for example 192.168.1.20."
        case .profileServerUnavailable:
            return "Open the Apple TV setup guide in JoesProxy on the Mac so it starts the profile server."
        case .firewallLikelyBlocking:
            return "Allow incoming connections for JoesProxy in macOS Firewall settings."
        case .differentNetworkLikely:
            return "Put the Mac and Apple TV on the same Wi-Fi network or subnet."
        case .certificateTrustMissing:
            return "Open Settings > General > About > Certificate Trust Settings and enable JoesProxy Root CA."
        case .appLikelyPinned:
            return "Some streaming apps reject user-installed certificates. Try another app or inspect only unpinned traffic."
        }
    }
}

/// Result of the tvOS companion's direct verification ping through the configured proxy.
enum TVOSTrafficVerificationResult: Equatable, Sendable {
    case ready
    case pinging
    case watchingForCapture
    case trafficInspected(host: String)
    case trafficTunneled(host: String)
    case trafficObserved(host: String)
    case noTrafficObserved
    case failed(String)

    var isSuccess: Bool {
        switch self {
        case .trafficInspected, .trafficTunneled, .trafficObserved:
            return true
        default:
            return false
        }
    }
}

/// Result of probing the Mac-hosted profile server from the Apple TV.
enum TVOSReachabilityResult: Equatable, Sendable {
    case notChecked
    case checking
    case reachable(baseURL: URL, profileURL: URL)
    case blocked(TVOSSetupIssue)
}

/// A Mac running JoesProxy, discovered or entered manually.
struct TVOSDiscoveredProxy: Identifiable, Equatable, Sendable {
    var id: String { "\(host):\(profilePort)" }

    let name: String
    let host: String
    let proxyPort: Int
    let profilePort: Int
    let sdkPort: Int?
    let profilePath: String

    init(
        name: String,
        host: String,
        proxyPort: Int,
        profilePort: Int,
        sdkPort: Int?,
        profilePath: String
    ) {
        self.name = name
        self.host = Self.normalizedHost(host)
        self.proxyPort = proxyPort
        self.profilePort = profilePort
        self.sdkPort = sdkPort
        self.profilePath = profilePath
    }

    var profileBaseURL: URL? {
        URL(string: "http://\(host):\(profilePort)")
    }

    var profileURL: URL? {
        profileBaseURL?.appendingPathComponent(profilePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    static func normalizedHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(".") else {
            return trimmed
        }
        return String(trimmed.dropLast())
    }

    static let fixture = TVOSDiscoveredProxy(
        name: "JoesProxy on Mac",
        host: "192.168.1.20",
        proxyPort: 9090,
        profilePort: 8765,
        sdkPort: 9091,
        profilePath: "profile"
    )
}
