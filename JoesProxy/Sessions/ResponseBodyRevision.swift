import CryptoKit
import Foundation

/// Immutable bytes and provenance for one captured or draft response-body revision.
struct ResponseBodyRevision: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case capturedSession(sessionID: SessionRecord.ID, captureSequence: UInt64)
        case draftRevision(draftID: UUID, revision: Int)
    }

    enum Representation: Equatable, Sendable {
        case raw
        case decodedIdentity
    }

    enum CompletenessStatus: Equatable, Sendable {
        case complete
        case captureTruncated
        case decodeTruncated
        case unsupportedEncoding
        case invalidUTF8
        case decodeFailed
        case bodyDeferred
        case bodyOmitted
    }

    let revisionID: UUID
    let clientID: String
    let source: Source
    let representation: Representation
    let bodyBytes: Data
    let bodySHA256: String
    let statusCode: Int
    let contentType: String?
    let charset: String?
    let completeness: CompletenessStatus
    let createdAt: Date
    let parentRevisionID: UUID?

    /// Builds a decoded-identity revision through the same bounded capture decoder used by MCP
    /// inspection and disclosure. Returns metadata even when the body is not UTF-8-editable; callers
    /// that require searchable text must check ``CompletenessStatus/complete`` and UTF-8 validity.
    ///
    /// Concurrency: `@MainActor` because it reads ``MCPSessionSnapshotService`` session state.
    @MainActor
    static func fromCapturedSession(
        _ sessionID: SessionRecord.ID,
        snapshotService: MCPSessionSnapshotService,
        clientID: String,
        maxBytes: Int
    ) throws -> ResponseBodyRevision {
        guard let indexed = snapshotService.indexedSession(id: sessionID),
              let response = indexed.record.response,
              let bodyData = response.bodyData else {
            throw ResponseBodyRevisionError.bodyUnavailable
        }
        guard maxBytes > 0 else {
            throw ResponseBodyRevisionError.invalidLimit
        }

        let decoded = CapturedBodyDecoder.decode(
            bodyData: bodyData,
            headers: response.headers,
            maxDecodedBytes: maxBytes
        )
        let representation: Representation
        let bodyBytes: Data
        var completeness: CompletenessStatus
        if let decoded {
            representation = decoded.appliedCodings.isEmpty ? .raw : .decodedIdentity
            if decoded.isKnownBinaryContentType {
                bodyBytes = Data()
                completeness = .unsupportedEncoding
            } else if !decoded.canUseAnalysisDataForInspection {
                bodyBytes = Data()
                completeness = completenessStatus(
                    decodeStatus: decoded.status,
                    isUTF8: false,
                    capturedBytes: bodyData.count,
                    reportedBytes: response.bodySize
                )
            } else if let text = decoded.analysisUTF8Text() {
                let textBytes = Data(text.utf8)
                guard textBytes.count <= maxBytes else {
                    throw ResponseBodyRevisionError.bodyExceedsLimit
                }
                bodyBytes = textBytes
                completeness = completenessStatus(
                    decodeStatus: decoded.status,
                    isUTF8: true,
                    capturedBytes: bodyData.count,
                    reportedBytes: response.bodySize
                )
            } else {
                bodyBytes = Data()
                completeness = .invalidUTF8
            }
        } else {
            representation = .raw
            bodyBytes = Data()
            completeness = bodyData.count < (response.bodySize ?? bodyData.count)
                ? .captureTruncated
                : .unsupportedEncoding
        }

        // Explicit retention evidence takes precedence over apparently complete retained bytes.
        if response.bodyDeferred {
            completeness = .bodyDeferred
        } else if response.recordingBodyOmissionReason != nil {
            completeness = .bodyOmitted
        } else if response.bodyTruncated {
            completeness = .captureTruncated
        }

        return ResponseBodyRevision(
            revisionID: UUID(),
            clientID: clientID,
            source: .capturedSession(
                sessionID: sessionID,
                captureSequence: indexed.captureSequence
            ),
            representation: representation,
            bodyBytes: bodyBytes,
            bodySHA256: sha256Hex(bodyBytes.isEmpty ? bodyData : bodyBytes),
            statusCode: response.statusCode,
            contentType: contentType(from: response.headers),
            charset: charset(from: response.headers),
            completeness: completeness,
            createdAt: Date(),
            parentRevisionID: nil
        )
    }

    private static func completenessStatus(
        decodeStatus: CapturedBodyDecodeStatus,
        isUTF8: Bool,
        capturedBytes: Int,
        reportedBytes: Int?
    ) -> CompletenessStatus {
        if let reportedBytes, capturedBytes < reportedBytes {
            return .captureTruncated
        }
        switch decodeStatus {
        case .limitExceeded:
            return .decodeTruncated
        case .unsupported:
            return .unsupportedEncoding
        case .failed:
            return .decodeFailed
        case .unchanged, .decoded:
            return isUTF8 ? .complete : .invalidUTF8
        }
    }

    private static func contentType(from headers: [HTTPHeaderField]) -> String? {
        headers.first {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value.split(separator: ";", maxSplits: 1).first.map(String.init)
    }

    private static func charset(from headers: [HTTPHeaderField]) -> String? {
        guard let value = headers.first(where: {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        })?.value else {
            return nil
        }
        return value.split(separator: ";").dropFirst().compactMap { parameter in
            let pieces = parameter.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard pieces.count == 2, pieces[0].caseInsensitiveCompare("charset") == .orderedSame else {
                return nil
            }
            return pieces[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }.first
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum ResponseBodyRevisionError: Error, Equatable, Sendable {
    case bodyUnavailable
    case invalidLimit
    case bodyExceedsLimit
}
