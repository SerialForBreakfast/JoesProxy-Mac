import XCTest
@testable import JoesProxy

final class ArtifactSearchTests: XCTestCase {
    private func source(_ bytes: Data, kind: ArtifactSourceKind = .text) throws -> ArtifactSnapshot {
        try ArtifactSnapshotReader.decode(data: bytes, kind: kind, deadline: .now.advanced(by: .seconds(5)))
    }

    func testSmallRecordProbePreservesBoundariesFiltersUnicodeAndOmissions() throws {
        let body = "\"é😀é😀\""
        func entry(_ method: String, _ text: String, _ size: Int) -> [String: Any] {
            ["startedDateTime": "2026-11-07T00:00:00Z", "time": 1,
             "request": ["method": method, "url": "https://example.invalid/test"],
             "response": ["status": 200, "content": ["size": size, "mimeType": "application/json", "text": text]]]
        }
        let entries = [entry("GET", body, body.utf8.count), entry("POST", body, body.utf8.count),
            entry("GET", "\"other\"", 7), entry("GET", body, 300)]
        let snapshot = try source(JSONSerialization.data(withJSONObject: ["log": ["entries": entries]]), kind: .har)
        for budget in [2, 14, 28, 65] {
            for probe in [true, false] {
                let q = try ArtifactSearchQuery(inventory: false, arguments: ["dataset": "responseJSON", "literal": "é😀", "limit": 1, "method": "GET"])
                var p = ArtifactSearch.Position()
                var offsets: [Int] = []
                while p.record < entries.count {
                    let page = try ArtifactSearch.page(snapshot: snapshot, query: q, from: p, byteBudget: budget, nativeProbe: probe)
                    XCTAssertLessThanOrEqual(page.scannedBytes, budget)
                    XCTAssertTrue(page.items.allSatisfy { $0.recordIndex == 0 })
                    offsets += page.items.compactMap(\.byteOffset)
                    p = page.position
                }
                XCTAssertEqual(offsets, [1, 7])
                XCTAssertEqual(p.omissions, ["representation_unavailable": 1])
                XCTAssertEqual(p.searched, 2)
                XCTAssertEqual(p.excluded, 1)
            }
        }
    }

    func testSavedBriefRejectsAmbiguousArgumentsAndQualifiesBadBodies() throws {
        for args: [String: Any] in [["recordIndex": true], ["recordIndex": 1.5], ["recordIndex": -1],
            ["recordIndex": 0, "includeStructure": 1], ["recordIndex": 0, "selectionPointer": "/~2"],
            ["recordIndex": 0, "selectionPointer": "/" + String(repeating: "a", count: 512)], ["recordIndex": 0, "includeBody": true]] {
            XCTAssertThrowsError(try SavedResponseBrief(arguments: args))
        }
        let bodies = [Data("bad-json".utf8), Data([0xff]), Data(repeating: 120, count: 262_145)]
        let entries: [[String: Any]] = bodies.map { body in
            ["startedDateTime": "2026-11-07T00:00:00Z", "time": 0, "request": ["method": "GET", "url": "https://example.invalid"],
             "response": ["status": 200, "content": ["size": body.count, "encoding": "base64", "mimeType": "application/json",
                "text": body.base64EncodedString()]]]
        }
        let snapshot = try source(JSONSerialization.data(withJSONObject: ["log": ["entries": entries]]), kind: .har)
        for (i, reason) in ["invalid_json", "invalid_utf8", "input_limit", "record_out_of_range"].enumerated() {
            let report = try SavedResponseBrief(arguments: ["recordIndex": i]).report(snapshot: snapshot)
            XCTAssertEqual(report.status, reason)
            XCTAssertTrue(report.fields.isEmpty)
        }
    }

    func testByteExactUTF8AcrossPageAndWorkBoundaries() throws {
        let text = "\u{FEFF}e\u{301}é😀é😀aaaaaa"
        let snapshot = try source(Data(text.utf8))
        for (literal, offsets) in [("é😀", [6, 12]), ("aaa", [18, 21]), ("e\u{301}", [3]), ("xxx", [])] {
            for budget in [1, 3, 64] {
                let query = try ArtifactSearchQuery(inventory: false, arguments: ["dataset": "sourceUTF8", "literal": literal, "limit": 1])
                var position = ArtifactSearch.Position()
                var actual: [Int] = []
                for _ in 0...text.utf8.count {
                    let page = try ArtifactSearch.page(snapshot: snapshot, query: query, from: position, byteBudget: budget)
                    actual += page.items.compactMap(\.byteOffset)
                    position = page.position
                    if page.completeTraversal { break }
                }
                XCTAssertEqual(position.record, 1)
                XCTAssertEqual(position.omissions, [:])
                XCTAssertEqual(actual, offsets)
            }
        }
    }

