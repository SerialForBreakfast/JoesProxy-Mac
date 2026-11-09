import Foundation
import XCTest

/// Fails if shipped sources, fixtures, or tests reintroduce forbidden content-brand host strings.
///
/// Walks `JoesProxy/`, `JoesProxyCLI/`, `Fixtures/`, and `JoesProxyTests/` relative to the
/// repo root derived from `#filePath`. Historical memlog field notes are intentionally excluded.
/// This file is skipped during the walk so its own string construction does not self-fail.
final class VendorNameHygieneTests: XCTestCase {
    /// Forbidden brand tokens, assembled so this source file does not contain the contiguous literals.
    private static let forbiddenTerms: [String] = [
        "plu" + "to",
        "para" + "mount"
    ]

    private static let scannedRelativeRoots = [
        "JoesProxy",
        "JoesProxyCLI",
        "Fixtures",
        "JoesProxyTests"
    ]

    private static let skippedPathComponents: Set<String> = [
        ".DS_Store",
        "DerivedData",
        "xcuserdata"
    ]

    private static let skippedFileNames: Set<String> = [
        "VendorNameHygieneTests.swift"
    ]

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testShippedTreesContainNoForbiddenVendorBrandReferences() throws {
        let root = repositoryRoot()
        var offenders: [String] = []

        for relative in Self.scannedRelativeRoots {
            let directory = root.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: directory.path) else {
                XCTFail("Expected scan root missing: \(directory.path)")
                continue
            }

            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            XCTAssertNotNil(enumerator, "Failed to enumerate \(directory.path)")

            while let item = enumerator?.nextObject() as? URL {
                let name = item.lastPathComponent
                if Self.skippedFileNames.contains(name) {
                    continue
                }
                if Self.skippedPathComponents.contains(name) {
                    enumerator?.skipDescendants()
                    continue
                }

                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else {
                    continue
                }

                // Skip binary media; only text-like files are grepped.
                let ext = item.pathExtension.lowercased()
                if ["ts", "png", "jpg", "jpeg", "gif", "webp", "key", "bin"].contains(ext) {
                    continue
                }

                guard let data = try? Data(contentsOf: item),
                      let text = String(data: data, encoding: .utf8) else {
                    continue
                }

                let lowercased = text.lowercased()
                let pathLower = item.path.lowercased()
                for term in Self.forbiddenTerms {
                    if lowercased.contains(term) || pathLower.contains(term) {
                        let relativePath = item.path.replacingOccurrences(of: root.path + "/", with: "")
                        offenders.append("\(relativePath) (term: \(term))")
                        break
                    }
                }
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            """
            Forbidden vendor brand strings found in shipped trees. \
            Rename fixtures and neutralize hosts — do not hardcode content brands.
            Offenders:
            \(offenders.sorted().joined(separator: "\n"))
            """
        )
    }
}
