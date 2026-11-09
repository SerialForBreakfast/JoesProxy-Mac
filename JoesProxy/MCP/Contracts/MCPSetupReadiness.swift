import Foundation

enum MCPSetupReadinessTarget: String, Codable, CaseIterable, Sendable {
    case macOS = "macOS"
    case iOSiPadOS = "iOS/iPadOS"
    case tvOS = "tvOS"
    case simulator = "Simulator"
    case generic = "generic"
}

enum MCPSetupReadinessCheckState: String, Codable, Sendable {
    case confirmed
    case observed
    case needsUserConfirmation = "needs_user_confirmation"
    case notObservable = "not_observable"
}

enum MCPSetupReadinessActor: String, Codable, Sendable {
    case app
    case agent
    case user
}

struct MCPSetupReadinessCheckDTO: Codable, Equatable, Sendable {
    var id: String
    var state: MCPSetupReadinessCheckState
    var detail: String
    var evidence: String?
    var actor: MCPSetupReadinessActor
    var nextHumanAction: String?
    var confidenceBoundary: String?
}

struct MCPSetupReadinessDTO: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var target: MCPSetupReadinessTarget
    var state: String
    var checks: [MCPSetupReadinessCheckDTO]
    var recommendedNextActions: [String]
    var remoteTrustNotObservable: Bool
}
