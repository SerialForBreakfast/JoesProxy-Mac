import Foundation

enum OnboardingLifecycle: String, Codable, Equatable, Sendable {
    case notStarted
    case inProgress
    case completed
    case expertBypassInProgress
    case legacyDismissed
}

enum WorkingViewPreference: String, Codable, Equatable, Sendable {
    case inspector
    case compact
}

enum LaunchWorkspacePreference: String, Codable, Equatable, Sendable {
    case inspector
    case agent
}

/// Durable first-run state only. Runtime readiness and live proxy state never belong in this record.
struct OnboardingProgressRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var lifecycle: OnboardingLifecycle

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        lifecycle: OnboardingLifecycle
    ) {
        self.schemaVersion = schemaVersion
        self.lifecycle = lifecycle
    }
}

/// Safe presentation hints for returning launch projection.
///
/// Contains ONLY non-sensitive layout and target preferences.
/// Volatile runtime facts (proxy running, cert validity, approvals, capture data)
/// NEVER belong in this record.
struct SessionStartPresentationRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var selectedTargetID: String?
    var lastVerificationSummary: String?
    var lastVerifiedAt: Date?
    var reviewedCustomizationHintIDs: Set<String>

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        selectedTargetID: String? = nil,
        lastVerificationSummary: String? = nil,
        lastVerifiedAt: Date? = nil,
        reviewedCustomizationHintIDs: Set<String> = []
    ) {
        self.schemaVersion = schemaVersion
        self.selectedTargetID = selectedTargetID
        self.lastVerificationSummary = lastVerificationSummary
        self.lastVerifiedAt = lastVerifiedAt
        self.reviewedCustomizationHintIDs = reviewedCustomizationHintIDs
    }

    static var `default`: SessionStartPresentationRecord {
        SessionStartPresentationRecord()
    }
}
