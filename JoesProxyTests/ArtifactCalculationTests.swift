import Foundation
import XCTest
@testable import JoesProxy

final class ArtifactCalculationTests: XCTestCase {
    private func query(_ kind: String, field: String = "/value", pointer: String = "", limit: Int? = nil,
                       order: String? = nil) throws -> ArtifactCalculation.Query {
        var operation: [String: Any] = ["kind": kind]
        if kind != "rowCount" { operation["fieldPointer"] = field }
        if let limit { operation["limit"] = limit }
        if let order { operation["order"] = order }
        return try .init(selectionPointer: pointer, operation: operation)
    }

    private func analyze(_ text: String, kind: String = "numericSummary", field: String = "/value",
                         pointer: String = "", limit: Int? = nil, order: String? = nil) throws -> ArtifactCalculation.Report {
        try ArtifactCalculation.analyze(data: Data(text.utf8), query: query(kind, field: field, pointer: pointer, limit: limit, order: order),
            deadline: .now.advanced(by: .seconds(10)))
    }

    func testExactDecimalSumAndSelectedFieldIsolation() throws {
        let report = try analyze(#"{"items":[{"value":0.1,"ignored":9007199254740993},{"value":0.2},{"value":null},{}],"other":[999]}"#, pointer: "/items")
        XCTAssertEqual(report.rows, 4)
        XCTAssertEqual(report.result.count, 2)
        XCTAssertEqual(report.result.sum, "0.3")
        XCTAssertEqual(report.result.mean?.decimal, "0.15")
        XCTAssertEqual(report.result.mean?.numerator, "0.3")
        XCTAssertEqual(report.result.mean?.denominator, 2)
        XCTAssertEqual(report.result.mean?.exact, true)
        XCTAssertEqual(report.result.missing, 1)
        XCTAssertEqual(report.result.null, 1)
    }

    func testRepeatingMeansAndHalfEvenRoundingBothSigns() throws {
        let report = try analyze("[1,0,0]", field: "")
        XCTAssertEqual(report.result.mean?.decimal, "0.333333")
        XCTAssertEqual(report.result.mean?.numerator, "1")
        XCTAssertEqual(report.result.mean?.exact, false)
        XCTAssertEqual(try analyze("[0.000001,0]", field: "").result.mean?.decimal, "0")
        XCTAssertEqual(try analyze("[0.000003,0]", field: "").result.mean?.decimal, "0.000002")
        XCTAssertEqual(try analyze("[-0.000003,0]", field: "").result.mean?.decimal, "-0.000002")
    }

    func testPrecisionMagnitudeAndNonNumericInputsFailWithoutPartialAnswer() throws {
        for text in ["[0.1,0.0000001]", "[9007199254740993]", "[1000000000000]", "[1,true]", "[1,\"2\"]", "[1,[]]"] {
            XCTAssertThrowsError(try analyze(text, field: ""), text)
        }
        XCTAssertEqual(try analyze("[1e3,1.0000000,-0]", field: "").result.sum, "1001")
        XCTAssertEqual(try analyze("[999999999999.999999]", field: "").result.sum, "999999999999.999999")
    }

    func testAccumulatorOverflowIsPermutationIndependent() throws {
        let positives = Array(repeating: "999999999999.999999", count: 10)
        let negatives = Array(repeating: "-999999999999.999999", count: 10)
        for values in [positives + negatives, negatives + positives, zip(positives, negatives).flatMap { [$0.0, $0.1] }] {
            XCTAssertThrowsError(try analyze("[" + values.joined(separator: ",") + "]", field: "")) { error in
                XCTAssertEqual(error as? ArtifactAnalysisFailure, .numericOverflow)
            }
        }
    }

    func testFieldStatsIncludesMissingNullAndAllTypesWithoutArithmetic() throws {
        let report = try analyze(#"[{},{"value":null},{"value":true},{"value":9007199254740993},{"value":"x"},{"value":[]},{"value":{}}]"#, kind: "fieldStats")
        XCTAssertEqual(report.result.fieldTypes, ["missing": 1, "null": 1, "boolean": 1, "number": 1, "string": 1, "array": 1, "object": 1])
    }

    func testDistinctTypedIdentitiesAndUnicodeBytes() throws {
        let report = try analyze("[1,1.0,1e0,true,\"1\",\"é\",\"e\\u0301\",null]", kind: "distinctCount", field: "")
        XCTAssertEqual(report.result.distinctCount, 5)
        XCTAssertEqual(report.result.null, 1)
        XCTAssertThrowsError(try analyze("[{}]", kind: "distinctCount", field: ""))
    }

    func testGroupOutputLimitDoesNotChangeExactTotals() throws {
        let report = try analyze(#"[{"value":"b"},{"value":"a"},{"value":"a"},{},{"value":null}]"#, kind: "groupCount", limit: 2)
        XCTAssertEqual(report.status, "output_limited")
        XCTAssertEqual(report.selectionCoverage, "complete")
        XCTAssertEqual(report.result.totalGroups, 4)
        XCTAssertEqual(report.result.omittedGroups, 2)
        XCTAssertEqual(report.result.groups?.first?.key.value, "a")
        XCTAssertEqual(report.result.groups?.first?.count, 2)
        XCTAssertEqual(report.result.groups?.last?.key.type, "missing")
    }

    func testTopRowsUsesOrdinalTieBreakAndDoesNotSum() throws {
        let report = try analyze("[5,null,9,9,1]", kind: "topRows", field: "", limit: 2)
        XCTAssertEqual(report.result.rows?.map(\.rowIndex), [2, 3])
        XCTAssertEqual(report.result.rowsNotReturned, 2)
        XCTAssertEqual(report.status, "complete")
        XCTAssertEqual(try analyze("[5,1,1]", kind: "topRows", field: "", limit: 2, order: "asc").result.rows?.map(\.rowIndex), [1, 2])
        let manyLarge = "[" + Array(repeating: "999999999999.999999", count: 20).joined(separator: ",") + "]"
        XCTAssertEqual(try analyze(manyLarge, kind: "topRows", field: "").result.eligibleRows, 20)
    }

    func testEmptyCollectionAndNonArraySelections() throws {
        let empty = try analyze("[]")
        XCTAssertEqual(empty.result.count, 0)
        XCTAssertEqual(empty.result.sum, "0")
        XCTAssertNil(empty.result.mean)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(empty.result)) as? [String: Any])
        XCTAssertTrue(encoded["min"] is NSNull)
        XCTAssertTrue(encoded["max"] is NSNull)
        XCTAssertTrue(encoded["mean"] is NSNull)
        XCTAssertThrowsError(try analyze("{}", kind: "rowCount"))
        XCTAssertEqual(try analyze("[]", kind: "rowCount").result.count, 0)
    }

    func testStrictJSONDuplicateKeysTrailingTokensAndInvalidNumbers() throws {
        for text in [#"[{"value":1,"value":2}]"#, "[01]", "[1.]", "[1e]", "[+1]", "[NaN]", "[1,]", "[] true", "[\"\\uD800\"]"] {
            XCTAssertThrowsError(try analyze(text, kind: "rowCount"), text)
        }
        XCTAssertThrowsError(try ArtifactJSONReader(data: Data([0xFF]), deadline: .now.advanced(by: .seconds(1))))
        // Canonically equivalent keys are distinct bytes; duplicate escaped spellings are not.
        XCTAssertEqual(try analyze("[{\"é\":1,\"e\\u0301\":2}]", kind: "rowCount").result.count, 1)
        XCTAssertThrowsError(try analyze(#"[{"a":1,"\u0061":2}]"#, kind: "rowCount"))
    }

    func testPointerEscapesAndNoImplicitCollectionSelection() throws {
        XCTAssertEqual(try analyze(#"{"a/b":{"~items":[{"x/y":3}]}}"#, field: "/x~1y", pointer: "/a~1b/~0items").result.sum, "3")
        XCTAssertThrowsError(try query("rowCount", pointer: "/~2"))
        XCTAssertThrowsError(try query("rowCount", pointer: String(repeating: "/a", count: 17)))
        XCTAssertThrowsError(try analyze("[[1]]", kind: "rowCount", pointer: "/00"))
    }

    func testBoundsAndDeadlineRejectRatherThanTruncate() throws {
        XCTAssertThrowsError(try ArtifactCalculation.analyze(data: Data(repeating: 32, count: 1_048_577), query: query("rowCount"), deadline: .now.advanced(by: .seconds(1))))
        let rows = "[" + Array(repeating: "0", count: 10_001).joined(separator: ",") + "]"
        XCTAssertThrowsError(try analyze(rows, kind: "rowCount"))
        let identities = "[" + (0..<257).map(String.init).joined(separator: ",") + "]"
        XCTAssertThrowsError(try analyze(identities, kind: "distinctCount", field: ""))
        XCTAssertThrowsError(try analyze("[\"" + String(repeating: "x", count: 257) + "\"]", kind: "groupCount", field: ""))
        XCTAssertThrowsError(try ArtifactCalculation.analyze(data: Data("[]".utf8), query: query("rowCount"), deadline: .now.advanced(by: .seconds(-1))))
    }

    func testUnknownOperatorOptionsCannotBecomeCodeOrFilters() throws {
        XCTAssertThrowsError(try ArtifactCalculation.Query(selectionPointer: "", operation: ["kind": "rowCount", "filter": "status >= 400"]))
        XCTAssertThrowsError(try ArtifactCalculation.Query(selectionPointer: "", operation: ["kind": "groupCount", "fieldPointer": "", "limit": true]))
        XCTAssertThrowsError(try ArtifactCalculation.Query(selectionPointer: "", operation: ["kind": "eval", "code": "1+1"]))
    }

    func testVersionedThousandRowCompactionFixture() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let baseline = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            repo.appendingPathComponent("memlog/Research/Agent-Efficiency-Artifact-Baseline-v1.json"))) as? [String: Any])
        let gates = try XCTUnwrap(baseline["numericSummary"] as? [String: Any])
        let rows = (0..<1000).map { #"{"price":0.1,"description":"synthetic mock item "# + String($0) + #""}"# }
        let raw = Data(("[" + rows.joined(separator: ",") + "]").utf8)
        let report = try ArtifactCalculation.analyze(data: raw, query: query("numericSummary", field: "/price"), deadline: .now.advanced(by: .seconds(10)))
        XCTAssertGreaterThanOrEqual(raw.count, try XCTUnwrap(gates["minimumRawInputBytes"] as? Int))
        XCTAssertEqual(report.result.sum, gates["expectedSum"] as? String)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(report).count, try XCTUnwrap(gates["maximumResultBytes"] as? Int))
        print("EFFICIENCY_METRIC artifact-calculate-v1 rawBytes=\(raw.count) resultBytes=\(try JSONEncoder().encode(report).count) calls=1 analyses=1 rows=1000")
    }

    func testOneMiBKernelMemoryAndLatencyTrend() throws {
        let row = "{\"price\":0.1,\"description\":\"" + String(repeating: "x", count: 180) + "\"}"
        var raw = Data(("[" + Array(repeating: row, count: 4000).joined(separator: ",") + "]").utf8)
        raw.append(Data(repeating: 32, count: 1_048_576 - raw.count))
        let query = try query("numericSummary", field: "/price")
        let sampler = CurrentProcessMetricsSampler()
        let before = sampler.sample()
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTMemoryMetric(), XCTClockMetric()], options: options) {
            do {
                let report = try ArtifactCalculation.analyze(data: raw, query: query, deadline: .now.advanced(by: .seconds(1)))
                XCTAssertEqual(report.result.sum, "400")
                XCTAssertEqual(report.rows, 4000)
            } catch { XCTFail("Bounded one-MiB fixture failed: \(error)") }
        }
        let after = sampler.sample()
        print("EFFICIENCY_METRIC artifact-kernel-memory-v1 inputBytes=\(raw.count) baselinePhysicalBytes=\(before.physicalFootprintBytes) endPhysicalBytes=\(after.physicalFootprintBytes) processLifetimePeakResidentBytes=\(after.peakResidentMemoryBytes)")
    }

    func testWherePredicatesAndMultiOperationBatching() throws {
        let json = #"{"items":[{"status":200,"price":10,"tag":"ok"},{"status":503,"price":25,"tag":"err-timeout"},{"status":500,"price":15,"tag":null},{"price":99}]}"#
        let data = Data(json.utf8)
        let q1 = try ArtifactCalculation.Query(
            selectionPointer: "/items",
            operation: [
                "kind": "numericSummary",
                "fieldPointer": "/price",
                "where": ["fieldPointer": "/status", "op": "gte", "value": 400]
            ]
        )
        let q2 = try ArtifactCalculation.Query(
            selectionPointer: "/items",
            operation: [
                "kind": "rowCount",
                "where": ["fieldPointer": "/status", "op": "isMissing"]
            ]
        )
        let q3 = try ArtifactCalculation.Query(
            selectionPointer: "/items",
            operation: [
                "kind": "rowCount",
                "where": ["fieldPointer": "/tag", "op": "contains", "value": "timeout"]
            ]
        )
        let batch = try ArtifactCalculation.analyzeBatch(
            data: data,
            selectionPointer: "/items",
            queries: [q1, q2, q3],
            deadline: .now.advanced(by: .seconds(5))
        )
        XCTAssertEqual(batch.rows, 4)
        XCTAssertEqual(batch.results.count, 3)
        XCTAssertEqual(batch.results[0].filteredRows, 2)
        XCTAssertEqual(batch.results[0].result.sum, "40")
        XCTAssertEqual(batch.results[1].filteredRows, 1)
        XCTAssertEqual(batch.results[1].result.count, 1)
        XCTAssertEqual(batch.results[2].filteredRows, 1)
        XCTAssertEqual(batch.results[2].result.count, 1)
    }
}