    func testEscapesAndAllStandaloneInventoryKinds() throws {
        let json = try source(Data(#"{"marker":"\u0061bc"}"#.utf8), kind: .json)
        for (word, count) in [("abc", 0), (#"\u0061"#, 1)] {
            let q = try ArtifactSearchQuery(inventory: false, arguments: ["dataset": "sourceUTF8", "literal": word])
            XCTAssertEqual(try ArtifactSearch.page(snapshot: json, query: q, from: .init()).position.observed, count)
        }
        for kind in [ArtifactSourceKind.text, .json, .image, .effectBundle] {
            let snapshot = ArtifactSnapshot(kind: kind, originalBytes: Data(), packageMembers: [:], sourceSHA256: "",
                records: [], schemaVersion: nil, warnings: [], retainedBytes: 0, frameCount: nil)
            let query = try ArtifactSearchQuery(inventory: true, arguments: [:])
            let item = try XCTUnwrap(ArtifactSearch.page(snapshot: snapshot, query: query, from: .init()).items.first)
            XCTAssertEqual(item.kind, kind.rawValue)
            XCTAssertEqual(item.datasets, [.json, .text].contains(kind) ? ["sourceUTF8"] : [])
        }
    }

    func testLabelledHARInventoryFiltersAndIncompleteZero() throws {
        let good = #"{"startedDateTime":"2026-01-01T00:00:00Z","time":1,"request":{"method":"GET","url":"https://api.example.invalid/a"},"response":{"status":503,"content":{"size":11,"mimeType":"application/json","text":"\"marker123\""}}}"#
        let absent = good.replacingOccurrences(of: "\"size\":11", with: "\"size\":99")
        for count in [10, 100, 1000] {
            let entries = (0..<count).map { $0 == count - 1 ? absent : good }
            let data = Data(("{\"log\":{\"entries\":[" + entries.joined(separator: ",") + "]}}").utf8)
            let snapshot = try source(data, kind: .har)
            for (word, expected) in [("marker", count - 1), ("absent", 0)] {
                let query = try ArtifactSearchQuery(inventory: false, arguments: ["dataset": "responseJSON",
                    "literal": word, "method": "GET", "statusCode": 503])
                var p = ArtifactSearch.Position()
                var ids: [Int] = []
                var pages = 0
                repeat {
                    let page = try ArtifactSearch.page(snapshot: snapshot, query: query, from: p)
                    XCTAssertTrue(page.items.allSatisfy { $0.byteOffset == 1 })
                    ids += page.items.compactMap(\.recordIndex)
                    p = page.position
                    pages += 1
                    XCTAssertLessThanOrEqual(pages, count + 1)
                    if pages > count + 1 { break }
                } while p.record < count
                XCTAssertEqual(ids, Array(0..<expected))
                XCTAssertEqual(p.omissions, ["representation_unavailable": 1])
                XCTAssertEqual(p.observed, expected)
                print("EC06_SCAN records=\(count) bytes=\(data.count) matches=\(expected) pages=\(pages) omissions=1")
            }
            let query = try ArtifactSearchQuery(inventory: true, arguments: ["method": "POST"])
            let page = try ArtifactSearch.page(snapshot: snapshot, query: query, from: .init())
            XCTAssertEqual(page.position.excluded, min(256, count))
            XCTAssertTrue(page.items.isEmpty)
        }
    }

    func testNonUTF8ResponseWithJSONMediaTypeIsAnOmission() throws {
        let har = #"{"log":{"entries":[{"startedDateTime":"2026-01-01T00:00:00Z","time":1,"request":{"method":"GET","url":"https://api.example.invalid"},"response":{"status":200,"content":{"size":4,"mimeType":"application/json","encoding":"base64","text":"/2FiYw=="}}}]}}"#
        let snapshot = try source(Data(har.utf8), kind: .har)
        let inventory = try ArtifactSearchQuery(inventory: true, arguments: [:])
        let row = try XCTUnwrap(ArtifactSearch.page(snapshot: snapshot, query: inventory, from: .init()).items.first)
        XCTAssertEqual(row.representationAvailable, false)
        let query = try ArtifactSearchQuery(inventory: false, arguments: ["dataset": "responseJSON", "literal": "abc"])
        let page = try ArtifactSearch.page(snapshot: snapshot, query: query, from: .init())
        XCTAssertTrue(page.completeTraversal)
        XCTAssertEqual(page.position.omissions, ["representation_unavailable": 1])
        XCTAssertEqual(page.position.observed, 0)
    }

    func testSparseFourMiBInputAgainstByteRangeOracleAndMemoryTrend() throws {
        var bytes = Data(repeating: 97, count: 4_194_304)
        let marker = Data("marker".utf8)
        let offset = 1_048_574
        bytes.replaceSubrange(offset..<(offset + marker.count), with: marker)
        let oracle = try XCTUnwrap(bytes.range(of: marker))
        let snapshot = try source(bytes)
        let query = try ArtifactSearchQuery(inventory: false, arguments: ["dataset": "sourceUTF8", "literal": "marker"])
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTMemoryMetric(), XCTClockMetric()], options: options) {
            do {
                var pages = 0
                var scanned = 0
                var matches: [Int] = []
                var start = ArtifactSearch.Position()
                repeat {
                    let page = try ArtifactSearch.page(snapshot: snapshot, query: query, from: start)
                    matches += page.items.compactMap(\.byteOffset)
                    scanned += page.scannedBytes
                    start = page.position
                    pages += 1
                    guard pages <= 100 else { return XCTFail("Traversal did not advance") }
                } while start.record == 0
                XCTAssertEqual(matches, [oracle.lowerBound])
                XCTAssertEqual(scanned, bytes.count)
            } catch { XCTFail("Sparse scan failed: \(error)") }
        }
    }

    func testRejectsInvalidSelectionsAndSnippetRequests() throws {
        for extra: [String: Any] in [["limit": true], ["limit": 51], ["recordIndices": [2, 1]],
                                     ["includeContext": true], ["cursor": 9], ["recordIndices": [0, 0]]] {
            XCTAssertThrowsError(try ArtifactSearchQuery(inventory: true, arguments: extra))
        }
        let snapshot = try source(Data("abc".utf8))
        let q = try ArtifactSearchQuery(inventory: false, arguments: ["dataset": "responseJSON", "literal": "abc"])
        XCTAssertThrowsError(try ArtifactSearch.page(snapshot: snapshot, query: q, from: .init()))
    }
}
