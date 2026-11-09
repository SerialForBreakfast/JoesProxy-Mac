//
//  RollingCaptureOffPathExportTests.swift
//  JoesProxyTests
//
//  Unit tests for off-path rolling capture snapshot export (.jproxy and .har).
//

import XCTest
@testable import JoesProxy

@MainActor
final class RollingCaptureOffPathExportTests: XCTestCase {
    func testBackgroundExportsPreserveLiveStoreAndSnapshot() async throws {
        let store = InMemorySessionStore()
        let config = UserDefaultsAppConfiguration(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let coordinator = RollingCapturePersistenceCoordinator(
            sessionStore: store, configuration: config, proxyPortProvider: { 9090 },
            storageDirectoryOverride: tempDirectory
        )
        let sample = makeSampleSession()
        await coordinator.flushSnapshot(sessions: [sample])
        for format in [RollingCaptureExportFormat.recording, .har] {
            let destination = tempDirectory.appendingPathComponent(format == .har ? "copy.har" : "copy.jproxy")
            try await coordinator.exportSnapshotInBackground(to: destination, format: format)
            try await coordinator.exportSnapshotInBackground(to: destination, format: format)
            XCTAssertTrue(fileManager.fileExists(atPath: destination.path))
            if format == .recording {
                XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: coordinator.latestFileURL))
            }
            XCTAssertTrue(store.sessions.isEmpty)
            XCTAssertEqual(try coordinator.restoreLatestSnapshot().map(\.id), [sample.id])
        }
        do {
            try await coordinator.exportSnapshotInBackground(to: coordinator.latestFileURL, format: .recording)
            XCTFail("Export must not overwrite its recovery source")
        } catch {
            XCTAssertEqual(try coordinator.restoreLatestSnapshot().count, 1)
        }
        do {
            try await coordinator.exportSnapshotInBackground(to: tempDirectory, format: .har)
            XCTFail("A directory is not an export destination")
        } catch {
            XCTAssertEqual(try coordinator.restoreLatestSnapshot().count, 1)
        }
    }

    private var tempDirectory: URL!
    private var fileManager: FileManager!

    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
        tempDirectory = fileManager.temporaryDirectory.appendingPathComponent("RollingOffPath-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func makeSampleSession() -> SessionRecord {
        let request = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/v1/data",
            headers: [HTTPHeaderField(name: "Accept", value: "application/json")],
            bodyData: nil,
            bodySize: nil
        )
        let response = CapturedResponse(
            statusCode: 200,
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
            bodyData: "{\"status\": \"ok\"}".data(using: .utf8),
            bodySize: 16
        )
        return SessionRecord(
            request: request,
            response: response,
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
    }

    func testCopyLatestSnapshotDirectly() async throws {
        let store = InMemorySessionStore()
        let sample = makeSampleSession()
        store.load(sessions: [sample], epochChangeReason: "test_seed")

        let defaults = UserDefaults(suiteName: "RollingOffPath-\(UUID().uuidString)")!
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        configuration.rollingCaptureAutoSaveEnabled = true
        let coordinator = RollingCapturePersistenceCoordinator(
            sessionStore: store,
            configuration: configuration,
            fileManager: fileManager,
            proxyPortProvider: { 9090 },
            storageDirectoryOverride: tempDirectory
        )

        // Force a snapshot write
        await coordinator.flushSnapshot(sessions: [sample])

        // Copy snapshot off-path
        let destinationURL = tempDirectory.appendingPathComponent("exported_recording.jproxy")
        try coordinator.copyLatestSnapshot(to: destinationURL)

        XCTAssertTrue(fileManager.fileExists(atPath: destinationURL.path))
        let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
        XCTAssertGreaterThan(attributes[.size] as? Int ?? 0, 0)
    }

    func testExportLatestSnapshotAsHAR() async throws {
        let store = InMemorySessionStore()
        let sample = makeSampleSession()
        store.load(sessions: [sample], epochChangeReason: "test_seed")

        let defaults = UserDefaults(suiteName: "RollingOffPath-\(UUID().uuidString)")!
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        configuration.rollingCaptureAutoSaveEnabled = true
        let coordinator = RollingCapturePersistenceCoordinator(
            sessionStore: store,
            configuration: configuration,
            fileManager: fileManager,
            proxyPortProvider: { 9090 },
            storageDirectoryOverride: tempDirectory
        )

        await coordinator.flushSnapshot(sessions: [sample])

        let destinationHAR = tempDirectory.appendingPathComponent("exported_trace.har")
        let harService = HARSessionExportService()
        try coordinator.exportLatestSnapshotAsHAR(to: destinationHAR, harExportService: harService)

        XCTAssertTrue(fileManager.fileExists(atPath: destinationHAR.path))
        let data = try Data(contentsOf: destinationHAR)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let log = json?["log"] as? [String: Any]
        let entries = log?["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.count, 1)
    }
}
