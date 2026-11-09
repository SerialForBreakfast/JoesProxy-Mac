import Foundation
import CoreGraphics
import ImageIO
import XCTest
@testable import JoesProxy

final class ArtifactSnapshotTests: XCTestCase {
    func testOrderedSavedPairAcrossFormatsAndCoverageLimits() throws {
        func snapshots(_ text: String) throws -> [ArtifactSnapshot] {
            let body = Data(text.utf8)
            var native = record()
            native.response = CapturedResponse(statusCode: 200, headers: [.init(name: "Content-Type", value: "application/json")],
                bodyData: body, bodySize: body.count)
            let entry: [String: Any] = ["startedDateTime": "2026-11-07T00:00:00Z", "time": 0,
                "request": ["method": "GET", "url": "https://example.invalid/items"],
                "response": ["status": 200, "content": ["mimeType": "application/json", "size": body.count, "text": text]]]
            let har = try JSONSerialization.data(withJSONObject: ["log": ["entries": [entry]]])
            return try [(.recording, recording(records: [native])), (ArtifactSourceKind.har, har)].map {
                try ArtifactSnapshotReader.decode(data: $0.1, kind: $0.0, deadline: deadline)
            }
        }
        let side: [String: Any] = ["handle": UUID().uuidString, "snapshotRevision": UUID().uuidString, "recordIndex": 0]
        let query = try SavedResponsePair(["baseline": side, "candidate": side])
        for left in try snapshots(#"[{"state":null},{"state":"private"}]"#) {
            for right in try snapshots(#"[{},{"state":"private"}]"#) {
                let report = try query.report(baseline: left, candidate: right)
                XCTAssertEqual(report.status, "complete")
                XCTAssertEqual(report.changes.map(\.kind), ["missing_count_changed", "occurrence_count_changed", "type_counts_changed"])
                XCTAssertEqual(report.wholeResponseBytesEqual, false)
                XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("private"))
            }
        }
        let empty = try snapshots("[]")[0]
        XCTAssertEqual(try query.report(baseline: empty, candidate: empty).wholeResponseBytesEqual, true)
        let whitespace = try query.report(baseline: empty, candidate: snapshots("[ ]")[0])
        XCTAssertTrue(whitespace.changes.isEmpty)
        XCTAssertEqual(whitespace.wholeResponseBytesEqual, false)
        let missing = try SavedResponsePair(["baseline": side, "candidate": side, "selectionPointer": "/absent"])
        XCTAssertEqual(try missing.report(baseline: empty, candidate: empty).status, "incomplete")
        let many = Dictionary(uniqueKeysWithValues: (0..<75).map { ("field\($0)", 0) })
        func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
        let bounded = try query.report(baseline: snapshots(json(many))[0], candidate: snapshots(json(many.mapValues { _ in ["x"] }))[0])
        XCTAssertEqual(bounded.status, "incomplete")
        XCTAssertLessThanOrEqual(bounded.changes.count, 32)
        XCTAssertFalse(bounded.changes.contains { $0.kind == "observed_path_added" })
        XCTAssertFalse(bounded.baseline.limits.isEmpty)
        let fields = Dictionary(uniqueKeysWithValues: (0..<26).map { ("x\($0)", 1) })
        let capped = try query.report(baseline: snapshots(json([fields, fields]))[0], candidate: snapshots(json([fields, [:]]))[0])
        XCTAssertEqual(capped.changes.count, 32)
        XCTAssertGreaterThan(capped.omittedChangeCount, 0)
        for bad: Any in [true, 1.25, 1000, -1] {
            XCTAssertThrowsError(try SavedResponsePair(["baseline": side.merging(["recordIndex": bad]) { _, n in n }, "candidate": side]))
        }
        XCTAssertThrowsError(try SavedResponsePair(["baseline": side, "candidate": side, "selectionPointer": "/bad~2"]))
    }

    func testNearLimitPackageMemoryAndLatencyTrend() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("near-limit.joesmock")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let bodies = [Data(repeating: 120, count: 15 * 1_048_576), Data(repeating: 121, count: 16 * 1_048_576)]
        let assets = bodies.enumerated().map { index, bytes in
            EffectBundleAsset(id: "synthetic-large-\(index)", role: .localFile, logicalPath: "large-\(index).txt",
                sha256: ArtifactSnapshotReader.hash(bytes), byteCount: bytes.count, contentType: "text/plain")
        }
        for (asset, bytes) in zip(assets, bodies) { try bytes.write(to: package.appendingPathComponent(asset.packageRelativePath)) }
        let manifest = EffectBundleManifest(schemaVersion: EffectBundleSchema.currentVersion, id: UUID(), name: "Synthetic memory fixture",
            notes: "", createdAt: Date(timeIntervalSince1970: 0), appVersion: "synthetic", privacy: .exactContent,
            defaultTTLSeconds: 60, assets: assets, responseEffects: [], hlsSubstitutions: [])
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent(EffectBundlePackageEngine.manifestFileName))
        let sampler = CurrentProcessMetricsSampler()
        let before = sampler.sample()
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTMemoryMetric(), XCTClockMetric()], options: options) {
            do {
                let snapshot = try ArtifactSnapshotReader.read(url: package, kind: .effectBundle, deadline: deadline)
                for (asset, bytes) in zip(assets, bodies) { XCTAssertEqual(snapshot.packageMembers[asset.packageRelativePath], bytes) }
                XCTAssertLessThanOrEqual(snapshot.retainedBytes, ArtifactSnapshotReader.maximumRetainedBytes)
            } catch { XCTFail("Near-limit source failed: \(error)") }
        }
        let after = sampler.sample()
        print("EFFICIENCY_METRIC artifact-source-memory-v1 assetBytes=\(bodies.reduce(0) { $0 + $1.count }) baselinePhysicalBytes=\(before.physicalFootprintBytes) endPhysicalBytes=\(after.physicalFootprintBytes) processLifetimePeakResidentBytes=\(after.peakResidentMemoryBytes)")
    }

    func testVersionedRecordingAndHARPreparationCohorts() throws {
        let countQuery = try ArtifactCalculation.Query(selectionPointer: "", operation: ["kind": "rowCount"])
        let entry = #"{"startedDateTime":"2026-11-06T00:00:00Z","time":1,"request":{"method":"GET","url":"https://api.example.com/items"},"response":{"status":200,"content":{"text":"[1,2]","size":5,"mimeType":"application/json"}}}"#
        for count in [10, 100, 1000] {
            let native = try recording(records: Array(repeating: record(), count: count))
            let har = Data(("{\"log\":{\"entries\":[" + Array(repeating: entry, count: count).joined(separator: ",") + "]}}").utf8)
            for (kind, bytes) in [(ArtifactSourceKind.recording, native), (.har, har)] {
                let start = ContinuousClock.now
                let snapshot = try ArtifactSnapshotReader.decode(data: bytes, kind: kind, deadline: deadline)
                XCTAssertEqual(snapshot.invalidRecordCount, 0)
                XCTAssertEqual(try snapshot.calculate(dataset: .sessionMetadata(nil), query: countQuery, deadline: deadline).result.count, count)
                XCTAssertLessThanOrEqual(snapshot.retainedBytes, ArtifactSnapshotReader.maximumRetainedBytes)
                print("EFFICIENCY_METRIC artifact-source-v1 kind=\(kind.rawValue) records=\(count) encodedBytes=\(bytes.count) retainedBytes=\(snapshot.retainedBytes) preparationElapsed=\(start.duration(to: .now))")
            }
        }
        XCTAssertThrowsError(try ArtifactSnapshotReader.decode(data: recording(records: Array(repeating: record(), count: 1001)), kind: .recording, deadline: deadline))
    }

    func testJSONAndTextByteBoundaryCohortsAndDepthLimit() throws {
        for size in [65_536, 1_048_576, 4_194_304] {
            let bytes = Data("[]".utf8) + Data(repeating: 32, count: size - 2)
            for kind in [ArtifactSourceKind.json, .text] {
                let start = ContinuousClock.now
                let snapshot = try ArtifactSnapshotReader.decode(data: bytes, kind: kind, deadline: deadline)
                XCTAssertEqual(snapshot.originalBytes.count, size)
                print("EFFICIENCY_METRIC artifact-source-v1 kind=\(kind.rawValue) encodedBytes=\(size) retainedBytes=\(snapshot.retainedBytes) preparationElapsed=\(start.duration(to: .now))")
            }
        }
        let tooLarge = Data("[]".utf8) + Data(repeating: 32, count: 4_194_303)
        for kind in [ArtifactSourceKind.json, .text] {
            XCTAssertThrowsError(try ArtifactSnapshotReader.decode(data: tooLarge, kind: kind, deadline: deadline))
        }
        let atDepth = Data((String(repeating: "[", count: 32) + String(repeating: "]", count: 32)).utf8)
        XCTAssertNoThrow(try ArtifactSnapshotReader.decode(data: atDepth, kind: .json, deadline: deadline))
        let beyondDepth = Data((String(repeating: "[", count: 33) + String(repeating: "]", count: 33)).utf8)
        XCTAssertThrowsError(try ArtifactSnapshotReader.decode(data: beyondDepth, kind: .json, deadline: deadline))
    }

    func testBundleMemberCohortsDigestValidationAndSymlinkRejection() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for memberCount in [1, 32, 256] {
            let package = root.appendingPathComponent("fixture-\(memberCount).joesmock")
            try FileManager.default.createDirectory(at: package.appendingPathComponent("assets"), withIntermediateDirectories: true)
            var assets: [EffectBundleAsset] = []
            for index in 0..<(memberCount - 1) {
                let bytes = Data("synthetic-\(index)".utf8)
                let asset = EffectBundleAsset(id: "asset-\(index)", role: .localFile, logicalPath: "item-\(index).txt",
                    sha256: ArtifactSnapshotReader.hash(bytes), byteCount: bytes.count, contentType: "text/plain")
                assets.append(asset)
                try bytes.write(to: package.appendingPathComponent(asset.packageRelativePath))
            }
            let manifest = EffectBundleManifest(schemaVersion: EffectBundleSchema.currentVersion, id: UUID(), name: "Synthetic corpus",
                notes: "", createdAt: Date(timeIntervalSince1970: 0), appVersion: "synthetic", privacy: .exactContent,
                defaultTTLSeconds: 60, assets: assets, responseEffects: [], hlsSubstitutions: [])
            try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent(EffectBundlePackageEngine.manifestFileName))
            let start = ContinuousClock.now
            let snapshot = try ArtifactSnapshotReader.read(url: package, kind: .effectBundle, deadline: deadline)
            XCTAssertEqual(snapshot.packageMembers.count, memberCount)
            XCTAssertTrue(snapshot.records.isEmpty)
            print("EFFICIENCY_METRIC artifact-source-v1 kind=effectBundle members=\(memberCount) encodedBytes=\(snapshot.byteCount) retainedBytes=\(snapshot.retainedBytes) preparationElapsed=\(start.duration(to: .now))")
            if let first = assets.first {
                let path = package.appendingPathComponent(first.packageRelativePath)
                try Data(repeating: 120, count: first.byteCount).write(to: path)
                XCTAssertThrowsError(try ArtifactSnapshotReader.read(url: package, kind: .effectBundle, deadline: deadline))
                try FileManager.default.removeItem(at: path)
                try FileManager.default.createSymbolicLink(at: path, withDestinationURL: package.appendingPathComponent(EffectBundlePackageEngine.manifestFileName))
                XCTAssertThrowsError(try ArtifactSnapshotReader.read(url: package, kind: .effectBundle, deadline: deadline))
            }
        }
    }

    func testGzipContainerUsesBoundedDecoderAndCancellationHook() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.jproxy")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: RecordingContainer.magic + Data([RecordingContainer.gzipFormat])))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let writer = try RecordingGzipWriter(fileHandle: handle)
        let bytes = try recording(records: [record()])
        try writer.write(bytes)
        try writer.finish()
        try handle.close()
        let data = try Data(contentsOf: url)
        let snapshot = try ArtifactSnapshotReader.decode(data: data, kind: .recording, deadline: deadline)
        XCTAssertEqual(snapshot.records.count, 1)
        XCTAssertEqual(snapshot.originalBytes, data)
        XCTAssertThrowsError(try RecordingGzipReader.data(fromCompressedData: data.dropFirst(5), maxExpandedBytes: 16))
        XCTAssertThrowsError(try RecordingGzipReader.data(fromCompressedData: data.dropFirst(5), checkProgress: { throw ArtifactAnalysisFailure.cancelled }))
    }

    func testImageMetadataOnlyRetainsExactEncodedBytes() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8,
            bytesPerRow: 12, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let snapshot = try ArtifactSnapshotReader.decode(data: bytes as Data, kind: .image, deadline: deadline)
        XCTAssertEqual(snapshot.imageWidth, 3)
        XCTAssertEqual(snapshot.imageHeight, 2)
        XCTAssertEqual(snapshot.frameCount, 1)
        XCTAssertEqual(snapshot.originalBytes, bytes as Data)
        XCTAssertTrue(snapshot.records.isEmpty)
    }

    func testEffectBundleInspectionIsReadOnlyAndRejectsUnexpectedMembers() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("synthetic.joesmock")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let manifest = EffectBundleManifest(schemaVersion: EffectBundleSchema.currentVersion, id: UUID(), name: "Synthetic artifact",
            notes: "", createdAt: Date(timeIntervalSince1970: 0), appVersion: "synthetic", privacy: .exactContent,
            defaultTTLSeconds: 60, assets: [], responseEffects: [], hlsSubstitutions: [])
        let data = try JSONEncoder().encode(manifest)
        let manifestURL = package.appendingPathComponent(EffectBundlePackageEngine.manifestFileName)
        try data.write(to: manifestURL)
        let snapshot = try ArtifactSnapshotReader.read(url: package, kind: .effectBundle, deadline: deadline)
        XCTAssertEqual(snapshot.packageMembers[EffectBundlePackageEngine.manifestFileName], data)
        XCTAssertEqual(try Data(contentsOf: manifestURL), data)
        XCTAssertTrue(snapshot.records.isEmpty)
        try Data("unexpected".utf8).write(to: package.appendingPathComponent("extra.txt"))
        XCTAssertThrowsError(try ArtifactSnapshotReader.read(url: package, kind: .effectBundle, deadline: deadline))
    }

    private var deadline: ContinuousClock.Instant { .now.advanced(by: .seconds(10)) }

    private func record() -> SessionRecord {
        let bytes = Data(#"[{"price":0.1},{"price":0.2}]"#.utf8)
        return SessionRecord(request: CapturedRequest(method: "GET", scheme: .http, host: "api.example.com",
            port: 80, path: "/items", headers: [], bodyData: nil, bodySize: nil),
            response: CapturedResponse(statusCode: 200, headers: [.init(name: "Content-Type", value: "application/json")],
                bodyData: bytes, bodySize: bytes.count), state: .completed, timing: SessionTiming(startedAt: Date(timeIntervalSince1970: 0)))
    }

    private func recording(records: [SessionRecord], schema: Int = RecordingConstants.currentSchemaVersion) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let entries = try records.map { try JSONSerialization.jsonObject(with: encoder.encode($0)) }
        return try JSONSerialization.data(withJSONObject: ["schemaVersion": schema, "exportedAt": "2026-11-06T00:00:00Z",
            "appVersion": "synthetic", "proxyPort": 9090, "sessionCount": records.count, "sessions": entries])
    }

    private func query() throws -> ArtifactCalculation.Query {
        try .init(selectionPointer: "", operation: ["kind": "numericSummary", "fieldPointer": "/price"])
    }

    func testReviewOfLiveBriefReuseForSavedRecordingAndHAR() throws {
        let body = Data(#"{"items":[{"state":null,"nested":{"a":2}},{"nested":{}},false]}"#.utf8)
        var live = record()
        live.response = CapturedResponse(statusCode: 200, headers: [.init(name: "Content-Type", value: "application/json")],
            bodyData: body, bodySize: body.count)
        let input = try MCPDisclosureSerializer().responseAnalysisInput(from: live, approvedCapabilities: [.bodyRead])
        let content: [String: Any] = ["mimeType": "application/json", "size": body.count, "text": String(decoding: body, as: UTF8.self)]
        let entry: [String: Any] = ["startedDateTime": "2026-11-07T00:00:00Z", "time": 0,
            "request": ["method": "GET", "url": "https://example.invalid/items"], "response": ["status": 200, "content": content]]
        let har = try JSONSerialization.data(withJSONObject: ["log": ["entries": [entry]]])
        for (kind, data) in [(ArtifactSourceKind.recording, try recording(records: [live])), (.har, har)] {
            let snapshot = try ArtifactSnapshotReader.decode(data: data, kind: kind, deadline: deadline)
            let projection = try XCTUnwrap(snapshot.records.first ?? nil)
            XCTAssertTrue(projection.hasSearchableUTF8)
            XCTAssertNotNil(projection.responseJSON)
            for pointer in ["", "/items", "/missing"] {
                let expected = ResponseEvidenceBrief.analyze(text: input.text, truncated: input.truncated,
                    unavailableReason: input.unavailableReason, pointer: pointer, includeStructure: true)
                let saved = try SavedResponseBrief(arguments: ["recordIndex": 0, "selectionPointer": pointer, "includeStructure": true]).report(snapshot: snapshot)
                XCTAssertEqual(saved, expected)
                if pointer == "/items" {
                    XCTAssertEqual(saved.itemCount, 3)
                    XCTAssertEqual(saved.fields.first { $0.name == "state" }?.missing, 1)
                    XCTAssertEqual(saved.fields.first { $0.name == "state" }?.null, 1)
                    XCTAssertEqual(saved.sourceSHA256, ArtifactSnapshotReader.hash(body))
                } else if pointer == "/missing" { XCTAssertEqual(saved.status, "selection_not_found") }
            }
        }
    }

    func testSavedAndLiveBytesHaveEquivalentFactsAndOriginalDigest() throws {
        let live = record()
        let original = try recording(records: [live])
        let snapshot = try ArtifactSnapshotReader.decode(data: original, kind: .recording, deadline: deadline)
        XCTAssertEqual(snapshot.originalBytes, original)
        XCTAssertEqual(snapshot.sourceSHA256, ArtifactSnapshotReader.hash(original))
        let saved = try snapshot.calculate(dataset: .responseJSON(0), query: query(), deadline: deadline)
        let liveReport = try ArtifactCalculation.analyze(data: XCTUnwrap(ArtifactSessionProjection(record: live).responseJSON), query: query(), deadline: deadline)
        XCTAssertEqual(saved.result.sum, "0.3")
        XCTAssertEqual(saved.result.sum, liveReport.result.sum)
        XCTAssertEqual(saved.rows, liveReport.rows)
    }

    func testLegacyAndLZFSEContainersPreserveReviewedBytes() throws {
        let original = try recording(records: [record()], schema: 0)
        let wrapped = try RecordingContainer.wrap(original)
        let snapshot = try ArtifactSnapshotReader.decode(data: wrapped, kind: .recording, deadline: deadline)
        XCTAssertEqual(snapshot.originalBytes, wrapped)
        XCTAssertEqual(snapshot.schemaVersion, 0)
        XCTAssertTrue(snapshot.warnings.contains("legacy_schema"))
        XCTAssertEqual(snapshot.records.count, 1)
        XCTAssertThrowsError(try ArtifactSnapshotReader.decode(data: recording(records: [], schema: 999), kind: .recording, deadline: deadline))
        XCTAssertThrowsError(try ArtifactSnapshotReader.decode(data: RecordingContainer.magic + Data([255, 0]), kind: .recording, deadline: deadline))
    }

    func testTruncatedAndMissingBodiesDoNotBecomeCompleteOnImport() throws {
        var partial = record()
        let response = try XCTUnwrap(partial.response)
        partial.response = CapturedResponse(statusCode: response.statusCode, headers: response.headers,
            bodyData: response.bodyData, bodySize: response.bodySize, bodyTruncated: true)
        let snapshot = try ArtifactSnapshotReader.decode(data: recording(records: [partial]), kind: .recording, deadline: deadline)
        XCTAssertFalse(try XCTUnwrap(snapshot.records.first!).responseComplete)
        XCTAssertThrowsError(try snapshot.calculate(dataset: .responseJSON(0), query: query(), deadline: deadline))
        XCTAssertTrue(snapshot.warnings.contains("incomplete_bodies"))
    }

    func testMalformedRecordKeepsPhysicalOrdinalAndExplicitSubsetCanSucceed() throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: recording(records: [record()])) as? [String: Any])
        let entries = try XCTUnwrap(root["sessions"] as? [Any])
        root["sessions"] = [[:], entries[0]]
        root["sessionCount"] = 2
        let snapshot = try ArtifactSnapshotReader.decode(data: JSONSerialization.data(withJSONObject: root), kind: .recording, deadline: deadline)
        XCTAssertEqual(snapshot.invalidRecordCount, 1)
        let count = try ArtifactCalculation.Query(selectionPointer: "", operation: ["kind": "rowCount"])
        XCTAssertThrowsError(try snapshot.calculate(dataset: .sessionMetadata(nil), query: count, deadline: deadline))
        XCTAssertEqual(try snapshot.calculate(dataset: .sessionMetadata([1]), query: count, deadline: deadline).result.count, 1)
        XCTAssertEqual(try snapshot.calculate(dataset: .responseJSON(1), query: query(), deadline: deadline).result.sum, "0.3")
    }

    func testHARDecodedContentRequiresMeasuredCompleteness() throws {
        let text = #"{"log":{"entries":[{"startedDateTime":"2026-11-06T00:00:00Z","time":1,"request":{"method":"GET","url":"https://api.example.com/items"},"response":{"status":200,"bodySize":99,"headers":[{"name":"Content-Encoding","value":"gzip"}],"content":{"text":"[1,2]","size":5,"mimeType":"application/json"}}}]}}"#
        let snapshot = try ArtifactSnapshotReader.decode(data: Data(text.utf8), kind: .har, deadline: deadline)
        let query = try ArtifactCalculation.Query(selectionPointer: "", operation: ["kind": "numericSummary", "fieldPointer": ""])
        XCTAssertEqual(try snapshot.calculate(dataset: .responseJSON(0), query: query, deadline: deadline).result.sum, "3")
        let partial = text.replacingOccurrences(of: "\"size\":5", with: "\"size\":6")
        let unavailable = try ArtifactSnapshotReader.decode(data: Data(partial.utf8), kind: .har, deadline: deadline)
        XCTAssertThrowsError(try unavailable.calculate(dataset: .responseJSON(0), query: query, deadline: deadline))
        let unsupported = text.replacingOccurrences(of: "\"size\":5", with: "\"size\":5,\"encoding\":\"unknown\"")
        let unsupportedSnapshot = try ArtifactSnapshotReader.decode(data: Data(unsupported.utf8), kind: .har, deadline: deadline)
        XCTAssertThrowsError(try unsupportedSnapshot.calculate(dataset: .responseJSON(0), query: query, deadline: deadline))
    }

    func testJSONAndTextAdmissionDoNotSilentlyTruncate() throws {
        let raw = Data(#"{"items":[1,2]}"#.utf8)
        XCTAssertEqual(try ArtifactSnapshotReader.decode(data: raw, kind: .json, deadline: deadline).originalBytes, raw)
        XCTAssertThrowsError(try ArtifactSnapshotReader.decode(data: Data(#"{"a":1,"a":2}"#.utf8), kind: .json, deadline: deadline))
        XCTAssertThrowsError(try ArtifactSnapshotReader.decode(data: Data(repeating: 32, count: 4_194_305), kind: .text, deadline: deadline))
        XCTAssertThrowsError(try ArtifactSnapshotReader.decode(data: Data([0xFF]), kind: .text, deadline: deadline))
        XCTAssertThrowsError(try ArtifactSnapshotReader.decode(data: Data("not an image".utf8), kind: .image, deadline: deadline))
    }

    func testStableFileReadKeepsCopyAfterOriginalEditAndRejectsSymlink() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("source.json")
        try Data("[1,2]".utf8).write(to: original)
        let snapshot = try ArtifactSnapshotReader.read(url: original, kind: .json, deadline: deadline)
        try Data("[9]".utf8).write(to: original)
        XCTAssertEqual(snapshot.originalBytes, Data("[1,2]".utf8))
        let link = root.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        XCTAssertThrowsError(try ArtifactSnapshotReader.read(url: link, kind: .json, deadline: deadline))
    }

    private func fixtureDirectory() throws -> URL {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let root = repo.appendingPathComponent("build/ArtifactContracts/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
