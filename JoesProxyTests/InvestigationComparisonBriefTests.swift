import XCTest
@testable import JoesProxy

final class InvestigationComparisonBriefTests: XCTestCase {
    private func input(_ text: String?, host: String = "api.example.test", path: String = "/items",
                       status: Int = 200, at: TimeInterval = 0) -> InvestigationComparisonBrief.Input {
        let record = SessionRecord(request: CapturedRequest(method: "GET", scheme: .https, host: host,
            port: 443, path: path, headers: [], bodyData: nil, bodySize: nil),
            response: CapturedResponse(statusCode: status, headers: [], bodyData: text.map { Data($0.utf8) }, bodySize: text?.utf8.count),
            state: .completed, timing: SessionTiming(startedAt: Date(timeIntervalSince1970: at), completedAt: Date(timeIntervalSince1970: at + 1)))
        let brief = ResponseEvidenceBrief.analyze(text: text, truncated: false, unavailableReason: text == nil ? "body_missing" : nil,
            pointer: "", includeStructure: true)
        return .init(source: .init(sessionID: record.id.uuidString, captureSequence: 1,
            analysisStatus: brief.status, unavailableReason: text == nil ? "body_missing" : nil, sourceSHA256: brief.sourceSHA256),
            record: record, brief: brief)
    }

    func testComparisonUsesObservedStructureWithoutLeakingValues() throws {
        let before = input(#"{"meta":{"name":"private-before"},"removed":true}"#)
        let after = input(#"{"meta":{"name":null},"added":"private-after"}"#, status: 503)
        let report = InvestigationComparisonBrief.compare(baseline: [before], candidate: [after])
        XCTAssertEqual(report.status, "complete")
        XCTAssertEqual(report.steps.first?.alignment, "Status Code Mismatch")
        XCTAssertEqual(report.steps.first?.wholeResponseBytesChanged, true)
        XCTAssertTrue(report.changes.contains { $0.kind == "observed_path_removed" })
        XCTAssertTrue(report.changes.contains { $0.kind == "observed_path_added" })
        XCTAssertTrue(report.changes.contains { $0.kind == "type_counts_changed" })
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-before"))
        XCTAssertFalse(encoded.contains("private-after"))
        XCTAssertFalse(encoded.contains("api.example.test"))
        XCTAssertEqual(report.targetOutcome, "not_observed")
    }

    func testUnavailableBodyAndMissingSessionStayIncomplete() {
        let missing = InvestigationComparisonBrief.Input(source: .init(sessionID: UUID().uuidString, analysisStatus: "session_missing"))
        let report = InvestigationComparisonBrief.compare(baseline: [input("{}"), missing], candidate: [input(nil)])
        XCTAssertEqual(report.status, "incomplete")
        XCTAssertEqual(report.incomparablePairCount, 1)
        XCTAssertEqual(report.baseline.count, 2)
        XCTAssertNil(report.steps.first?.wholeResponseBytesChanged)
        XCTAssertTrue(report.changes.isEmpty)
    }

    func testDifferentOriginsAreNotPairedAndUnchangedPairIsExplicit() {
        let before = input("{}")
        let other = input("{}", host: "other.example.test")
        let report = InvestigationComparisonBrief.compare(baseline: [before], candidate: [other])
        XCTAssertEqual(report.steps.count, 2)
        XCTAssertTrue(report.steps.allSatisfy { $0.baselineSessionID == nil || $0.candidateSessionID == nil })
        let unchanged = InvestigationComparisonBrief.compare(baseline: [before], candidate: [before])
        XCTAssertEqual(unchanged.steps.first?.wholeResponseBytesChanged, false)
        XCTAssertTrue(unchanged.changes.isEmpty)
    }

    func testPartialStructuresCannotClaimPathsAddedOrRemoved() {
        let before = input(#"{"a":{"b":{"c":{"d":{"e":1}}}}}"#)
        let after = input(#"{"other":null}"#)
        let report = InvestigationComparisonBrief.compare(baseline: [before], candidate: [after])
        XCTAssertEqual(report.status, "incomplete")
        XCTAssertEqual(report.steps.first?.structureComparison, "bounded")
        XCTAssertFalse(report.changes.contains { $0.kind == "observed_path_added" || $0.kind == "observed_path_removed" })
    }

    func testChangeLimitPreservesOmissionCountAndIncompleteStatus() throws {
        let beforeText = String(decoding: try JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: (0..<20).map { ("a\($0)", 1) })), as: UTF8.self)
        let afterText = String(decoding: try JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: (0..<20).map { ("b\($0)", 1) })), as: UTF8.self)
        let report = InvestigationComparisonBrief.compare(baseline: [input(beforeText)], candidate: [input(afterText)])
        XCTAssertEqual(report.changes.count, 32)
        XCTAssertEqual(report.omittedChangeCount, 8)
        XCTAssertEqual(report.status, "incomplete")
    }
}
