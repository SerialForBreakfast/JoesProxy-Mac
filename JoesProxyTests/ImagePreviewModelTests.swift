import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import JoesProxy

@MainActor
final class ImagePreviewModelTests: XCTestCase {
    func testCommonPNGPathPreservesPixelsMetadataAndVisualAnalysis() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 24, height: 12, bitsPerComponent: 8,
            bytesPerRow: 96, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 12))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let data = output as Data
        let analysis = await ImagePreviewModel.analyzeImage(data)
        let decoded = try XCTUnwrap(analysis?.image)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let reference = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.dataProvider?.data as Data?, reference.dataProvider?.data as Data?)
        XCTAssertEqual(decoded.width, 24)
        XCTAssertEqual(decoded.height, 12)
        XCTAssertNil(analysis?.fallbackData)
        XCTAssertEqual(analysis?.metadata.pixelWidth, 24)
        XCTAssertEqual(analysis?.metadata.pixelHeight, 12)
        XCTAssertEqual(analysis?.metadata.preferredMIMEType, "image/png")
        XCTAssertEqual(analysis?.visualReport, VisualWireInspectorEngine.analyze(imageData: data))
    }

    func testUnchangedIdentityDoesNotRepeatWorkAndRevisionRefreshes() async throws {
        let model = ImagePreviewModel(analyze: { data in ImagePreviewGate.result(data) })
        let id = UUID()
        let key = ImagePreviewKey(sessionID: id, revision: 1, contentType: "image/png")
        model.request(key: key, data: Data([1]))
        try await settle(model)
        for _ in 0..<100 { model.request(key: key, data: Data([1])) }
        XCTAssertEqual(model.attemptCount, 1)
        model.request(key: ImagePreviewKey(sessionID: id, revision: 2, contentType: "image/png"), data: Data([2]))
        try await settle(model)
        XCTAssertEqual(model.attemptCount, 2)
        XCTAssertEqual(model.visualReport?.pixelWidth, 2)
    }

    func testRapidRevisionsKeepOneWorkerAndOnlyLatestPendingImage() async throws {
        let gate = ImagePreviewGate()
        defer { Task { await gate.releaseAll() } }
        let model = ImagePreviewModel(analyze: { data in await gate.run(data) })
        let id = UUID()
        model.request(key: ImagePreviewKey(sessionID: id, revision: 0, contentType: nil), data: Data([0]))
        try await waitUntil { model.attemptCount == 1 }
        for revision in 1...50 {
            model.request(key: ImagePreviewKey(sessionID: id, revision: UInt64(revision), contentType: nil), data: Data([UInt8(revision)]))
        }
        XCTAssertEqual(model.attemptCount, 1)
        await gate.releaseNext()
        try await waitUntil { model.attemptCount == 2 }
        XCTAssertNil(model.visualReport)
        await gate.releaseNext()
        try await settle(model)
        XCTAssertEqual(model.visualReport?.pixelWidth, 50)
        let peak = await gate.peak
        XCTAssertEqual(peak, 1)
    }

    func testDisappearDropsResultsAndReappearWaitsForDrain() async throws {
        let gate = ImagePreviewGate()
        defer { Task { await gate.releaseAll() } }
        let model = ImagePreviewModel(analyze: { data in await gate.run(data) })
        let key = ImagePreviewKey(sessionID: UUID(), revision: 1, contentType: nil)
        model.request(key: key, data: Data([1]))
        try await waitUntil { model.attemptCount == 1 }
        model.cancelAndClear()
        model.request(key: key, data: Data([2]))
        XCTAssertEqual(model.attemptCount, 1)
        await gate.releaseNext()
        try await waitUntil { model.attemptCount == 2 }
        XCTAssertNil(model.visualReport)
        await gate.releaseNext()
        try await settle(model)
        XCTAssertEqual(model.visualReport?.pixelWidth, 2)
        model.cancelAndClear()
        XCTAssertNil(model.image)
        XCTAssertNil(model.metadata)
        XCTAssertNil(model.visualReport)
        XCTAssertFalse(model.isLoading)
    }

    func testCompletedWorkerReleasesModel() async throws {
        var model: ImagePreviewModel? = ImagePreviewModel(analyze: { data in ImagePreviewGate.result(data) })
        weak var releasedModel = model
        model?.request(key: ImagePreviewKey(sessionID: UUID(), revision: 1, contentType: nil), data: Data([1]))
        try await waitUntil { model?.isWorking == false }
        model = nil
        try await waitUntil { releasedModel == nil }
    }

    private func settle(_ model: ImagePreviewModel) async throws {
        try await waitUntil { !model.isWorking }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Image preview did not settle")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private actor ImagePreviewGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var permits = 0
    private var released = false
    private var active = 0
    private(set) var peak = 0

    func run(_ data: Data) async -> ImagePreviewAnalysis? {
        active += 1
        peak = max(peak, active)
        if permits > 0 { permits -= 1 }
        else if !released { await withCheckedContinuation { waiters.append($0) } }
        active -= 1
        return Self.result(data)
    }

    nonisolated static func result(_ data: Data) -> ImagePreviewAnalysis {
        ImagePreviewAnalysis(image: nil, fallbackData: nil,
            metadata: ImageMetadataService().loadMetadata(from: Data()),
            visualReport: VisualAssetReport(pixelWidth: Int(data.first ?? 0), pixelHeight: 1,
                aspectRatio: 1, bytesPerPixel: 1, dominantPalette: [], hasTransparency: false,
                isFullyTransparent: false, anomalies: []))
    }

    func releaseNext() {
        if waiters.isEmpty { permits += 1 } else { waiters.removeFirst().resume() }
    }

    func releaseAll() {
        released = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}
