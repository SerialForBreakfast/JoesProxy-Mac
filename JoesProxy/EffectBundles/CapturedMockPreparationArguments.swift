import Foundation

struct CapturedMockPreparationArguments {
    let sessionID: UUID
    let name: String
    let idempotencyKey: String
    let clientAddress: String
    let draftJSON: String

    init(_ arguments: [String: Any]) throws {
        guard let text = arguments["sessionID"] as? String, let id = UUID(uuidString: text) else {
            throw Self.failure("sessionID", "invalidSource", "Select a captured response and supply its session UUID.")
        }
        sessionID = id
        guard let name = arguments["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= EffectBundleBudget.maxNameBytes else {
            throw Self.failure("name", "invalidName", "Supply a nonempty name within the bundle name budget.")
        }
        self.name = name
        guard let key = arguments["idempotencyKey"] as? String, !key.isEmpty, key.utf8.count <= 256 else {
            throw Self.failure("idempotencyKey", "invalidIdempotencyKey", "Supply a nonempty key of at most 256 UTF-8 bytes. Reuse it only for an unchanged preparation request.")
        }
        idempotencyKey = key
        guard let address = arguments["clientAddress"] as? String,
              !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Self.failure("clientAddress", "missingClientScope", "Select the intended captured client address explicitly; preparation must not broaden to all clients.")
        }
        clientAddress = address
        guard let draft = arguments["draftJSON"] as? String,
              draft.utf8.count <= CollectionMockDraftDecoder.maximumInputBytes else {
            throw Self.failure("draftJSON", "invalidDraft", "Supply a typed JSON draft string of at most 64 KiB; use collectionPointer, item or templateIndex, and explicit identityPointers.")
        }
        draftJSON = draft
    }

    static func response(from record: SessionRecord?) throws -> CapturedResponse {
        guard let record, let response = record.response else {
            throw failure("sessionID", "sourceUnavailable", "Select a retained captured response. No upstream refetch is performed.")
        }
        guard record.request.method == "GET" else {
            throw failure("sessionID", "unsupportedMethod", "Select a captured GET response; this authoring workflow does not support other methods.")
        }
        if response.bodyDeferred {
            throw failure("sessionID", "bodyDeferred", "Wait for recording body loading to finish, then prepare again.")
        }
        if response.bodyTruncated {
            throw failure("sessionID", "bodyTruncated", "Select a complete capture or recording; a truncated body cannot establish a complete fixture.")
        }
        if response.recordingBodyOmissionReason != nil {
            throw failure("sessionID", "bodyOmitted", "Select a recording or capture retaining the body. Refetching cannot restore historical evidence.")
        }
        guard response.bodyData != nil else {
            throw failure("sessionID", "bodyUnavailable", "Select a response with retained body bytes. No upstream refetch is performed.")
        }
        return response
    }

    private static func failure(_ field: String, _ reason: String, _ recovery: String) -> CapturedMockPreparationFailure {
        .init(reason: reason, field: field, recovery: recovery)
    }
}
