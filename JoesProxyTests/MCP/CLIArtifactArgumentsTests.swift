import Foundation
import XCTest

final class CLIArtifactArgumentsTests: XCTestCase {
    func testExactSearchPreservesLiteralAndRejectsAmbiguousInputs() throws {
        let base = ["artifact", "search", "--handle", "h", "--snapshot-revision", "r", "--dataset", "sourceUTF8"]
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data(" a\n".utf8))
        try pipe.fileHandleForWriting.close()
        let args = try CLIArtifactArguments.search(CLIInvocation.parse(base + ["--literal-stdin"]), inventory: false, input: pipe.fileHandleForReading)
        XCTAssertEqual(args["literal"] as? String, " a\n")
        for flags in [["--literal", "ab"], ["--literal", "abc", "--literal-stdin"], ["--literal", "abc", "--include-context", "yes"]] {
            XCTAssertThrowsError(try CLIArtifactArguments.search(CLIInvocation.parse(base + flags), inventory: false))
        }
    }

    func testLiveAndSavedCommandsBuildSameOperationAndExplicitSelection() throws {
        let live = try CLIInvocation.parse(["capture", "calculate", "--session-ids", UUID().uuidString,
            "--dataset", "responseJSON", "--selection-pointer", "/items", "--operation", "numericSummary", "--field-pointer", "/price"])
        let saved = try CLIInvocation.parse(["artifact", "calculate", "--handle", "opaque", "--snapshot-revision", "revision",
            "--dataset", "json", "--selection-pointer", "/items", "--operation", "numericSummary", "--field-pointer", "/price"])
        let lhs = try CLIArtifactArguments.calculation(live, live: true)
        let rhs = try CLIArtifactArguments.calculation(saved, live: false)
        XCTAssertEqual(lhs["operation"] as? [String: String], rhs["operation"] as? [String: String])
        XCTAssertEqual(lhs["selectionPointer"] as? String, "/items")
        XCTAssertNil(rhs["sessionIDs"])
    }

    func testRegistrationRequiresExplicitScopesAndRejectsPathInput() throws {
        let base = ["artifact", "source", "register", "--request-key", UUID().uuidString, "--kind", "json", "--scope", "metadata-v1,calculations-v1"]
        let valid = try CLIArtifactArguments.source(CLIInvocation.parse(base), action: "register")
        XCTAssertEqual(valid["scopes"] as? [String], ["calculations-v1", "metadata-v1"])
        XCTAssertThrowsError(try CLIArtifactArguments.source(CLIInvocation.parse(base + ["--file", "private.json"]), action: "register"))
        XCTAssertThrowsError(try CLIArtifactArguments.source(CLIInvocation.parse(base + ["--ttl-seconds", "3601"]), action: "register"))
    }

    func testOperatorAndDatasetSpecificFlagsRejectRatherThanIgnore() throws {
        let base = ["capture", "calculate", "--session-ids", UUID().uuidString, "--dataset", "sessionMetadata", "--operation", "rowCount"]
        XCTAssertThrowsError(try CLIArtifactArguments.calculation(CLIInvocation.parse(base + ["--field-pointer", "/statusCode"]), live: true))
        XCTAssertThrowsError(try CLIArtifactArguments.calculation(CLIInvocation.parse(base + ["--record-index", "2"]), live: true))
        XCTAssertEqual(try CLIArtifactArguments.calculation(CLIInvocation.parse(base), live: true)["selectionPointer"] as? String, "")
    }
}
