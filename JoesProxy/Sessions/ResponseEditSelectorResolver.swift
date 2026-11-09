import CryptoKit
import Foundation

/// Resolves exact-text and match-ref edit selectors into neutral ``ResolvedPatch`` values.
///
/// Concurrency: pure and `Sendable`; callers supply already-validated match ranges or find bytes.
enum ResponseEditSelectorResolver {
    enum OperationKind: String, Equatable, Sendable {
        case replace
        case insertBefore
        case insertAfter
        case delete
    }

    enum SelectorError: Error, Equatable, Sendable {
        case emptyEdits
        case excessiveEdits(Int)
        case findTooShort(Int)
        case findTooLong(Int)
        case replacementTooLong(Int)
        case missingExpectedOccurrences
        case occurrenceMismatch(expected: Int, actual: Int)
        case unsupportedOperation(String)
        case emptyMatchRefSet
        case overlappingResolvedRanges
    }

    private static let maxEdits = 100
    private static let minFindBytes = 3
    private static let maxFindBytes = 4 * 1024
    private static let maxReplacementBytes = 4 * 1024

    /// Resolves one exact-literal find/replace (or insert/delete) against immutable source bytes.
    static func resolveExactText(
        originalBytes: Data,
        find: Data,
        expectedOccurrences: Int,
        operation: OperationKind,
        replacement: Data
    ) throws -> [ResolvedPatch] {
        guard find.count >= minFindBytes else {
            throw SelectorError.findTooShort(find.count)
        }
        guard find.count <= maxFindBytes else {
            throw SelectorError.findTooLong(find.count)
        }
        guard replacement.count <= maxReplacementBytes else {
            throw SelectorError.replacementTooLong(replacement.count)
        }
        guard expectedOccurrences >= 0 else {
            throw SelectorError.missingExpectedOccurrences
        }
        let ranges = exactMatchRanges(in: originalBytes, find: find)
        guard ranges.count == expectedOccurrences else {
            throw SelectorError.occurrenceMismatch(expected: expectedOccurrences, actual: ranges.count)
        }
        return try ranges.map { range in
            try patch(
                originalBytes: originalBytes,
                matchedRange: range,
                operation: operation,
                replacement: replacement,
                provenance: .exactText
            )
        }
    }

    /// Resolves one or more opaque match ranges into patches for a single operation.
    static func resolveMatchRefs(
        originalBytes: Data,
        ranges: [Range<Int>],
        operation: OperationKind,
        replacement: Data
    ) throws -> [ResolvedPatch] {
        guard !ranges.isEmpty else {
            throw SelectorError.emptyMatchRefSet
        }
        guard ranges.count <= maxEdits else {
            throw SelectorError.excessiveEdits(ranges.count)
        }
        guard replacement.count <= maxReplacementBytes else {
            throw SelectorError.replacementTooLong(replacement.count)
        }
        let sorted = ranges.sorted {
            if $0.lowerBound != $1.lowerBound { return $0.lowerBound < $1.lowerBound }
            return $0.upperBound < $1.upperBound
        }
        for pair in zip(sorted, sorted.dropFirst()) where pair.0.upperBound > pair.1.lowerBound {
            throw SelectorError.overlappingResolvedRanges
        }
        return try sorted.map { range in
            try patch(
                originalBytes: originalBytes,
                matchedRange: range,
                operation: operation,
                replacement: replacement,
                provenance: .matchRef
            )
        }
    }

    private static func patch(
        originalBytes: Data,
        matchedRange: Range<Int>,
        operation: OperationKind,
        replacement: Data,
        provenance: ResolvedPatch.Provenance
    ) throws -> ResolvedPatch {
        let byteRange: Range<Int>
        let replacementBytes: Data
        switch operation {
        case .replace:
            byteRange = matchedRange
            replacementBytes = replacement
        case .delete:
            byteRange = matchedRange
            replacementBytes = Data()
        case .insertBefore:
            byteRange = matchedRange.lowerBound..<matchedRange.lowerBound
            replacementBytes = replacement
        case .insertAfter:
            byteRange = matchedRange.upperBound..<matchedRange.upperBound
            replacementBytes = replacement
        }
        guard byteRange.lowerBound >= 0, byteRange.upperBound <= originalBytes.count else {
            throw SelectorError.overlappingResolvedRanges
        }
        return ResolvedPatch(
            patchID: UUID(),
            byteRange: byteRange,
            expectedOriginalSHA256: sha256Hex(Data(originalBytes[byteRange])),
            replacementBytes: replacementBytes,
            provenance: provenance
        )
    }

    private static func exactMatchRanges(in haystack: Data, find: Data) -> [Range<Int>] {
        guard !find.isEmpty, find.count <= haystack.count else { return [] }
        var ranges: [Range<Int>] = []
        var searchStart = haystack.startIndex
        while searchStart <= haystack.endIndex - find.count {
            let window = searchStart..<(searchStart + find.count)
            if haystack[window].elementsEqual(find) {
                ranges.append(window)
                searchStart += find.count
            } else {
                searchStart += 1
            }
        }
        return ranges
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
