import CoreVideo
import XCTest
@testable import JoesProxy

final class AVMediaInspectionEligibilityTests: XCTestCase {
    func testCompleteCapturedVideoOffersCapturedAndLiveInspection() {
        let session = makeSession(path: "/video/segment.ts", body: Data(repeating: 0x47, count: 1_024))

        let eligibility = AVMediaInspectionEligibility.evaluate(session: session)

        XCTAssertTrue(eligibility.capturedItemAvailable)
        XCTAssertTrue(eligibility.liveURLAvailable)
        XCTAssertEqual(eligibility.availableSources, [.capturedItem, .liveURL])
    }

    func testCapturedManifestIsNotOfferedAsSelfContainedMedia() {
        let manifest = Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000\nvideo.m3u8".utf8)
        let session = makeSession(
            path: "/master.m3u8",
            body: manifest,
            contentType: "application/vnd.apple.mpegurl"
        )

        let eligibility = AVMediaInspectionEligibility.evaluate(session: session)

        XCTAssertFalse(eligibility.capturedItemAvailable)
        XCTAssertTrue(eligibility.liveURLAvailable)
        XCTAssertTrue(eligibility.capturedItemReason?.contains("manifest parser") == true)
    }

    func testTruncatedCapturedVideoIsRejected() {
        let session = makeSession(
            path: "/video/segment.ts",
            body: Data(repeating: 0x47, count: 188),
            bodyTruncated: true
        )

        let eligibility = AVMediaInspectionEligibility.evaluate(session: session)

        XCTAssertFalse(eligibility.capturedItemAvailable)
        XCTAssertTrue(eligibility.capturedItemReason?.contains("truncated") == true)
    }

    func testDeferredAndOmittedCapturedBodiesHaveSpecificReasons() {
        let deferred = makeSession(
            path: "/video/segment.ts",
            body: nil,
            bodyDeferred: true
        )
        let omitted = makeSession(
            path: "/video/segment.ts",
            body: nil,
            omissionReason: .metadataOnly
        )

        XCTAssertTrue(AVMediaInspectionEligibility.evaluate(session: deferred).capturedItemReason?.contains("still loading") == true)
        XCTAssertTrue(AVMediaInspectionEligibility.evaluate(session: omitted).capturedItemReason?.contains("does not contain") == true)
    }

    func testSensitiveRequestDataIsDetectedWithoutExposingValue() {
        let session = makeSession(
            path: "/video/segment.ts?token=private-value",
            body: Data(repeating: 0x47, count: 188),
            requestHeaders: [HTTPHeaderField(name: "Authorization", value: "Bearer private-value")]
        )

        XCTAssertTrue(AVMediaInspectionEligibility.evaluate(session: session).containsSensitiveRequestData)
    }

    private func makeSession(
        path: String,
        body: Data?,
        contentType: String = "video/mp2t",
        bodyTruncated: Bool = false,
        bodyDeferred: Bool = false,
        omissionReason: RecordingBodyOmissionReason? = nil,
        requestHeaders: [HTTPHeaderField] = []
    ) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                inspectionKind: .interceptedTLS,
                host: "media.example.com",
                port: 443,
                path: path,
                headers: requestHeaders,
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: contentType)],
                bodyData: body,
                bodySize: body?.count,
                bodyTruncated: bodyTruncated,
                recordingBodyOmissionReason: omissionReason,
                bodyDeferred: bodyDeferred
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )
    }
}

final class AVPixelBufferInspectorTests: XCTestCase {
    func testInspectsNonPlanarPixelBufferWithoutIOSurface() throws {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            8,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)

        let result = AVPixelBufferInspector.inspect(buffer, requestedTime: 1, decodedTime: 1.02)

        XCTAssertEqual(result.width, 16)
        XCTAssertEqual(result.height, 8)
        XCTAssertEqual(result.pixelFormat, "BGRA")
        XCTAssertFalse(result.isPlanar)
        XCTAssertEqual(result.planeCount, 0)
        XCTAssertFalse(result.hasIOSurface)
        XCTAssertEqual(result.decodedTime, 1.02, accuracy: 0.001)
    }

    func testInspectsIOSurfaceBackedPixelBuffer() throws {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            32,
            18,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)

        let result = AVPixelBufferInspector.inspect(buffer, requestedTime: 0, decodedTime: 0)

        XCTAssertTrue(result.hasIOSurface)
        XCTAssertEqual(result.ioSurfaceWidth, 32)
        XCTAssertEqual(result.ioSurfaceHeight, 18)
        XCTAssertNotNil(result.ioSurfaceAllocationSize)
    }
}

@MainActor
final class AVAssetMetadataServiceIntegrationTests: XCTestCase {
    private var scratchDirectory: URL!

