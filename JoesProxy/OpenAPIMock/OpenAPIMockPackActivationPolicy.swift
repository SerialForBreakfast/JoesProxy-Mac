import Foundation

/// How overlapping enabled Map Local / Block / Map Remote rows are treated at activate time.
enum OpenAPIMockConflictStrategy: String, Codable, Equatable, Sendable {
    /// Refuse activation and return the overlapping rule list.
    case refuse
    /// Allow activation; AW-3 records the list for rollback.
    case replaceConflicts
}

/// Overlapping live rule. Identifiers and method/path labels only — no bodies.
struct OpenAPIMockOverlappingRule: Equatable, Sendable, Codable {
    var ruleID: UUID
    var method: String
    var pathDescription: String
}

/// Approval/disclosure payload for one pack activation. No bodies and no filesystem paths.
struct OpenAPIMockActivationDisclosure: Equatable, Sendable, Codable {
    var packID: OpenAPIMockPackID
    var originDisplay: String
    var routeCount: Int
    var ttlSeconds: TimeInterval
    var conflictCount: Int
}

/// Inputs for a pure activation check. AW-3 supplies store counts; this type does not read them.
struct OpenAPIMockActivationRequest: Equatable, Sendable {
    var packID: OpenAPIMockPackID
    var owner: OpenAPIMockPackOwner
    var origin: OpenAPIMockOrigin
    var routeCount: Int
    var documentByteCount: Int
    var ttl: TimeInterval
    var activePackCountForOwner: Int
    var retainedPackCount: Int
    var overlappingRules: [OpenAPIMockOverlappingRule]
    var conflictStrategy: OpenAPIMockConflictStrategy
}

/// Result of ``OpenAPIMockPackActivationPolicy/evaluate(_:)``.
enum OpenAPIMockActivationDecision: Equatable, Sendable {
    case allowed(OpenAPIMockActivationDisclosure)
    case refusedBusy
    case refusedConflicts([OpenAPIMockOverlappingRule])
    case refusedBudget(OpenAPIMockPackError)
}

/// One-approval activation rules, owner slot, conflict strategy, and fail-closed relaunch.
enum OpenAPIMockPackActivationPolicy {
    /// Evaluates whether a pack may activate. Does not mutate stores.
    static func evaluate(_ request: OpenAPIMockActivationRequest) -> OpenAPIMockActivationDecision {
        do {
            try OpenAPIMockPackBudget.validateDocumentBytes(request.documentByteCount)
            try OpenAPIMockPackBudget.validateOperationCount(request.routeCount)
            try OpenAPIMockPackBudget.validateTTL(request.ttl)
            try OpenAPIMockPackBudget.validateRetainedPackCount(request.retainedPackCount)
        } catch let error as OpenAPIMockPackError {
            return .refusedBudget(error)
        } catch {
            return .refusedBudget(.documentTooLarge(byteCount: request.documentByteCount))
        }

        if request.activePackCountForOwner >= OpenAPIMockPackBudget.maxActivePacksPerOwner {
            return .refusedBusy
        }

        if !request.overlappingRules.isEmpty, request.conflictStrategy == .refuse {
            return .refusedConflicts(request.overlappingRules)
        }

        return .allowed(
            OpenAPIMockActivationDisclosure(
                packID: request.packID,
                originDisplay: request.origin.displayString,
                routeCount: request.routeCount,
                ttlSeconds: request.ttl,
                conflictCount: request.overlappingRules.count
            )
        )
    }

    /// Fail-closed recovery: a persisted `serving` pack reloads as `stopped`. Live intercept stays off.
    static func relaunchState(from persisted: OpenAPIMockPackState) -> OpenAPIMockPackState {
        switch persisted {
        case .serving:
            return .stopped
        case .inactive, .stopped, .expired, .cleanupRequired:
            return persisted
        }
    }
}
