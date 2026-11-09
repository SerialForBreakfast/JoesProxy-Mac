import XCTest
@testable import JoesProxy

final class ResponsivenessMonitorTests: XCTestCase {
    func testHealthyHeartbeatNeverReportsIncident() {
        var detector = ResponsivenessDetector()
        for tick in 0..<100 {
            let result = detector.tick(at: Double(tick))
            XCTAssertTrue(result.shouldPing)
            XCTAssertNil(result.event)
            XCTAssertNil(detector.acknowledge())
        }
    }

    func testStallIsReportedOnceAndAcknowledgementMarksRecovery() {
        var detector = ResponsivenessDetector()
        XCTAssertTrue(detector.tick(at: 0).shouldPing)
        for tick in 1..<5 {
            let result = detector.tick(at: Double(tick))
            XCTAssertFalse(result.shouldPing)
            XCTAssertEqual(result.event, tick == 1 ? .delayed : nil)
        }
        XCTAssertEqual(detector.tick(at: 5).event, .stalled)
        XCTAssertNil(detector.tick(at: 6).event)
        XCTAssertEqual(detector.acknowledge(), .recovered)
        XCTAssertNil(detector.acknowledge())
        XCTAssertTrue(detector.tick(at: 7).shouldPing)
    }

    func testShortDelayHasBoundedEvidenceWithoutPersistentStall() {
        var detector = ResponsivenessDetector()
        _ = detector.tick(at: 0)
        XCTAssertNil(detector.tick(at: 0.5).event)
        XCTAssertEqual(detector.tick(at: 1).event, .delayed)
        XCTAssertNil(detector.tick(at: 2).event)
        XCTAssertFalse(detector.isStalled)
        XCTAssertEqual(detector.acknowledge(), .delayRecovered)
        XCTAssertNil(detector.acknowledge())
    }

    func testSleepOrDelayedMonitorDoesNotBecomeUIHang() {
        var detector = ResponsivenessDetector()
        _ = detector.tick(at: 0)
        _ = detector.tick(at: 1)
        let wake = detector.tick(at: 600)
        XCTAssertTrue(wake.invalidated)
        XCTAssertNil(wake.event)
        XCTAssertFalse(detector.isStalled)
        XCTAssertNil(detector.acknowledge())
        XCTAssertTrue(detector.tick(at: 0).invalidated)
    }

    func testIncidentStoreIsBoundedAndReplacesOnlyLatestRecord() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ResponsivenessTests/\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResponsivenessIncidentStore(directory: directory)
        let sample = ResponsivenessSample(at: Date(timeIntervalSince1970: 1), pendingSeconds: 5,
            physicalFootprintBytes: 1024, cpuPercent: 99, activeChannels: 2, capturePending: 3,
            captureRejected: 4, progress: [.init(stage: "routingStarted", count: 5, lastObservedAt: nil)])
        var incident = ResponsivenessIncident(schemaVersion: 1, appVersion: "test", detectedAt: sample.at,
            recoveredAt: nil, onsetSamples: Array(repeating: sample, count: 30))
        try store.save(incident)
        incident.recoveredAt = sample.at.addingTimeInterval(1)
        try store.save(incident)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let data = try Data(contentsOf: XCTUnwrap(files.first))
        XCTAssertLessThanOrEqual(data.count, ResponsivenessIncidentStore.maximumBytes)
        let decoded = try JSONDecoder().decode(ResponsivenessIncident.self, from: data)
        XCTAssertEqual(decoded.recoveredAt, incident.recoveredAt)
        XCTAssertEqual(decoded.onsetSamples.count, 30)
        let oversized = ResponsivenessIncident(schemaVersion: 1, appVersion: "test", detectedAt: sample.at,
            recoveredAt: nil, onsetSamples: Array(repeating: sample, count: 31))
        XCTAssertThrowsError(try store.save(oversized))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)), data)
    }
}
