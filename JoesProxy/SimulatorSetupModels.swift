import Foundation

enum SimulatorPlatform: String, CaseIterable, Sendable {
    case iOS
    case iPadOS
    case tvOS
    case visionOS
    case watchOS
    case unknown

    var title: String {
        switch self {
        case .iOS:
            return "iOS"
        case .iPadOS:
            return "iPadOS"
        case .tvOS:
            return "tvOS"
        case .visionOS:
            return "visionOS"
        case .watchOS:
            return "watchOS"
        case .unknown:
            return "Other"
        }
    }
}

enum SimulatorSupportTier: String, Sendable {
    case verifiedFirst
    case expected
    case limited
    case outOfScope

    var title: String {
        switch self {
        case .verifiedFirst:
            return "Verified first"
        case .expected:
            return "Expected"
        case .limited:
            return "Limited"
        case .outOfScope:
            return "Out of scope"
        }
    }

    var detail: String {
        switch self {
        case .verifiedFirst:
            return "Best supported path for simulator setup."
        case .expected:
            return "Expected to work, but verify on this runtime."
        case .limited:
            return "Requires developer-owned app validation."
        case .outOfScope:
            return "Not included in this simulator setup slice."
        }
    }
}

struct SimulatorAvailability: Equatable, Sendable {
    let isAvailable: Bool
    let error: String?

    var displayText: String {
        if isAvailable {
            return "Available"
        }
        return error ?? "Unavailable"
    }
}

struct SimulatorDevice: Identifiable, Equatable, Sendable {
    let udid: String
    let name: String
    let state: String
    let runtimeIdentifier: String
    let runtimeName: String?
    let platform: SimulatorPlatform
    let supportTier: SimulatorSupportTier
    let availability: SimulatorAvailability

    var id: String { udid }

    var isBooted: Bool {
        state == "Booted"
    }

    var isSelectable: Bool {
        availability.isAvailable && supportTier != .outOfScope
    }
}

struct SimulatorSetupCommandResult: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    var commandText: String {
        ([executablePath] + arguments).map(Self.shellQuoted).joined(separator: " ")
    }

    private static func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-:=@"))
        if value.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum SimulatorVerificationResult: Equatable, Sendable {
    case ready
    case openingURL
    case captured(SessionRecord.ID)
    case noTrafficDetected
    case commandFailed(String)

    var title: String {
        switch self {
        case .ready:
            return "Ready"
        case .openingURL:
            return "Opening URL"
        case .captured:
            return "Captured"
        case .noTrafficDetected:
            return "No traffic detected"
        case .commandFailed:
            return "Command failed"
        }
    }
}

struct SimulatorCommandExecutionResult: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    var setupResult: SimulatorSetupCommandResult {
        SimulatorSetupCommandResult(
            executablePath: executableURL.path,
            arguments: arguments,
            exitCode: exitCode,
            standardOutput: standardOutput,
            standardError: standardError
        )
    }
}
