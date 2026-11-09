import Foundation
import XCTest
@testable import JoesProxy

/// Research only. Each trial owns one immutable snapshot, query workload and empty strategy state.
final class RepeatedArtifactSearchBenchmarkTests: XCTestCase {
    private struct Hit: Equatable {
        let record: Int
        let offset: Int
    }

    private struct Answer: Equatable {
        var hits: [Hit] = []
        var missing = 0
    }

    private struct Work {
        var pages = 0
        var scans = 0
        var bytes = 0
        var cacheHits = 0
    }

    // One 2,048-bit trigram presence filter per physical record. A candidate still needs an exact scan.
    private struct Filter {
        static let wordsPerRecord = 32
        var words: [UInt64]

        static func bit(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> Int {
            let key = UInt32(a) << 16 | UInt32(b) << 8 | UInt32(c)
            return Int((key &* 2_654_435_761) >> 21)
        }

        init(_ snapshot: ArtifactSnapshot) {
            words = Array(repeating: 0, count: snapshot.records.count * Self.wordsPerRecord)
            for (record, projection) in snapshot.records.enumerated() {
                guard let data = projection?.responseJSON, data.count >= 3 else { continue }
                data.withUnsafeBytes { raw in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    for i in 2..<bytes.count {
                        let bit = Self.bit(bytes[i - 2], bytes[i - 1], bytes[i])
                        words[record * Self.wordsPerRecord + bit / 64] |= 1 << (bit % 64)
                    }
                }
            }
        }

        func candidates(_ snapshot: ArtifactSnapshot, _ literal: [UInt8]) -> [Int] {
            let bits = (2..<literal.count).map { Self.bit(literal[$0 - 2], literal[$0 - 1], literal[$0]) }
            return snapshot.records.indices.filter { record in
                guard snapshot.records[record]?.hasSearchableUTF8 == true else { return true }
                return bits.allSatisfy { bit in
                    words[record * Self.wordsPerRecord + bit / 64] & (1 << (bit % 64)) != 0
                }
            }
        }
    }

