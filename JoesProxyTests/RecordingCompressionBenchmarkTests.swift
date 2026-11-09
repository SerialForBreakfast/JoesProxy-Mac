import XCTest
@testable import JoesProxy

final class RecordingCompressionBenchmarkTests: XCTestCase {
    func testRepresentativeCompressionMatrix() async throws {
        try requireOptIn()
        let cases: [(name: String, targetMB: Int, body: Data)] = [
            ("json-heavy", 50, Data(repeating: UInt8(ascii: "A"), count: 512 * 1024)),
            ("mixed", 100, deterministicBody(byteCount: 512 * 1024, compressiblePrefixBytes: 256 * 1024)),
            ("media-heavy", 200, deterministicBody(byteCount: 512 * 1024, compressiblePrefixBytes: 0))
        ]

        for benchmark in cases {
            let estimatedEncodedSessionBytes = benchmark.body.count * 4 / 3 + 1_024
            let sessionCount = max(1, benchmark.targetMB * 1024 * 1024 / estimatedEncodedSessionBytes)
            let sessions = (0..<sessionCount).map { index in
                benchmarkSession(index: index, body: benchmark.body)
            }
            let envelope = SessionExportEnvelope(
                exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
                appVersion: "rc-benchmark",
                proxyPort: 9090,
                sessionCount: sessions.count,
                sessions: sessions
            )
            let metricsSampler = CurrentProcessMetricsSampler()
            let baselineResidentBytes = metricsSampler.sample().residentMemoryBytes
            let url = repositoryRoot
                .appendingPathComponent("memlog", isDirectory: true)
                .appendingPathComponent("Research", isDirectory: true)
                .appendingPathComponent("rc-\(benchmark.name)-\(UUID().uuidString)")
                .appendingPathExtension("jproxy")
            defer { try? FileManager.default.removeItem(at: url) }

            let saveStarted = Date()
            try JSONSessionExportService().exportAsRecording(envelope, to: url)
            let saveSeconds = Date().timeIntervalSince(saveStarted)

            let storedBytes = try fileSize(at: url)
            let logicalBytes = try gzipExpandedSize(at: url)
            let openStarted = Date()
            let result = try await JSONSessionRecordingImportService().open(from: url)
            let phase1Seconds = Date().timeIntervalSince(openStarted)
            let reduction = 1 - Double(storedBytes) / Double(logicalBytes)
            let peakResidentBytes = metricsSampler.sample().residentMemoryBytes
            let residentIncreaseBytes = peakResidentBytes >= baselineResidentBytes
                ? peakResidentBytes - baselineResidentBytes
                : 0
            var scratchHighWaterBytes = 0

            XCTAssertEqual(result.envelope.sessions.count, sessions.count)
            XCTAssertGreaterThan(logicalBytes, benchmark.targetMB * 1024 * 1024 * 85 / 100)
            XCTAssertLessThan(storedBytes, logicalBytes)
            if let phase2Source = result.phase2Source {
                scratchHighWaterBytes = await phase2Source.retainedScratchBytes()
                await phase2Source.cleanup()
            }

            print(
                "RC_MATRIX workload=\(benchmark.name) target_mb=\(benchmark.targetMB) " +
                "sessions=\(sessionCount) logical_bytes=\(logicalBytes) stored_bytes=\(storedBytes) " +
                "reduction_percent=\(String(format: "%.2f", reduction * 100)) " +
                "save_seconds=\(String(format: "%.3f", saveSeconds)) " +
                "phase1_seconds=\(String(format: "%.3f", phase1Seconds)) " +
                "resident_increase_bytes=\(residentIncreaseBytes) " +
                "scratch_high_water_bytes=\(scratchHighWaterBytes)"
            )
        }
    }

    func testCompressionLevelComparison() throws {
        try requireOptIn()
        let body = deterministicBody(byteCount: 512 * 1024, compressiblePrefixBytes: 256 * 1024)
        let sessions = (0..<30).map { benchmarkSession(index: $0, body: body) }
        let envelope = SessionExportEnvelope(
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "rc-level-benchmark",
            proxyPort: 9090,
            sessionCount: sessions.count,
            sessions: sessions
        )

        for level: Int32 in [1, 6, 9] {
            let url = repositoryRoot
                .appendingPathComponent("memlog", isDirectory: true)
                .appendingPathComponent("Research", isDirectory: true)
                .appendingPathComponent("rc-level-\(level)-\(UUID().uuidString)")
                .appendingPathExtension("jproxy")
            defer { try? FileManager.default.removeItem(at: url) }

            let started = Date()
            try JSONSessionExportService(recordingCompressionLevel: level)
                .exportAsRecording(envelope, to: url)
            let seconds = Date().timeIntervalSince(started)
            let storedBytes = try fileSize(at: url)
            let logicalBytes = try gzipExpandedSize(at: url)
            let reduction = 1 - Double(storedBytes) / Double(logicalBytes)
            print(
                "RC_LEVEL level=\(level) logical_bytes=\(logicalBytes) stored_bytes=\(storedBytes) " +
                "reduction_percent=\(String(format: "%.2f", reduction * 100)) " +
                "save_seconds=\(String(format: "%.3f", seconds))"
            )
        }
    }

    private func deterministicBody(byteCount: Int, compressiblePrefixBytes: Int) -> Data {
        var result = Data(repeating: 0, count: byteCount)
        var state: UInt64 = 0x4A_50_58_52
        result.withUnsafeMutableBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<byteCount {
                if index < compressiblePrefixBytes {
                    bytes[index] = UInt8(ascii: "T")
                } else {
                    state = state &* 6_364_136_223_846_793_005 &+ 1
                    bytes[index] = UInt8(truncatingIfNeeded: state >> 32)
                }
            }
        }
        return result
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func requireOptIn() throws {
        let markerURL = repositoryRoot
            .appendingPathComponent("memlog", isDirectory: true)
            .appendingPathComponent("Research", isDirectory: true)
            .appendingPathComponent(".run-workstream-rc-benchmarks")
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            throw XCTSkip("Create memlog/Research/.run-workstream-rc-benchmarks to run large RC benchmarks.")
        }
    }

    private func benchmarkSession(index: Int, body: Data) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                inspectionKind: .interceptedTLS,
                host: "capture.example.com",
                port: 443,
                path: "/segments/segment-\(index).bin",
                headers: [HTTPHeaderField(name: "Accept", value: "application/octet-stream")],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/octet-stream")],
                bodyData: body,
                bodySize: body.count
            ),
            state: .completed,
            timing: SessionTiming(
                startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                completedAt: Date(timeIntervalSince1970: 1_700_000_000.1 + Double(index))
            )
        )
    }

    private func fileSize(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    private func gzipExpandedSize(at url: URL) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let endOffset = try handle.seekToEnd()
        guard endOffset >= 4 else { throw RecordingContainerError.corruptPayload }
        try handle.seek(toOffset: endOffset - 4)
        guard let trailer = try handle.read(upToCount: 4), trailer.count == 4 else {
            throw RecordingContainerError.corruptPayload
        }
        return trailer.enumerated().reduce(0) { partial, item in
            partial | (Int(item.element) << (item.offset * 8))
        }
    }
}