    override func setUpWithError() throws {
        scratchDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/AVMediaInspectionTests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratchDirectory.path), [],
                       "Inspection must await temporary-media cleanup before returning")
        try FileManager.default.removeItem(at: scratchDirectory)
    }

    func testCapturedResponsePreparationProducesDecodedFrame() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/media_inspection_one_frame.mp4"))
        let input = AVMediaInspectionInput(
            source: .capturedItem, url: nil, capturedData: nil,
            capturedFileExtension: "mp4", displayName: "Synthetic captured response",
            sampleTime: 0.5, initialWarnings: [],
            capturedResponse: CapturedResponse(statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "video/mp4")],
                bodyData: data, bodySize: data.count)
        )
        let report = await AVAssetMetadataService(metadataTimeout: 5, playerTimeout: 5,
            temporaryDirectory: scratchDirectory).inspect(input)
        XCTAssertEqual(report.decodedFrame?.width, 64)
        XCTAssertEqual(report.decodedFrame?.height, 36)
        XCTAssertEqual(report.stages.map(\.outcome), [.completed, .completed, .completed])
    }

    func testPreparationSaturationReturnsRetryableReportWithoutStartingAsset() async {
        let budget = MediaInspectionWorkBudget()
        let entered = expectation(description: "Both preparation slots occupied")
        entered.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        let first = Task { await budget.run { entered.fulfill(); release.wait(); return 1 } }
        let second = Task { await budget.run { entered.fulfill(); release.wait(); return 2 } }
        await fulfillment(of: [entered], timeout: 5)
        let report = await AVAssetMetadataService(preparationBudget: budget,
            temporaryDirectory: scratchDirectory).inspect(emptyCapturedInput())
        release.signal()
        release.signal()
        _ = await first.value
        _ = await second.value
        XCTAssertNil(report.asset)
        XCTAssertNil(report.player)
        XCTAssertEqual(report.stages.map(\.outcome), [.failed])
        XCTAssertTrue(report.warnings.contains { $0.contains("Media preparation is busy") })
        let resumed = await budget.run { true }
        XCTAssertEqual(resumed, true)
    }

    func testCancelledInspectionDoesNotBeginPreparation() async {
        let input = emptyCapturedInput()
        let service = AVAssetMetadataService(temporaryDirectory: scratchDirectory)
        let inspection = Task { await service.inspect(input) }
        inspection.cancel()
        let report = await inspection.value
        XCTAssertEqual(report.stages.map(\.outcome), [.cancelled])
        XCTAssertNil(report.asset)
        XCTAssertTrue(report.warnings.isEmpty)
    }

    func testInvalidCapturedMediaCleansPreparedFileAfterFailure() async {
        let input = AVMediaInspectionInput(source: .capturedItem, url: nil,
            capturedData: Data("not a media file".utf8), capturedFileExtension: "mp4",
            displayName: "Malformed synthetic media", sampleTime: 0, initialWarnings: [])
        let report = await AVAssetMetadataService(metadataTimeout: 1, playerTimeout: 1,
            temporaryDirectory: scratchDirectory).inspect(input)
        XCTAssertTrue(report.isPartial)
        XCTAssertNil(report.decodedFrame)
        XCTAssertTrue(report.stages.contains { $0.outcome != .completed })
    }

    func testUnavailableResponseDoesNotFallBackToDifferentCapturedBytes() async {
        let input = AVMediaInspectionInput(source: .capturedItem, url: nil,
            capturedData: Data("different bytes".utf8), capturedFileExtension: "mp4",
            displayName: "Unavailable synthetic response", sampleTime: 0, initialWarnings: [],
            capturedResponse: CapturedResponse(statusCode: 200, headers: [], bodyData: nil, bodySize: nil))
        let report = await AVAssetMetadataService(temporaryDirectory: scratchDirectory).inspect(input)
        XCTAssertNil(report.asset)
        XCTAssertEqual(report.stages.map(\.id), ["inspection"])
        XCTAssertTrue(report.warnings.contains { $0.contains("input is unavailable") })
    }

    func testRepeatedCapturedDecodeAndMalformedInputLeaveNoTemporaryFiles() async throws {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/media_inspection_one_frame.mp4"))
        let service = AVAssetMetadataService(metadataTimeout: 2, playerTimeout: 2,
            temporaryDirectory: scratchDirectory)
        for cycle in 0..<6 {
            let valid = cycle.isMultiple(of: 2)
            let input = AVMediaInspectionInput(source: .capturedItem, url: nil,
                capturedData: valid ? bytes : Data("invalid media".utf8), capturedFileExtension: "mp4",
                displayName: "Synthetic cycle \(cycle)", sampleTime: 0.5, initialWarnings: [])
            let report = await service.inspect(input)
            if valid { XCTAssertEqual(report.decodedFrame?.width, 64) }
            else { XCTAssertTrue(report.isPartial); XCTAssertNil(report.decodedFrame) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratchDirectory.path), [],
                "Temporary files must retire after every cycle, not just test teardown")
        }
    }

    private func emptyCapturedInput() -> AVMediaInspectionInput {
        AVMediaInspectionInput(source: .capturedItem, url: nil, capturedData: nil,
            capturedFileExtension: "mp4", displayName: "Synthetic preparation",
            sampleTime: 0, initialWarnings: [])
    }

    func testInspectsOneFrameFromCapturedMediaFile() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("media_inspection_one_frame.mp4")
        let data = try Data(contentsOf: fixtureURL)
        let input = AVMediaInspectionInput(
            source: .capturedItem,
            url: nil,
            capturedData: data,
            capturedFileExtension: "mp4",
            displayName: "media_inspection_one_frame.mp4",
            sampleTime: 0.5,
            initialWarnings: []
        )

        let report = await AVAssetMetadataService(metadataTimeout: 5, playerTimeout: 5,
            temporaryDirectory: scratchDirectory).inspect(input)

        XCTAssertEqual(report.source, .capturedItem)
        XCTAssertEqual(report.asset?.isPlayable, true)
        XCTAssertEqual(report.videoTracks.first?.width, 64)
        XCTAssertEqual(report.videoTracks.first?.height, 36)
        XCTAssertEqual(report.decodedFrame?.width, 64)
        XCTAssertEqual(report.decodedFrame?.height, 36)
        XCTAssertEqual(report.stages.map(\.outcome), [.completed, .completed, .completed])
    }
}
