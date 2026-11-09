import CryptoKit
import Foundation
import XCTest
@testable import JoesProxy

final class BoundedBytePatchEngineTests: XCTestCase {
    func testInsertionReplacementAndDeletion() throws {
        let original = Data("abcdef".utf8)
        let patches = [
            patch(original, range: 1..<1, replacement: "X"),
            patch(original, range: 2..<4, replacement: "YZ"),
            patch(original, range: 4..<5, replacement: "")
        ]

        let result = try BoundedBytePatchEngine.apply(originalBytes: original, patches: patches)

        XCTAssertEqual(String(decoding: result.data, as: UTF8.self), "aXbYZf")
        XCTAssertEqual(result.perPatchByteCounts.count, 3)
    }

    func testMultiplePatchesAreIndependentOfInputOrder() throws {
        let original = Data("0123456789".utf8)
        let first = patch(original, range: 0..<2, replacement: "A")
        let second = patch(original, range: 8..<10, replacement: "Z")

        let result = try BoundedBytePatchEngine.apply(
            originalBytes: original,
            patches: [second, first]
        )

        XCTAssertEqual(String(decoding: result.data, as: UTF8.self), "A234567Z")
    }

    func testRejectsOverlappingAndDuplicatePatches() throws {
        let original = Data("abcdef".utf8)
        let first = patch(original, range: 1..<4, replacement: "x")
        let overlap = patch(original, range: 3..<5, replacement: "y")
        XCTAssertThrowsError(
            try BoundedBytePatchEngine.apply(originalBytes: original, patches: [first, overlap])
        ) { error in
            guard case .overlappingRanges = error as? BoundedBytePatchEngine.PatchError else {
                return XCTFail("Expected overlapping range rejection, got \(error).")
            }
        }

        let duplicateID = UUID()
        let duplicateA = patch(original, range: 0..<1, replacement: "x", id: duplicateID)
        let duplicateB = patch(original, range: 2..<3, replacement: "y", id: duplicateID)
        XCTAssertThrowsError(
            try BoundedBytePatchEngine.apply(originalBytes: original, patches: [duplicateA, duplicateB])
        ) { error in
            XCTAssertEqual(error as? BoundedBytePatchEngine.PatchError, .duplicatePatch(patchID: duplicateID))
        }
    }

    func testRejectsStaleAndOutOfBoundsPatchesWithoutPartialOutput() throws {
        let original = Data("abcdef".utf8)
        let stale = ResolvedPatch(
            patchID: UUID(),
            byteRange: 1..<2,
            expectedOriginalSHA256: sha256(Data("q".utf8)),
            replacementBytes: Data("X".utf8),
            provenance: .exactText
        )
        XCTAssertThrowsError(
            try BoundedBytePatchEngine.apply(originalBytes: original, patches: [stale])
        ) { error in
            guard case .staleSourceHash = error as? BoundedBytePatchEngine.PatchError else {
                return XCTFail("Expected stale source rejection, got \(error).")
            }
        }

        let outOfBounds = ResolvedPatch(
            patchID: UUID(),
            byteRange: 5..<8,
            expectedOriginalSHA256: sha256(Data("f".utf8)),
            replacementBytes: Data("X".utf8),
            provenance: .exactText
        )
        XCTAssertThrowsError(
            try BoundedBytePatchEngine.apply(originalBytes: original, patches: [outOfBounds])
        ) { error in
            guard case .outOfBounds = error as? BoundedBytePatchEngine.PatchError else {
                return XCTFail("Expected bounds rejection, got \(error).")
            }
        }
    }

    func testRejectsEmptyAndExcessivePatches() throws {
        let original = Data("abc".utf8)
        XCTAssertThrowsError(
            try BoundedBytePatchEngine.apply(originalBytes: original, patches: [])
        ) { error in
            XCTAssertEqual(error as? BoundedBytePatchEngine.PatchError, .emptyPatchSet)
        }

        let patches = (0..<101).map { index in
            patch(original, range: 0..<0, replacement: "", id: UUID())
        }
        XCTAssertThrowsError(
            try BoundedBytePatchEngine.apply(originalBytes: original, patches: patches)
        ) { error in
            XCTAssertEqual(error as? BoundedBytePatchEngine.PatchError, .excessivePatchCount(101))
        }
    }

    func testRejectsPatchThatSplitsUTF8Scalar() throws {
        let original = Data("AéB".utf8)
        let patchInsideScalar = ResolvedPatch(
            patchID: UUID(),
            byteRange: 2..<3,
            expectedOriginalSHA256: sha256(Data(original[2..<3])),
            replacementBytes: Data("x".utf8),
            provenance: .exactText
        )

        XCTAssertThrowsError(
            try BoundedBytePatchEngine.apply(originalBytes: original, patches: [patchInsideScalar])
        ) { error in
            XCTAssertEqual(
                error as? BoundedBytePatchEngine.PatchError,
                .splitsUTF8Scalar(2..<3)
            )
        }
    }

    private func patch(
        _ original: Data,
        range: Range<Int>,
        replacement: String,
        id: UUID = UUID()
    ) -> ResolvedPatch {
        ResolvedPatch(
            patchID: id,
            byteRange: range,
            expectedOriginalSHA256: sha256(Data(original[range])),
            replacementBytes: Data(replacement.utf8),
            provenance: .exactText
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
