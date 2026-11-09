import Foundation

/// Safe, transport-neutral guidance. Never interpolate captured values, URLs or file paths.
struct CapturedMockPreparationFailure: Error, Equatable, Sendable {
    let reason: String
    let field: String
    let recovery: String

    var message: String { "\(field): \(reason). \(recovery) Nothing was activated." }
    var details: [String: String] {
        ["phase": "preparation", "reason": reason, "field": field,
         "recommendedAction": recovery, "nextTool": "effect_bundle_prepare"]
    }

    /// Keep cancellation and unknown errors intact; only known preparation errors get guidance.
    static func atField<T>(_ field: String, recovery: String? = nil, _ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch {
            guard let failure = describe(error, field: field) else { throw error }
            if error is Self { throw failure }
            throw Self(reason: failure.reason, field: failure.field, recovery: recovery ?? failure.recovery)
        }
    }

    static func describe(_ error: Error, field: String? = nil) -> Self? {
        if let failure = error as? Self { return failure }
        if let error = error as? CollectionMockAuthoringError {
            switch error {
            case .revisionRetired, .revisionNotFound:
                return .init(reason: error.rawValue, field: field ?? "revisionID",
                    recovery: "Inspect any saved bundle before preparing again with a new key. Prepared handles are process-local.")
            case .requestHistoryFull:
                return .init(reason: error.rawValue, field: field ?? "preparation",
                    recovery: "Preparation history is full for this app process. A restart clears it; do not interrupt an active capture automatically.")
            case .capacityExceeded:
                return .init(reason: error.rawValue, field: field ?? "preparation",
                    recovery: "Retire unused prepared handles or reduce the prepared resources before retrying.")
            case .invalidRequest, .idempotencyConflict: break
            }
        }
        if let error = error as? CollectionMockAuthoringError, error == .invalidRequest {
            return .init(reason: error.rawValue, field: field ?? "inputs",
                recovery: "Use complete captured responses and the documented typed draft/related-response fields. Related responses require an identity link; unknown fields are rejected.")
        }
        if let error = error as? CollectionMockDraftDecoder.ValidationError {
            return .init(reason: error.reason, field: field ?? (error.reason == "unknownField" ? "draftJSON" : "draftJSON.\(error.field)"),
                recovery: error.allowedValues.isEmpty ? "Correct the indicated draft field and prepare again."
                    : "Use one of: \(error.allowedValues.joined(separator: ", ")); then prepare again.")
        }
        if let error = error as? CollectionMockError {
            let location: String
            let action: String
            switch error {
            case .invalidJSON:
                location = "source/draftJSON"; action = "Use a complete JSON response and a valid JSON draft. No upstream refetch is performed."
            case .invalidPointer, .missingValue, .incompatibleType:
                location = "draftJSON"; action = "Check collectionPointer and edit pointers against the captured JSON structure and value types."
            case .invalidTemplate:
                location = "draftJSON.templateIndex"; action = "Choose an existing collection item as the template, or supply an explicit item, not both."
            case .missingIdentity, .duplicateIdentity:
                location = "draftJSON.identityPointers"; action = "Check identity pointers and assign unique identities to inserted items."
            case .invalidCount:
                location = "draftJSON"; action = "Use supported collection counts and a valid insertion position."
            case .sizeLimit:
                location = "resources"; action = "Reduce the JSON or image inputs to the documented preparation budgets."
            }
            return .init(reason: error.rawValue, field: field ?? location, recovery: action)
        }
        if let error = error as? CapturedMockImageFile.ImageFileError {
            return .init(reason: error.rawValue, field: field ?? "images",
                recovery: "Select a readable regular image file within budget and mint a fresh file bookmark; then prepare again.")
        }
        if let error = error as? CapturedMockPackageError {
            switch error {
            case .invalidScope:
                return .init(reason: error.rawValue, field: field ?? "scope",
                    recovery: "Use an observed GET request, an explicit client address and supported image delivery URLs.")
            case .duplicateBinding:
                return .init(reason: error.rawValue, field: field ?? "images",
                    recovery: "Bind each primary image pointer once and remove edits targeting the same pointer.")
            case .tooManyImages:
                return .init(reason: error.rawValue, field: field ?? "images", recovery: "Use at most 16 image bindings.")
            case .invalidImage, .unsupportedImage:
                return .init(reason: error.rawValue, field: field ?? "images",
                    recovery: "Choose valid supported image bytes and bind every image to a primary item, batch item or related response using its supplied image-N asset ID.")
            }
        }
        return nil
    }
}
