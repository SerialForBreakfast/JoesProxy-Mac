import Combine
import XCTest
@testable import JoesProxy

// MARK: - Schema versioning

final class SessionExportEnvelopeSchemaVersionTests: XCTestCase {

    func testRoundTripWithCurrentSchemaVersion() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let envelope = makeEnvelope()
        let data = try encoder.encode(envelope)
        let decoded = try decoder.decode(SessionExportEnvelope.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, RecordingConstants.currentSchemaVersion)
        XCTAssertEqual(decoded.sessions.count, envelope.sessions.count)
    }

    func testMissingSchemaVersionKeyDecodesAsZero() throws {
        let json = """
        {
          "exportedAt": "2024-01-01T00:00:00Z",
          "appVersion": "0.0.0-fixture",
          "proxyPort": 9090,
          "sessionCount": 0,
          "sessions": []
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(SessionExportEnvelope.self, from: json)
        XCTAssertEqual(envelope.schemaVersion, 0)
    }

    func testSchemaVersionIsPreserved() throws {
        let json = """
        {
          "schemaVersion": 2,
          "exportedAt": "2024-01-01T00:00:00Z",
          "appVersion": "0.0.0-fixture",
          "proxyPort": 9090,
          "sessionCount": 0,
          "sessions": []
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(SessionExportEnvelope.self, from: json)
        XCTAssertEqual(envelope.schemaVersion, 2)
    }

    func testMissingRecordingFidelityDecodesAsNil() throws {
        let json = """
        {
          "schemaVersion": 2,
          "exportedAt": "2024-01-01T00:00:00Z",
          "appVersion": "0.0.0-fixture",
          "proxyPort": 9090,
          "sessionCount": 0,
          "sessions": []
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(SessionExportEnvelope.self, from: json)
        XCTAssertNil(envelope.recordingFidelity)
    }
}

// MARK: - Body truncation

final class BodyTruncationTests: XCTestCase {
    private let service = JSONSessionExportService()
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jproxy")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    func testBodyBelowLimitNotTruncated() throws {
        let body = Data(repeating: 0xAB, count: 100)
        let session = makeSession(requestBody: body, responseBody: body)
        let envelope = makeEnvelope(sessions: [session])

        try service.exportAsRecording(envelope, to: tempURL)

        let decoded = try roundTrip(from: tempURL)
        XCTAssertFalse(decoded.sessions[0].request.bodyTruncated)
        XCTAssertFalse(decoded.sessions[0].response?.bodyTruncated == true)
        XCTAssertEqual(decoded.sessions[0].request.bodyData, body)
    }

    func testFullRecordingPreservesBodiesAbovePreviewLimit() throws {
        let oversized = Data(repeating: 0xCC, count: RecordingConstants.bodySizeLimit + 500)
        let session = makeSession(requestBody: oversized, responseBody: oversized)
        let envelope = makeEnvelope(sessions: [session])

        try service.exportAsRecording(envelope, to: tempURL)

        let decoded = try roundTrip(from: tempURL)
        XCTAssertFalse(decoded.sessions[0].request.bodyTruncated)
        XCTAssertFalse(decoded.sessions[0].response?.bodyTruncated == true)
        XCTAssertEqual(decoded.sessions[0].request.bodyData, oversized)
        XCTAssertEqual(decoded.sessions[0].response?.bodyData, oversized)
    }

    func testBodyTruncatedFalseIsOmittedFromJSON() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let request = makeCapturedRequest(bodyTruncated: false)
        let data = try encoder.encode(request)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("bodyTruncated"), "bodyTruncated=false should be omitted from JSON")
    }

    func testBodyTruncatedTrueIsPresentInJSON() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let request = makeCapturedRequest(bodyTruncated: true)
        let data = try encoder.encode(request)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("bodyTruncated"), "bodyTruncated=true should be present in JSON")
    }

    /// bodyDeferred is a transient in-memory loading flag and must never appear in serialized JSON,
    /// regardless of its value.
    func testBodyDeferredIsNeverSerializedToJSON() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let deferred = makeCapturedRequest(bodyTruncated: false, bodyDeferred: true)
        let deferredJSON = String(data: try encoder.encode(deferred), encoding: .utf8)!
        XCTAssertFalse(deferredJSON.contains("bodyDeferred"),
                       "bodyDeferred=true must never be written to JSON")

        let notDeferred = makeCapturedRequest(bodyTruncated: false, bodyDeferred: false)
        let notDeferredJSON = String(data: try encoder.encode(notDeferred), encoding: .utf8)!
        XCTAssertFalse(notDeferredJSON.contains("bodyDeferred"),
                       "bodyDeferred=false must never be written to JSON")
    }

    /// bodyDeferred defaults to false when absent from JSON (e.g. all persisted records).
    func testBodyDeferredDefaultsFalseWhenAbsentFromJSON() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let original = makeCapturedRequest(bodyTruncated: false, bodyDeferred: false)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(CapturedRequest.self, from: data)
        XCTAssertFalse(decoded.bodyDeferred, "bodyDeferred should be false when absent from JSON")
    }

    func testStandardExportDoesNotTruncate() throws {
        let oversized = Data(repeating: 0xDD, count: RecordingConstants.bodySizeLimit + 1000)
        let session = makeSession(requestBody: oversized, responseBody: nil)
        let envelope = makeEnvelope(sessions: [session])

        try service.export(envelope, to: tempURL)

        let decoded = try roundTrip(from: tempURL)
        XCTAssertEqual(decoded.sessions[0].request.bodyData?.count, oversized.count)
        XCTAssertFalse(decoded.sessions[0].request.bodyTruncated)
    }

    func testOriginalSessionsAreNotMutated() throws {
        let oversized = Data(repeating: 0xEE, count: RecordingConstants.bodySizeLimit + 200)
        let session = makeSession(requestBody: oversized, responseBody: nil)
        let envelope = makeEnvelope(sessions: [session])

        try service.exportAsRecording(envelope, to: tempURL)

        XCTAssertEqual(envelope.sessions[0].request.bodyData?.count, oversized.count)
        XCTAssertFalse(envelope.sessions[0].request.bodyTruncated)
    }

    func testMetadataOnlyRecordingOmitsBodiesAndPersistsReason() throws {
        let body = Data("secret".utf8)
        let session = makeSession(requestBody: body, responseBody: body)
        let envelope = makeEnvelope(sessions: [session])

        try service.exportAsRecording(envelope, to: tempURL, fidelity: .metadataOnly)

        let decoded = try roundTrip(from: tempURL)
        XCTAssertNil(decoded.sessions[0].request.bodyData)
        XCTAssertNil(decoded.sessions[0].response?.bodyData)
        XCTAssertEqual(decoded.sessions[0].request.recordingBodyOmissionReason, .metadataOnly)
        XCTAssertEqual(decoded.sessions[0].response?.recordingBodyOmissionReason, .metadataOnly)
        XCTAssertEqual(decoded.recordingFidelity, .metadataOnly)
    }

    func testMetadataOnlyHighVolumeRecordingOmitsBodiesAndKeepsSessionMetadata() throws {
        let sessions = (0..<500).map { index in
            let body = Data("{\"index\":\(index),\"payload\":\"metadata-only\"}".utf8)
            return makeSession(
                path: "/events/\(index)",
                requestHeaders: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                requestBody: body,
                responseBody: body
            )
        }
        let envelope = makeEnvelope(sessions: sessions)

        try service.exportAsRecording(envelope, to: tempURL, fidelity: .metadataOnly)

        let decoded = try roundTrip(from: tempURL)
        XCTAssertEqual(decoded.recordingFidelity, .metadataOnly)
        XCTAssertEqual(decoded.sessionCount, sessions.count)
        XCTAssertEqual(decoded.sessions.count, sessions.count)
        XCTAssertEqual(decoded.sessions.first?.request.path, "/events/0")
        XCTAssertEqual(decoded.sessions.last?.request.path, "/events/499")
        XCTAssertTrue(decoded.sessions.allSatisfy { $0.request.bodyData == nil })
        XCTAssertTrue(decoded.sessions.allSatisfy { $0.response?.bodyData == nil })
        XCTAssertTrue(decoded.sessions.allSatisfy { $0.request.bodySize != nil })
        XCTAssertTrue(decoded.sessions.allSatisfy { $0.response?.bodySize != nil })
        XCTAssertTrue(decoded.sessions.allSatisfy { $0.request.recordingBodyOmissionReason == .metadataOnly })
        XCTAssertTrue(decoded.sessions.allSatisfy { $0.response?.recordingBodyOmissionReason == .metadataOnly })
    }

    func testTextBodiesOnlyOmitsBinaryBodiesAndPersistsReason() throws {
        let binaryBody = Data([0x89, 0x50, 0x4E, 0x47, 0x00])
        let session = makeSession(
            path: "/image.png",
            requestHeaders: [HTTPHeaderField(name: "Content-Type", value: "application/octet-stream")],
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "image/png")],
            requestBody: binaryBody,
            responseBody: binaryBody
        )
        let envelope = makeEnvelope(sessions: [session])

        try service.exportAsRecording(envelope, to: tempURL, fidelity: .textBodiesOnly)

        let decoded = try roundTrip(from: tempURL)
        XCTAssertNil(decoded.sessions[0].request.bodyData)
        XCTAssertNil(decoded.sessions[0].response?.bodyData)
        XCTAssertEqual(decoded.sessions[0].request.recordingBodyOmissionReason, .binaryExcludedFromTextMode)
        XCTAssertEqual(decoded.sessions[0].response?.recordingBodyOmissionReason, .binaryExcludedFromTextMode)
    }

    func testMediaFocusedKeepsInitSegmentButOmitsOversizedMediaSegment() throws {
        let initBody = Data(repeating: 0xAA, count: RecordingConstants.mediaInitSegmentBodySizeLimit - 32)
        let segmentBody = Data(repeating: 0xBB, count: RecordingConstants.mediaSegmentBodySizeLimit + 32)
        let initSession = makeSession(
            path: "/video/init-stream0.m4s",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "video/mp4")],
            responseBody: initBody
        )
        let segmentSession = makeSession(
            path: "/video/segment-001.m4s",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "video/mp4")],
            responseBody: segmentBody
        )
        let envelope = makeEnvelope(sessions: [initSession, segmentSession])

        try service.exportAsRecording(envelope, to: tempURL, fidelity: .mediaFocused)

        let decoded = try roundTrip(from: tempURL)
        XCTAssertEqual(decoded.sessions[0].response?.bodyData, initBody)
        XCTAssertNil(decoded.sessions[0].response?.recordingBodyOmissionReason)
        XCTAssertNil(decoded.sessions[1].response?.bodyData)
        XCTAssertEqual(decoded.sessions[1].response?.recordingBodyOmissionReason, .oversizedMediaExcluded)
        XCTAssertEqual(decoded.recordingFidelity, .mediaFocused)
    }

    func testMediaFocusedOmitsMultipleOversizedMediaSegmentsAndKeepsMetadata() throws {
        let oversizedSegmentBody = Data(
            repeating: 0xBC,
            count: RecordingConstants.mediaSegmentBodySizeLimit + 1_024
        )
        let sessions = (0..<24).map { index in
            makeSession(
                path: "/video/segment-\(String(format: "%03d", index)).m4s",
                responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "video/mp4")],
                responseBody: oversizedSegmentBody
            )
        }
        let envelope = makeEnvelope(sessions: sessions)

        try service.exportAsRecording(envelope, to: tempURL, fidelity: .mediaFocused)

        let decoded = try roundTrip(from: tempURL)
        XCTAssertEqual(decoded.recordingFidelity, .mediaFocused)
        XCTAssertEqual(decoded.sessions.count, sessions.count)
        XCTAssertTrue(decoded.sessions.allSatisfy { $0.response?.bodyData == nil })
        XCTAssertTrue(decoded.sessions.allSatisfy { $0.response?.bodySize == oversizedSegmentBody.count })
        XCTAssertTrue(decoded.sessions.allSatisfy { $0.response?.recordingBodyOmissionReason == .oversizedMediaExcluded })
        XCTAssertEqual(decoded.sessions.first?.request.path, "/video/segment-000.m4s")
        XCTAssertEqual(decoded.sessions.last?.request.path, "/video/segment-023.m4s")
    }

    func testRecordingBodyOmissionReasonIsSerializedWhenPresent() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let request = CapturedRequest(
            method: "GET",
            scheme: .http,
            host: "example.com",
            port: 80,
            path: "/",
            headers: [],
            bodyData: nil,
            bodySize: 8,
            bodyTruncated: false,
            recordingBodyOmissionReason: .metadataOnly
        )
        let data = try encoder.encode(request)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("recordingBodyOmissionReason"))
    }
}

// MARK: - Import service: basic behaviour

final class JSONSessionRecordingImportServiceTests: XCTestCase {
    private let service = JSONSessionRecordingImportService()
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jproxy")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    func testValidFileLoadsSuccessfully() async throws {
        let envelope = makeEnvelope(sessions: [makeSession()])
        try writeEnvelope(envelope, to: tempURL)

        let result = try await service.open(from: tempURL)
        XCTAssertEqual(result.envelope.sessions.count, 1)
        XCTAssertNil(result.schemaNotice)
        XCTAssertTrue(result.failedSessionIDs.isEmpty)
    }

    func testMissingFileThrowsError() async {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).jproxy")

        do {
            _ = try await service.open(from: missingURL)
            XCTFail("Expected RecordingOpenError.fileNotFound")
        } catch RecordingOpenError.fileNotFound {
            // pass
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMalformedJSONThrowsError() async throws {
        try "not json at all".data(using: .utf8)!.write(to: tempURL)

        do {
            _ = try await service.open(from: tempURL)
            XCTFail("Expected RecordingOpenError.malformedJSON")
        } catch RecordingOpenError.malformedJSON {
            // pass
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // schema too new → throws when bestEffort is false (default)
    func testSchemaTooNewThrowsWithoutBestEffort() async throws {
        try writeFutureSchemaFile(to: tempURL, sessions: [])

        do {
            _ = try await service.open(from: tempURL)
            XCTFail("Expected RecordingOpenError.schemaTooNew")
        } catch RecordingOpenError.schemaTooNew(let version) {
            XCTAssertEqual(version, RecordingConstants.currentSchemaVersion + 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // schema too new + bestEffort: true → succeeds with advisory notice
    func testSchemaTooNewBestEffortSucceedsWithNotice() async throws {
        try writeFutureSchemaFile(to: tempURL, sessions: [makeSession()])

        let result = try await service.open(from: tempURL, bestEffort: true)
        XCTAssertFalse(result.envelope.sessions.isEmpty)
        XCTAssertNotNil(result.schemaNotice, "Best-effort future-schema load should set a notice")
    }

    func testSchemaVersion0ProducesNotice() async throws {
        let json = """
        {
          "exportedAt": "2024-01-01T00:00:00Z",
          "appVersion": "0.0.0-fixture",
          "proxyPort": 9090,
          "sessionCount": 0,
          "sessions": []
        }
        """.data(using: .utf8)!
        try json.write(to: tempURL)

        let result = try await service.open(from: tempURL)
        XCTAssertNotNil(result.schemaNotice)
    }

    func testEmptySessionsLoadsSuccessfully() async throws {
        let envelope = makeEnvelope(sessions: [])
        try writeEnvelope(envelope, to: tempURL)

        let result = try await service.open(from: tempURL)
        XCTAssertTrue(result.envelope.sessions.isEmpty)
    }
}

// MARK: - Import service: per-session decode

final class PerSessionDecodeTests: XCTestCase {
    private let service = JSONSessionRecordingImportService()
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jproxy")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    // A malformed session alongside a valid one: valid loads, malformed is skipped.
    func testMalformedSessionIsSkippedAndValidSessionLoads() async throws {
        let validSession = makeSession()
        let fullData = try encodeEnvelope(makeEnvelope(sessions: [validSession]))

        // Inject a broken session entry before the valid one.
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: fullData) as? [String: Any])
        var sessions = try XCTUnwrap(root["sessions"] as? [[String: Any]])
        sessions.insert(["id": UUID().uuidString, "broken_field": 42], at: 0)
        root["sessions"] = sessions
        let brokenData = try JSONSerialization.data(withJSONObject: root)
        try brokenData.write(to: tempURL)

        let result = try await service.open(from: tempURL)

        XCTAssertEqual(result.envelope.sessions.count, 1, "Valid session should load")
        XCTAssertEqual(result.failedSessionIDs.count, 1, "Malformed session should be captured in failedSessionIDs")
        XCTAssertEqual(result.envelope.sessions[0].id, validSession.id)
    }

    // All sessions malformed: empty result with all IDs in failedSessionIDs.
    func testAllMalformedSessionsProducesEmptyLoad() async throws {
        let fullData = try encodeEnvelope(makeEnvelope(sessions: []))

        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: fullData) as? [String: Any])
        root["sessions"] = [["bad": 1], ["also_bad": 2]]
        let brokenData = try JSONSerialization.data(withJSONObject: root)
        try brokenData.write(to: tempURL)

        let result = try await service.open(from: tempURL)

        XCTAssertTrue(result.envelope.sessions.isEmpty)
        XCTAssertEqual(result.failedSessionIDs.count, 2)
    }

    // Multiple valid sessions all decode correctly and failedSessionIDs is empty.
    func testMultipleValidSessionsHaveNoFailures() async throws {
        let sessions = [makeSession(), makeSession(), makeSession()]
        try writeEnvelope(makeEnvelope(sessions: sessions), to: tempURL)

        let result = try await service.open(from: tempURL)

        XCTAssertEqual(result.envelope.sessions.count, 3)
        XCTAssertTrue(result.failedSessionIDs.isEmpty)
    }
}

// MARK: - RecordingLoadCoordinator

@MainActor
final class RecordingLoadCoordinatorTests: XCTestCase {
    private var sessionStore: InMemorySessionStore!
    private var tempURL: URL!
    private let exportService = JSONSessionExportService()
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        sessionStore = InMemorySessionStore()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jproxy")
    }

    override func tearDown() {
        cancellables = []
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    // MARK: Basic load modes

    func testReplaceModeReplacesExistingSessions() async throws {
        let existing = makeSession()
        sessionStore.append(existing)

        let imported = makeSession()
        try writeEnvelope(makeEnvelope(sessions: [imported]), to: tempURL)

        let coordinator = makeCoordinator()
        await coordinator.load(from: tempURL, mode: .replace)

        XCTAssertEqual(sessionStore.sessions.count, 1)
        XCTAssertEqual(sessionStore.sessions[0].id, imported.id)
    }

    func testMergeModeAppendsDeduplicated() async throws {
        let existing = makeSession()
        sessionStore.append(existing)

        let imported = makeSession()
        try writeEnvelope(makeEnvelope(sessions: [imported, existing]), to: tempURL)

        let coordinator = makeCoordinator()
        await coordinator.load(from: tempURL, mode: .merge)

        XCTAssertEqual(sessionStore.sessions.count, 2)
        XCTAssertTrue(sessionStore.sessions.contains(where: { $0.id == existing.id }))
        XCTAssertTrue(sessionStore.sessions.contains(where: { $0.id == imported.id }))
    }

    func testLoadStateIsIdleAfterSuccess() async throws {
        try writeEnvelope(makeEnvelope(sessions: []), to: tempURL)

        let coordinator = makeCoordinator()
        await coordinator.load(from: tempURL, mode: .replace)

        XCTAssertEqual(coordinator.loadState, .idle)
    }

    func testLoadStateIsFailedForMissingFile() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-file-\(UUID().uuidString).jproxy")

        let coordinator = makeCoordinator()
        await coordinator.load(from: missing, mode: .replace)

        if case .failed = coordinator.loadState {
            // pass
        } else {
            XCTFail("Expected .failed, got \(coordinator.loadState)")
        }
    }

    // MARK: Partial load warning (failed sessions)

    func testLoadWarningStateWhenSessionsFail() async {
        let failedID = UUID()
        let result = RecordingLoadResult(
            envelope: makeEnvelope(sessions: []),
            failedSessionIDs: [failedID],
            schemaNotice: nil,
            phase2Source: nil
        )
        let mock = MockSessionRecordingImportService(result: .success(result))
        let coordinator = RecordingLoadCoordinator(importService: mock, sessionStore: sessionStore)

        await coordinator.load(from: tempURL, mode: .replace)

        if case .loadWarning(let ids) = coordinator.loadState {
            XCTAssertEqual(ids, [failedID])
        } else {
            XCTFail("Expected .loadWarning, got \(coordinator.loadState)")
        }
    }

    // MARK: Schema-version warning flow

    func testSchemaTooNewSetsPendingWarningInsteadOfFailing() async throws {
        try writeFutureSchemaFile(to: tempURL, sessions: [makeSession()])

        let coordinator = makeCoordinator()
        await coordinator.load(from: tempURL, mode: .replace)

        XCTAssertNotNil(coordinator.pendingSchemaWarning, "schemaTooNew should surface as pendingSchemaWarning")
        XCTAssertEqual(coordinator.pendingSchemaWarning?.fileVersion, RecordingConstants.currentSchemaVersion + 1)
        XCTAssertEqual(coordinator.loadState, .idle, "Load state should not be .failed for schema warning")
        XCTAssertTrue(sessionStore.sessions.isEmpty, "No sessions should be loaded before user confirms")
    }

    func testConfirmSchemaWarningLoadsSessionsWithNotice() async throws {
        try writeFutureSchemaFile(to: tempURL, sessions: [makeSession()])

        let coordinator = makeCoordinator()
        await coordinator.load(from: tempURL, mode: .replace)
        XCTAssertNotNil(coordinator.pendingSchemaWarning)

        await coordinator.confirmSchemaWarning()

        XCTAssertNil(coordinator.pendingSchemaWarning)
        XCTAssertNotNil(coordinator.schemaNotice, "Best-effort load should produce an advisory notice")
        XCTAssertEqual(sessionStore.sessions.count, 1)
        XCTAssertEqual(coordinator.loadState, .idle)
    }

    func testCancelSchemaWarningResetsStateAndLeavesStoreEmpty() async throws {
        try writeFutureSchemaFile(to: tempURL, sessions: [makeSession()])

        let coordinator = makeCoordinator()
        await coordinator.load(from: tempURL, mode: .replace)
        coordinator.cancelSchemaWarning()

        XCTAssertNil(coordinator.pendingSchemaWarning)
        XCTAssertEqual(coordinator.loadState, .idle)
        XCTAssertTrue(sessionStore.sessions.isEmpty)
    }

    // MARK: Phase-2 body loading

    func testPhase2FillsBodiesAfterPhase1BodylessLoad() async throws {
        let body = Data(repeating: 0xBB, count: 64)
        let session = makeSession(requestBody: body)
        let fullEnvelope = makeEnvelope(sessions: [session])
        let rawData = try encodeEnvelope(fullEnvelope)

        // Build a phase-1 envelope with bodies stripped from the same JSON.
        let phase1Envelope = try strippingBodies(from: rawData)
        XCTAssertNil(phase1Envelope.sessions[0].request.bodyData, "Phase-1 body should be nil")

        let result = RecordingLoadResult(
            envelope: phase1Envelope,
            failedSessionIDs: [],
            schemaNotice: nil,
            phase2Source: RecordingPhase2Source(legacyEnvelopeData: rawData)
        )
        let mock = MockSessionRecordingImportService(result: .success(result))
        let coordinator = RecordingLoadCoordinator(importService: mock, sessionStore: sessionStore)

        await coordinator.load(from: tempURL, mode: .replace)

        // Phase 1: session visible but bodyless, marked deferred.
        XCTAssertEqual(sessionStore.sessions.count, 1)
        XCTAssertNil(sessionStore.sessions[0].request.bodyData)
        XCTAssertTrue(sessionStore.sessions[0].request.bodyDeferred,
                      "Phase-1 session should have bodyDeferred=true")

        // Phase 2 runs asynchronously; wait for the coordinator to finish applying it.
        await coordinator.waitForPhase2BodyLoadForTesting()

        XCTAssertEqual(sessionStore.sessions[0].request.bodyData, body,
                       "Phase-2 should fill in the body from its bounded source")
        XCTAssertFalse(sessionStore.sessions[0].request.bodyDeferred,
                       "Phase-2 should clear bodyDeferred after filling the body")
    }

    func testPhase2PublishesBatchedBodyUpdates() async throws {
        let body = Data(repeating: 0xBC, count: 64)
        let sessions = (0..<12).map { index in
            makeSession(path: "/batch-\(index)", responseBody: body)
        }
        let rawData = try encodeEnvelope(makeEnvelope(sessions: sessions))
        let phase1Envelope = try strippingBodies(from: rawData)
        let result = RecordingLoadResult(
            envelope: phase1Envelope,
            failedSessionIDs: [],
            schemaNotice: nil,
            phase2Source: RecordingPhase2Source(legacyEnvelopeData: rawData)
        )
        let mock = MockSessionRecordingImportService(result: .success(result))
        let coordinator = RecordingLoadCoordinator(importService: mock, sessionStore: sessionStore)
        var changes: [SessionStoreChange] = []

        sessionStore.sessionChangesPublisher
            .sink { changes.append($0) }
            .store(in: &cancellables)

        await coordinator.load(from: tempURL, mode: .replace)
        await coordinator.waitForPhase2BodyLoadForTesting()

        XCTAssertEqual(changes.first, .loaded(sessions: phase1Envelope.sessions, reason: "capture_loaded"))
        XCTAssertEqual(Array(changes.dropFirst()), [.updatedBatch(sessions, insertedIDs: [])])
        XCTAssertEqual(sessionStore.sessions.compactMap { $0.response?.bodyData?.count }, Array(repeating: body.count, count: sessions.count))
    }

    // MARK: Round-trip fidelity

    func testRoundTripPreservesSessionFields() async throws {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let completedAt = startedAt.addingTimeInterval(1.5)
        let session = SessionRecord(
            request: CapturedRequest(
                method: "POST",
                scheme: .https,
                inspectionKind: .interceptedTLS,
                host: "api.example.com",
                port: 443,
                path: "/v1/data",
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                bodyData: Data("{\"key\":\"value\"}".utf8),
                bodySize: 15
            ),
            response: CapturedResponse(
                statusCode: 201,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                bodyData: Data("{\"id\":1}".utf8),
                bodySize: 8
            ),
            state: .completed,
            timing: SessionTiming(startedAt: startedAt, completedAt: completedAt)
        )

        try writeEnvelope(makeEnvelope(sessions: [session]), to: tempURL)

        let coordinator = makeCoordinator()
        await coordinator.load(from: tempURL, mode: .replace)

        let loaded = sessionStore.sessions[0]
        XCTAssertEqual(loaded.id, session.id)
        XCTAssertEqual(loaded.request.method, "POST")
        XCTAssertEqual(loaded.request.scheme, .https)
        XCTAssertEqual(loaded.request.inspectionKind, .interceptedTLS)
        XCTAssertEqual(loaded.request.host, "api.example.com")
        XCTAssertEqual(loaded.response?.statusCode, 201)
        XCTAssertEqual(loaded.state, .completed)
        XCTAssertEqual(
            loaded.timing.startedAt.timeIntervalSinceReferenceDate,
            session.timing.startedAt.timeIntervalSinceReferenceDate,
            accuracy: 0.001
        )
    }

    func testRepresentativeRecordingReopensAcrossAllFidelityModes() async throws {
        for fidelity in RecordingSaveFidelity.allCases {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("jproxy")
            defer { try? FileManager.default.removeItem(at: url) }

            let envelope = makeRepresentativeRecordingEnvelope()
            try exportService.exportAsRecording(envelope, to: url, fidelity: fidelity)

            sessionStore.load(sessions: [])
            let coordinator = makeCoordinator()
            await coordinator.load(from: url, mode: .replace)
            await coordinator.waitForPhase2BodyLoadForTesting()

            XCTAssertEqual(coordinator.loadState, .idle, "Expected idle load state for \(fidelity.title)")
            XCTAssertEqual(sessionStore.sessions.count, envelope.sessions.count, "Expected all sessions to reopen for \(fidelity.title)")

            let playlist = try XCTUnwrap(sessionStore.sessions.first { $0.request.path == "/playlist/master.m3u8" })
            let initSegment = try XCTUnwrap(sessionStore.sessions.first { $0.request.path == "/video/init-main.m4s" })
            let segment = try XCTUnwrap(sessionStore.sessions.first { $0.request.path == "/video/segment-001.m4s" })
            let image = try XCTUnwrap(sessionStore.sessions.first { $0.request.path == "/assets/poster.jpg" })

            switch fidelity {
            case .fullRecording:
                XCTAssertNotNil(playlist.response?.bodyData)
                XCTAssertNotNil(initSegment.response?.bodyData)
                XCTAssertNotNil(segment.response?.bodyData)
                XCTAssertNotNil(image.response?.bodyData)
            case .metadataOnly:
                XCTAssertNil(playlist.response?.bodyData)
                XCTAssertEqual(playlist.response?.recordingBodyOmissionReason, .metadataOnly)
                XCTAssertNil(initSegment.response?.bodyData)
                XCTAssertEqual(initSegment.response?.recordingBodyOmissionReason, .metadataOnly)
                XCTAssertNil(segment.response?.bodyData)
                XCTAssertEqual(segment.response?.recordingBodyOmissionReason, .metadataOnly)
                XCTAssertNil(image.response?.bodyData)
                XCTAssertEqual(image.response?.recordingBodyOmissionReason, .metadataOnly)
            case .textBodiesOnly:
                XCTAssertNotNil(playlist.response?.bodyData)
                XCTAssertNil(initSegment.response?.bodyData)
                XCTAssertEqual(initSegment.response?.recordingBodyOmissionReason, .binaryExcludedFromTextMode)
                XCTAssertNil(segment.response?.bodyData)
                XCTAssertEqual(segment.response?.recordingBodyOmissionReason, .binaryExcludedFromTextMode)
                XCTAssertNil(image.response?.bodyData)
                XCTAssertEqual(image.response?.recordingBodyOmissionReason, .binaryExcludedFromTextMode)
            case .mediaFocused:
                XCTAssertNotNil(playlist.response?.bodyData)
                XCTAssertNotNil(initSegment.response?.bodyData)
                XCTAssertNil(segment.response?.bodyData)
                XCTAssertEqual(segment.response?.recordingBodyOmissionReason, .oversizedMediaExcluded)
                XCTAssertNil(image.response?.bodyData)
                XCTAssertEqual(image.response?.recordingBodyOmissionReason, .nonMediaBinaryExcluded)
            }
        }
    }

    func testLargeMixedRecordingReopensAcrossAllFidelityModes() async throws {
        let envelope = makeLargeMixedRecordingEnvelope()

        for fidelity in RecordingSaveFidelity.allCases {
            try? FileManager.default.removeItem(at: tempURL)
            try exportService.exportAsRecording(envelope, to: tempURL, fidelity: fidelity)

            sessionStore.load(sessions: [])
            let coordinator = makeCoordinator()
            await coordinator.load(from: tempURL, mode: .replace)
            await coordinator.waitForPhase2BodyLoadForTesting()

            XCTAssertEqual(coordinator.loadState, .idle, "Expected idle load state for \(fidelity.title)")
            XCTAssertEqual(sessionStore.sessions.count, envelope.sessions.count, "Expected all sessions to reopen for \(fidelity.title)")
            XCTAssertFalse(
                sessionStore.sessions.contains { $0.request.bodyDeferred || ($0.response?.bodyDeferred == true) },
                "Phase-2 body loading should settle for \(fidelity.title)"
            )

            let textSession = try XCTUnwrap(sessionStore.sessions.first { $0.request.path == "/events/0" })
            let mediaSegment = try XCTUnwrap(sessionStore.sessions.first { $0.request.path == "/video/segment-000.m4s" })

            switch fidelity {
            case .fullRecording:
                XCTAssertNotNil(textSession.response?.bodyData)
                XCTAssertNotNil(mediaSegment.response?.bodyData)
            case .metadataOnly:
                XCTAssertNil(textSession.response?.bodyData)
                XCTAssertEqual(textSession.response?.recordingBodyOmissionReason, .metadataOnly)
                XCTAssertNil(mediaSegment.response?.bodyData)
                XCTAssertEqual(mediaSegment.response?.recordingBodyOmissionReason, .metadataOnly)
            case .textBodiesOnly:
                XCTAssertNotNil(textSession.response?.bodyData)
                XCTAssertNil(mediaSegment.response?.bodyData)
                XCTAssertEqual(mediaSegment.response?.recordingBodyOmissionReason, .binaryExcludedFromTextMode)
            case .mediaFocused:
                XCTAssertNotNil(textSession.response?.bodyData)
                XCTAssertNil(mediaSegment.response?.bodyData)
                XCTAssertEqual(mediaSegment.response?.recordingBodyOmissionReason, .oversizedMediaExcluded)
            }
        }
    }

    func testLargeRecordingUsesDeferredPhase1AndRestoresBodiesInPhase2() async throws {
        let largeBody = Data(repeating: 0xAB, count: 800_000)
        let sessions = (0..<16).map { index in
            makeSession(
                path: "/video/segment-\(index).m4s",
                responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "video/mp4")],
                responseBody: largeBody
            )
        }
        let envelope = makeEnvelope(sessions: sessions)
        try exportService.exportAsRecording(envelope, to: tempURL, fidelity: .fullRecording)

        let coordinator = makeCoordinator()
        await coordinator.load(from: tempURL, mode: .replace)

        XCTAssertEqual(sessionStore.sessions.count, sessions.count)
        XCTAssertNil(sessionStore.sessions[0].response?.bodyData, "Phase 1 should strip bodies for large recordings")
        XCTAssertTrue(sessionStore.sessions[0].response?.bodyDeferred == true, "Phase 1 should mark bodies as deferred")

        await coordinator.waitForPhase2BodyLoadForTesting()

        XCTAssertEqual(sessionStore.sessions[0].response?.bodyData?.count, largeBody.count)
        XCTAssertFalse(sessionStore.sessions[0].response?.bodyDeferred == true, "Phase 2 should restore bodies and clear the deferred marker")
    }

    // MARK: Helpers

    private func makeCoordinator() -> RecordingLoadCoordinator {
        RecordingLoadCoordinator(
            importService: JSONSessionRecordingImportService(),
            sessionStore: sessionStore
        )
    }

    private func makeLargeMixedRecordingEnvelope() -> SessionExportEnvelope {
        let textSessions = (0..<8).map { index in
            makeSession(
                path: "/events/\(index)",
                responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                responseBody: Data("{\"index\":\(index),\"state\":\"active\"}".utf8)
            )
        }
        let mediaBody = Data(repeating: 0xCA, count: 700_000)
        let mediaSessions = (0..<18).map { index in
            makeSession(
                path: "/video/segment-\(String(format: "%03d", index)).m4s",
                responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "video/mp4")],
                responseBody: mediaBody
            )
        }

        return makeEnvelope(sessions: textSessions + mediaSessions)
    }
}

// MARK: - Mock import service

/// A test double for `SessionRecordingImportService` that returns a pre-configured result.
private final class MockSessionRecordingImportService: SessionRecordingImportService {
    private let stubbedResult: Result<RecordingLoadResult, Error>

    init(result: Result<RecordingLoadResult, Error>) {
        self.stubbedResult = result
    }

    func open(from url: URL, bestEffort: Bool) async throws -> RecordingLoadResult {
        switch stubbedResult {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }
}

// MARK: - Shared test helpers

private func makeEnvelope(sessions: [SessionRecord] = []) -> SessionExportEnvelope {
    SessionExportEnvelope(
        exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
        appVersion: "\(Bundle.main.marketingVersionOrDev)-test",
        proxyPort: 9090,
        sessionCount: sessions.count,
        sessions: sessions
    )
}

private func makeRepresentativeRecordingEnvelope() -> SessionExportEnvelope {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let sessions = [
        makeRepresentativeRecordingSession(
            method: "GET",
            host: "stream.example.com",
            path: "/playlist/master.m3u8",
            responseBody: Data("""
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1920x1080
            video/main.m3u8
            """.utf8),
            contentType: "application/vnd.apple.mpegurl",
            startedAt: now
        ),
        makeRepresentativeRecordingSession(
            method: "GET",
            host: "stream.example.com",
            path: "/video/init-main.m4s",
            responseBody: Data(repeating: 0xAA, count: 220_000),
            contentType: "video/mp4",
            startedAt: now.addingTimeInterval(1)
        ),
        makeRepresentativeRecordingSession(
            method: "GET",
            host: "cdn.example.com",
            path: "/video/segment-001.m4s",
            responseBody: Data(repeating: 0xBB, count: 420_000),
            contentType: "video/mp4",
            startedAt: now.addingTimeInterval(2)
        ),
        makeRepresentativeRecordingSession(
            method: "GET",
            host: "api.example.com",
            path: "/playback/bootstrap",
            responseBody: Data("{\"streamingUrl\":\"https://stream.example.com/playlist/master.m3u8\",\"token\":\"abc\"}".utf8),
            contentType: "application/json",
            startedAt: now.addingTimeInterval(3)
        ),
        makeRepresentativeRecordingSession(
            method: "POST",
            host: "auth.example.com",
            path: "/license",
            requestBody: Data("{\"challenge\":\"deadbeef\"}".utf8),
            responseBody: Data(repeating: 0xCC, count: 96_000),
            requestContentType: "application/json",
            contentType: "application/octet-stream",
            startedAt: now.addingTimeInterval(4)
        ),
        makeRepresentativeRecordingSession(
            method: "GET",
            host: "images.example.com",
            path: "/assets/poster.jpg",
            responseBody: Data(repeating: 0xDD, count: 180_000),
            contentType: "image/jpeg",
            startedAt: now.addingTimeInterval(5)
        )
    ]

    return SessionExportEnvelope(
        exportedAt: now.addingTimeInterval(10),
        appVersion: "\(Bundle.main.marketingVersionOrDev)-test",
        proxyPort: 9090,
        sessionCount: sessions.count,
        sessions: sessions
    )
}

private func makeSession(
    path: String = "/",
    requestHeaders: [HTTPHeaderField] = [],
    responseHeaders: [HTTPHeaderField] = [],
    requestBody: Data? = nil,
    responseBody: Data? = nil
) -> SessionRecord {
    SessionRecord(
        request: CapturedRequest(
            method: "GET",
            scheme: .http,
            host: "test.example.com",
            port: 80,
            path: path,
            headers: requestHeaders,
            bodyData: requestBody,
            bodySize: requestBody.map(\.count)
        ),
        response: responseBody != nil ? CapturedResponse(
            statusCode: 200,
            headers: responseHeaders,
            bodyData: responseBody,
            bodySize: responseBody.map(\.count)
        ) : nil,
        state: .completed,
        timing: SessionTiming(startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    )
}

private func makeRepresentativeRecordingSession(
    method: String,
    host: String,
    path: String,
    requestBody: Data? = nil,
    responseBody: Data?,
    requestContentType: String? = nil,
    contentType: String,
    startedAt: Date
) -> SessionRecord {
    var requestHeaders = [HTTPHeaderField(name: "Host", value: host)]
    if let requestContentType {
        requestHeaders.append(HTTPHeaderField(name: "Content-Type", value: requestContentType))
    }

    return SessionRecord(
        request: CapturedRequest(
            method: method,
            scheme: .https,
            inspectionKind: .interceptedTLS,
            host: host,
            port: 443,
            path: path,
            headers: requestHeaders,
            bodyData: requestBody,
            bodySize: requestBody?.count
        ),
        response: CapturedResponse(
            statusCode: 200,
            headers: [HTTPHeaderField(name: "Content-Type", value: contentType)],
            bodyData: responseBody,
            bodySize: responseBody?.count
        ),
        state: .completed,
        timing: SessionTiming(
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(0.15)
        )
    )
}

private func makeCapturedRequest(bodyTruncated: Bool, bodyDeferred: Bool = false) -> CapturedRequest {
    CapturedRequest(
        method: "GET",
        scheme: .http,
        host: "example.com",
        port: 80,
        path: "/",
        headers: [],
        bodyData: nil,
        bodySize: nil,
        bodyTruncated: bodyTruncated,
        recordingBodyOmissionReason: nil,
        bodyDeferred: bodyDeferred
    )
}

private func encodeEnvelope(_ envelope: SessionExportEnvelope) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(envelope)
}

private func roundTrip(from url: URL) throws -> SessionExportEnvelope {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    // Recordings are written in the JPXR container; legacy plain JSON passes through.
    let data = try RecordingContainer.unwrap(Data(contentsOf: url))
    return try decoder.decode(SessionExportEnvelope.self, from: data)
}

private func writeEnvelope(_ envelope: SessionExportEnvelope, to url: URL) throws {
    try encodeEnvelope(envelope).write(to: url)
}

/// Writes an envelope JSON with a schema version one higher than `currentSchemaVersion`.
private func writeFutureSchemaFile(to url: URL, sessions: [SessionRecord]) throws {
    let futureVersion = RecordingConstants.currentSchemaVersion + 1
    let envelope = makeEnvelope(sessions: sessions)
    var root = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: encodeEnvelope(envelope)) as? [String: Any]
    )
    root["schemaVersion"] = futureVersion
    let data = try JSONSerialization.data(withJSONObject: root)
    try data.write(to: url)
}

/// Returns an envelope decoded from `data` with all `bodyData` fields stripped from sessions
/// and `bodyDeferred` set to `true`, mirroring `SessionRecordingImportService.strippingBodyData`.
/// Used to simulate a phase-1 (body-deferred) load result in tests.
private func strippingBodies(from data: Data) throws -> SessionExportEnvelope {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let sessions = try XCTUnwrap(root["sessions"] as? [[String: Any]])
    root["sessions"] = sessions.map { sessionDict -> [String: Any] in
        var s = sessionDict
        if var req = s["request"] as? [String: Any] {
            req.removeValue(forKey: "bodyData")
            req["bodyDeferred"] = true
            s["request"] = req
        }
        if var resp = s["response"] as? [String: Any] {
            resp.removeValue(forKey: "bodyData")
            resp["bodyDeferred"] = true
            s["response"] = resp
        }
        return s
    }
    let stripped = try JSONSerialization.data(withJSONObject: root)
    return try decoder.decode(SessionExportEnvelope.self, from: stripped)
}

// MARK: - Encode helper on SessionExportEnvelope (test-only)

private extension SessionExportEnvelope {
    func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