    static func encodedHAR(varied: Bool) throws -> Data {
        let padding = String(repeating: "synthetic payload ", count: 112)
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
        var state: UInt32 = 1729
        func variedPadding() -> String {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(padding.utf8.count)
            for _ in 0..<padding.utf8.count {
                state = state &* 1_664_525 &+ 1_013_904_223
                bytes.append(alphabet[Int(state >> 26)])
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let entries: [[String: Any]] = try (0..<64).map { i in
            let text = try String(decoding: encoder.encode(["common": varied ? variedPadding() : padding, "id": String(format: "tag-%04d", i)]), as: UTF8.self)
            var content: [String: Any] = ["mimeType": "application/json", "size": text.utf8.count]
            if i < 63 { content["text"] = text }
            return ["startedDateTime": "2026-11-07T00:00:00Z", "time": 0,
                    "request": ["method": "GET", "url": "https://example.invalid/item"],
                    "response": ["status": 200, "content": content]]
        }
        return try JSONSerialization.data(withJSONObject: ["log": ["entries": entries]])

    }

    private func oracle(_ snapshot: ArtifactSnapshot, _ term: String) -> Answer {
        var answer = Answer()
        let pattern = Data(term.utf8)
        for (record, projection) in snapshot.records.enumerated() {
            guard let bytes = projection?.responseJSON else { answer.missing += 1; continue }
            var offset = 0
            while let range = bytes.range(of: pattern, in: offset..<bytes.count) {
                answer.hits.append(Hit(record: record, offset: range.lowerBound))
                offset = range.upperBound
            }
        }
        return answer
    }

    private func scan(_ snapshot: ArtifactSnapshot, term: String, ordinals: [Int]?, work: inout Work) throws -> Answer {
        if ordinals?.isEmpty == true { return Answer() }
        var args: [String: Any] = ["dataset": "responseJSON", "literal": term]
        args["recordIndices"] = ordinals
        let query = try ArtifactSearchQuery(inventory: false, arguments: args)
        var start = ArtifactSearch.Position()
        var answer = Answer()
        work.scans += 1
        while true {
            let page = try ArtifactSearch.page(snapshot: snapshot, query: query, from: start)
            work.pages += 1
            work.bytes += page.scannedBytes
            for row in page.items {
                answer.hits.append(Hit(record: try XCTUnwrap(row.recordIndex), offset: try XCTUnwrap(row.byteOffset)))
            }
            start = page.position
            if page.completeTraversal { break }
        }
        answer.missing = start.omissions.values.reduce(0, +)
        return answer
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }

    func testRepeatedSearchTradeoffs() throws {
        try compareStrategies(varied: false)
    }

    func testRepeatedSearchTradeoffsWithVariedPayloads() throws {
        try compareStrategies(varied: true)
    }

    private func compareStrategies(varied: Bool) throws {
        let snapshot = try ArtifactSnapshotReader.decode(data: Self.encodedHAR(varied: varied), kind: .har, deadline: .now.advanced(by: .seconds(5)))
        let sparse = "tag-0034"
        let workloads = [
            ("repeat", Array(repeating: sparse, count: 8)),
            ("distinct", [sparse, "absent-A", "tag-0007", "absent-B", "tag-0018", "absent-C", "tag-0049", "absent-D"]),
            ("dense", Array(repeating: "common", count: 8)),
            ("churn", [sparse, "missing", "tag-0025", sparse, "missing", "tag-0025", sparse, "missing"])
        ]
        let terms = Set(workloads.flatMap { $0.1 })
        let expected = Dictionary(uniqueKeysWithValues: terms.map { ($0, oracle(snapshot, $0)) })
        XCTAssertEqual(expected[sparse]?.hits.map(\.record), [34])
        XCTAssertEqual(expected["common"]?.hits.count, 63)
        XCTAssertTrue(expected.values.allSatisfy { $0.missing == 1 })
        let strategies = ["scan", "memo", "filter", "nativeProbe"]
        let bodyBytes = snapshot.records.reduce(0) { $0 + ($1?.responseJSON?.count ?? 0) }
        for trial in 0..<3 {
            for (name, queries) in workloads {
                for step in strategies.indices {
                    let strategy = strategies[(trial + step) % strategies.count]
                    let start = ContinuousClock.now
                    let filter = strategy == "filter" ? Filter(snapshot) : nil
                    let buildMs = filter == nil ? 0 : milliseconds(since: start)
                    var memo: [(term: String, answer: Answer)] = []
                    var work = Work()
                    var queryMs: [Double] = []
                    for term in queries {
                        let began = ContinuousClock.now
                        let answer: Answer
                        if strategy == "memo", let cached = memo.first(where: { $0.term == term }) {
                            answer = cached.answer
                            work.cacheHits += 1
                        } else {
                            let selected: [Int]?
                            if strategy == "nativeProbe" {
                                let literal = Data(term.utf8)
                                selected = snapshot.records.indices.filter { i in
                                    guard let data = snapshot.records[i]?.responseJSON else { return true }
                                    return data.range(of: literal) != nil
                                }
                            } else {
                                selected = filter?.candidates(snapshot, Array(term.utf8))
                            }
                            answer = try scan(snapshot, term: term, ordinals: selected, work: &work)
                            if strategy == "memo", answer.hits.count <= 20 {
                                if memo.count == 2 { memo.removeFirst() }
                                memo.append((term, answer))
                            }
                        }
                        queryMs.append(milliseconds(since: began))
                        XCTAssertEqual(answer, expected[term])
                    }
                    let result: [String: Any] = ["trial": trial, "workload": name, "strategy": strategy,
                        "corpus": varied ? "varied" : "repetitive",
                        "queries": queries.count, "sourceBytes": snapshot.byteCount, "buildMs": buildMs,
                        "queryMs": queryMs, "totalMs": buildMs + queryMs.reduce(0, +),
                        "scans": work.scans, "scanBytes": work.bytes, "scanPages": work.pages,
                        "filterBuildInputBytes": filter == nil ? 0 : bodyBytes,
                        "nativeProbeInputBytes": strategy == "nativeProbe" ? bodyBytes * queries.count : 0,
                        "memoHits": work.cacheHits, "retainedMemoEntries": memo.count,
                        "retainedHitPairs": memo.reduce(0) { $0 + $1.answer.hits.count },
                        "filterBytes": (filter?.words.count ?? 0) * MemoryLayout<UInt64>.stride]
                    let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                    print("EC10_TRIAL " + String(decoding: json, as: UTF8.self))
                }
            }
        }
    }
}
