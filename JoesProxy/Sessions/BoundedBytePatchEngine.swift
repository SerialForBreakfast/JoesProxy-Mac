import CryptoKit
import Foundation

/// Applies pre-resolved, bounded byte edits atomically.
///
/// Callers resolve text or format-specific matches before entering this type. The engine only
/// validates ranges and source hashes, so it can safely serve text, encoded text, or binary data
/// without reserializing the response.
enum BoundedBytePatchEngine {
    enum PatchError: Error, Equatable, Sendable {
        case emptyPatchSet
        case duplicatePatch(patchID: UUID)
        case overlappingRanges(Range<Int>, Range<Int>)
        case outOfBounds(Range<Int>)
        case staleSourceHash(expected: String, actual: String)
        case excessivePatchCount(Int)
        case excessiveReplacementSize(Int)
        case splitsUTF8Scalar(Range<Int>)
    }

    struct Result: Equatable, Sendable {
        let data: Data
        let originalSHA256: String
        let patchedSHA256: String
        let perPatchByteCounts: [(patchID: UUID, oldByteCount: Int, newByteCount: Int)]

        static func == (lhs: Result, rhs: Result) -> Bool {
            lhs.data == rhs.data
                && lhs.originalSHA256 == rhs.originalSHA256
                && lhs.patchedSHA256 == rhs.patchedSHA256
                && lhs.perPatchByteCounts.count == rhs.perPatchByteCounts.count
                && zip(lhs.perPatchByteCounts, rhs.perPatchByteCounts).allSatisfy {
                    $0.0.patchID == $0.1.patchID
                        && $0.0.oldByteCount == $0.1.oldByteCount
                        && $0.0.newByteCount == $0.1.newByteCount
                }
        }
    }

    private static let maxPatchCount = 100
    private static let maxReplacementBytes = 4 * 1024

    /// Validates every patch before applying any edit, then applies ranges from right to left.
    static func apply(originalBytes: Data, patches: [ResolvedPatch]) throws -> Result {
        guard !patches.isEmpty else {
            throw PatchError.emptyPatchSet
        }
        guard patches.count <= maxPatchCount else {
            throw PatchError.excessivePatchCount(patches.count)
        }

        var patchIDs = Set<UUID>()
        let originalHash = sha256Hex(originalBytes)
        for patch in patches {
            guard patchIDs.insert(patch.patchID).inserted else {
                throw PatchError.duplicatePatch(patchID: patch.patchID)
            }
            guard patch.replacementBytes.count <= maxReplacementBytes else {
                throw PatchError.excessiveReplacementSize(patch.replacementBytes.count)
            }
            guard patch.byteRange.lowerBound >= 0,
                  patch.byteRange.upperBound >= patch.byteRange.lowerBound,
                  patch.byteRange.upperBound <= originalBytes.count else {
                throw PatchError.outOfBounds(patch.byteRange)
            }
            if splitsUTF8Scalar(originalBytes, range: patch.byteRange) {
                throw PatchError.splitsUTF8Scalar(patch.byteRange)
            }
            let actualHash = sha256Hex(Data(originalBytes[patch.byteRange]))
            guard actualHash == patch.expectedOriginalSHA256 else {
                throw PatchError.staleSourceHash(expected: patch.expectedOriginalSHA256, actual: actualHash)
            }
        }

        let ascending = patches.sorted {
            if $0.byteRange.lowerBound != $1.byteRange.lowerBound {
                return $0.byteRange.lowerBound < $1.byteRange.lowerBound
            }
            return $0.byteRange.upperBound < $1.byteRange.upperBound
        }
        for pair in zip(ascending, ascending.dropFirst()) {
            let lhs = pair.0.byteRange
            let rhs = pair.1.byteRange
            let overlaps = lhs.upperBound > rhs.lowerBound
                || (lhs.isEmpty && rhs.isEmpty && lhs.lowerBound == rhs.lowerBound)
            if overlaps {
                throw PatchError.overlappingRanges(lhs, rhs)
            }
        }

        var patched = originalBytes
        for patch in patches.sorted(by: { $0.byteRange.lowerBound > $1.byteRange.lowerBound }) {
            patched.replaceSubrange(patch.byteRange, with: patch.replacementBytes)
        }
        return Result(
            data: patched,
            originalSHA256: originalHash,
            patchedSHA256: sha256Hex(patched),
            perPatchByteCounts: patches.map {
                ($0.patchID, $0.byteRange.count, $0.replacementBytes.count)
            }
        )
    }

    private static func splitsUTF8Scalar(_ data: Data, range: Range<Int>) -> Bool {
        func isContinuation(_ byte: UInt8) -> Bool {
            (byte & 0b1100_0000) == 0b1000_0000
        }
        if range.lowerBound > 0, range.lowerBound < data.count,
           isContinuation(data[range.lowerBound]) {
            return true
        }
        if range.upperBound > 0, range.upperBound < data.count,
           isContinuation(data[range.upperBound]) {
            return true
        }
        return false
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
