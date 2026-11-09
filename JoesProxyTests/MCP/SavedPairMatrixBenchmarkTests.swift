import Foundation
import XCTest
@testable import JoesProxy

private struct PairFixture {
    let name: String
    let width: Int
    var retyped = 0
    var removedFromSecondItem = 0
    var missingBody = false
    var nested = false

    var changeCount: Int { retyped + 2 * removedFromSecondItem }

    func recording(from template: SessionRecord, candidate: Bool) throws -> Data {
        var first: [String: Any] = [:]
        var second: [String: Any] = [:]
        for index in 0..<width {
            let key = String(format: "field_%02d", index)
            let value: Any = candidate && index < retyped ? 42 as Any : "synthetic-value"
            first[key] = value
            if !candidate || index >= removedFromSecondItem { second[key] = value }
        }
        let items = [first, second]
        let document: Any = nested ? ["suggestedItemsForTheCurrentDeliveryConfigurationAndPresentationContext": items] as Any : items
        let body = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        var record = template
        record.response = CapturedResponse(statusCode: 200, headers: [.init(name: "Content-Type", value: "application/json")],
            bodyData: candidate && missingBody ? nil : body, bodySize: body.count)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let entry = try JSONSerialization.jsonObject(with: encoder.encode(record))
        return try JSONSerialization.data(withJSONObject: [
            "schemaVersion": RecordingConstants.currentSchemaVersion, "exportedAt": "2026-11-07T00:00:00Z",
            "appVersion": "synthetic", "proxyPort": 9090, "sessionCount": 1, "sessions": [entry]
        ], options: [.sortedKeys])
    }
}

extension MCPResponseDisclosureIntegrationTests {
    func testSavedPairMatrixThroughReviewedAnswer() async throws {
        var fixtures = [PairFixture(name: "tiny-identical", width: 1), PairFixture(name: "two-field-identical", width: 2),
                        PairFixture(name: "identical", width: 10),
                        PairFixture(name: "sparse", width: 10, retyped: 1)]
        // Hold shape constant to isolate the cost of each additional changed field.
        for affected in 1...10 {
            fixtures.append(PairFixture(name: "dense-\(affected)", width: 10, retyped: affected, removedFromSecondItem: affected))
        }
        fixtures.append(PairFixture(name: "incomplete", width: 10, missingBody: true))
        fixtures.append(PairFixture(name: "dense-nested", width: 10, retyped: 10, removedFromSecondItem: 10, nested: true))
        fixtures.append(PairFixture(name: "dense-capped", width: 20, retyped: 20, removedFromSecondItem: 20))
        for fixture in fixtures {
            let stack = try await makeStack()
            let catalog = try await callRPC(stack: stack, method: "tools/list", params: [:])
            var setup: [Int] = []
            func source(candidate: Bool) async throws -> [String: Any] {
                var args = try await reviewedSource(stack, kind: .recording,
                    data: fixture.recording(from: stack.session, candidate: candidate), scopes: ["metadata-v1", "brief-v1"]) {
                        _, bytes in setup.append(bytes)
                    }
                args["recordIndex"] = 0
                return args
            }
            let left = try await source(candidate: false)
            let right = try await source(candidate: true)
            let pair = ["baseline": left, "candidate": right]
            let pending = try await callSessionSummary(stack: stack, toolName: "artifact_compare_responses", toolArguments: pair)
            XCTAssertNotNil(pending.errorData)
            let id = try XCTUnwrap(stack.artifactSources.pairReviews.keys.first)
            try stack.artifactSources.approvePair(id: id)
            let poll = try await callSessionSummary(stack: stack, toolName: "approval_status", toolArguments: ["requestID": id])
            XCTAssertNil(poll.errorData)
            let answer = try await callSessionSummary(stack: stack, toolName: "artifact_compare_responses", toolArguments: pair)
            func brief(_ side: [String: Any]) async throws -> ToolResponse {
                var args = side
                args["includeStructure"] = true
                return try await callSessionSummary(stack: stack, toolName: "artifact_response_brief", toolArguments: args)
            }
            let first = try await brief(left)
            let second = try await brief(right)
            let before = try summaryPayload(from: first)
            let after = try summaryPayload(from: second)
            let report = try summaryPayload(from: answer)
            let changes = try XCTUnwrap(report["changes"] as? [[String: Any]])
            let omitted = try XCTUnwrap(report["omittedChangeCount"] as? Int)
            let status = try XCTUnwrap(report["status"] as? String)
            XCTAssertEqual(before["structureCoverage"] as? String, "complete")
            if fixture.missingBody {
                XCTAssertEqual(status, "incomplete")
                XCTAssertEqual((report["candidate"] as? [String: Any])?["reason"] as? String, "incomplete_body")
                XCTAssertEqual(after["reason"] as? String, "incomplete_body")
                XCTAssertNil(report["wholeResponseBytesEqual"] as? Bool)
                XCTAssertTrue(changes.isEmpty)
            } else {
                let beforeDigest = try XCTUnwrap(before["sourceSHA256"] as? String)
                let afterDigest = try XCTUnwrap(after["sourceSHA256"] as? String)
                XCTAssertEqual(beforeDigest == afterDigest, fixture.changeCount == 0)
                XCTAssertEqual(report["wholeResponseBytesEqual"] as? Bool, beforeDigest == afterDigest)
                XCTAssertEqual(after["structureCoverage"] as? String, "complete")
                let expected = try clientChanges(before: before, after: after)
                XCTAssertEqual(expected.count, fixture.changeCount)
                XCTAssertEqual(changes as NSArray, Array(expected.prefix(32)) as NSArray, fixture.name)
                XCTAssertEqual(status, expected.count > 32 ? "incomplete" : "complete")
            }
            XCTAssertEqual(omitted, max(0, fixture.changeCount - 32))
            XCTAssertEqual(setup.count, 6)
            let receipt: [String: Any] = [
                "fixture": fixture.name, "status": status, "returned": changes.count, "omitted": omitted,
                "catalog": catalog.wireBytes, "setup": setup.reduce(0, +), "setupCalls": setup.count,
                "pending": pending.wireBytes, "poll": poll.wireBytes, "answer": answer.wireBytes,
                "baselineBrief": first.wireBytes, "candidateBrief": second.wireBytes
            ]
            let bytes = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            print("PAIR_MATRIX \(String(decoding: bytes, as: UTF8.self))")
        }
    }

    // Independent client-side answer for these fixed-shape fixtures, from the two returned briefs.
    private func clientChanges(before: [String: Any], after: [String: Any]) throws -> [[String: Any]] {
        let old = try XCTUnwrap(before["structure"] as? [[String: Any]])
        let new = try XCTUnwrap(after["structure"] as? [[String: Any]])
        let keys = [("missingFromParentObjects", "missing_count_changed"), ("occurrences", "occurrence_count_changed"),
                    ("types", "type_counts_changed")]
        XCTAssertEqual(Set(old.compactMap { $0["path"] as? String }), Set(new.compactMap { $0["path"] as? String }))
        var changes: [[String: Any]] = []
        for path in old.compactMap({ $0["path"] as? String }).sorted() {
            let lhs = try XCTUnwrap(old.first { $0["path"] as? String == path })
            let rhs = try XCTUnwrap(new.first { $0["path"] as? String == path })
            for (field, kind) in keys {
                let a = try XCTUnwrap(lhs[field] as? NSObject)
                let b = try XCTUnwrap(rhs[field] as? NSObject)
                if !a.isEqual(b) { changes.append(["path": path, "kind": kind, "before": a, "after": b]) }
            }
        }
        return changes
    }
}
