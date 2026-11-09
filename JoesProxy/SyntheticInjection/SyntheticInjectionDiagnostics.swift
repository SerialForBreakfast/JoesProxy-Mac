import Foundation

enum SyntheticInjectionReason: String, Codable, Sendable, Error, CaseIterable {
    case urlMismatch, clientScopeMismatch, unsupportedMedia, inputTooLarge
    case invalidJSON, collectionMissing, collectionNotArray, emptyCollection, templateNotObject
    case transformationFailed, encodingFailed, outputTooLarge, transformed
    case capacityUnavailable

    var recovery: String {
        switch self {
        case .capacityUnavailable: return "Mutation buffering is busy. The original response was forwarded; retry after in-flight responses drain."
        case .urlMismatch: return "Compare the actual request path with the plan matcher."
        case .clientScopeMismatch: return "Review the intended client's headers and the configured scope; do not broaden it automatically."
        case .unsupportedMedia: return "Choose a supported JSON response instead of a streaming media response."
        case .inputTooLarge, .outputTooLarge: return "Reduce the response or injected item; the 5 MiB limit preserves upstream delivery."
        case .invalidJSON: return "Inspect body completeness and content encoding; select a complete supported JSON response."
        case .collectionMissing: return "Select a collection path present in this response."
        case .collectionNotArray: return "Select an array rather than an object or scalar."
        case .emptyCollection: return "Use captured-fixture authoring with an explicit typed item; this legacy mode requires a template."
        case .templateNotObject: return "Choose a collection of object items for schema-inferred injection."
        case .transformationFailed: return "Review the collection path and insertion operation."
        case .encodingFailed: return "Review the synthesized values for JSON compatibility."
        case .transformed: return "Transformation is not delivery or rendering confirmation; inspect the captured response and target separately."
        }
    }
}

enum SyntheticInjectionDeliveryState: String, Codable, Sendable {
    case pending, downstreamWriteSucceeded, downstreamWriteFailed, notApplied
}

/// A registration is not an immutable authored bundle revision. IDs disclose no request content.
struct SyntheticInjectionReceipt: Codable, Equatable, Sendable {
    let requestID: UUID
    let registrationID: UUID
    var sessionID: UUID?
    let reason: SyntheticInjectionReason
    let observedAt: Date
    var deliveryState: SyntheticInjectionDeliveryState
    var deliveryObservedAt: Date?
    private(set) var targetOutcome = "unknown"
}

struct SyntheticInjectionAttribution: Sendable {
    let requestID: UUID
    let registrationID: UUID
}

/// Fixed-cardinality counters and bounded receipts; never retains URLs, headers, or bodies.
struct SyntheticInjectionDiagnostics: Codable, Equatable, Sendable {
    static let receiptLimit = 32
    var receipts: [SyntheticInjectionReceipt] = []
    var counts: [String: UInt64] = [:]
    var lastReason: SyntheticInjectionReason?
    var lastObservedAt: Date?
    var recovery: String?
    var deliveryState = "unknown"
    var targetOutcome = "unknown"

    mutating func recordReceipt(_ reason: SyntheticInjectionReason, attribution: SyntheticInjectionAttribution) {
        guard !receipts.contains(where: { $0.requestID == attribution.requestID }) else { return }
        receipts.append(.init(requestID: attribution.requestID, registrationID: attribution.registrationID,
            reason: reason, observedAt: Date(), deliveryState: reason == .transformed ? .pending : .notApplied))
        if receipts.count > Self.receiptLimit { receipts.removeFirst(receipts.count - Self.receiptLimit) }
    }

    mutating func record(_ reason: SyntheticInjectionReason) {
        let count = counts[reason.rawValue, default: 0]
        counts[reason.rawValue] = count == UInt64.max ? count : count + 1
        lastReason = reason
        recovery = reason.recovery
        lastObservedAt = Date()
    }
}
