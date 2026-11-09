import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import JoesProxy

final class ImageInspectionPreflightTests: XCTestCase {
    private func imageData(type: UTType = .png, frames: Int = 1, orientation: Int = 1, width: Int = 24, height: Int = 12) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage()), data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, frames, nil))
        for _ in 0..<frames {
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Valid compressed pixels isolate our pixel gate from ImageIO's malformed-file rejection.
    private func oversizedHeader() throws -> Data {
        try autoreleasepool { try imageData(width: 4097, height: 4096) }
    }

    func testHeaderBudgetRejectsBeforeDecodeAcrossCallers() async throws {
        let data = try oversizedHeader()
        let result = ImageInspectionPreflight.inspect(data)
        XCTAssertNil(result.source)
        XCTAssertEqual(result.reason, "pixel_limit")
        let report = VisualWireInspectorEngine.analyze(imageData: data)
        XCTAssertEqual(report.inspectedFrameCount, 0)
        XCTAssertTrue(report.anomalies.contains(.inspectionUnavailable(reason: "pixel_limit")))
        XCTAssertNil(ImageBodyDecoder.makeImage(from: data))
        let preview = await ImagePreviewModel.analyzeImage(data)
        XCTAssertNil(preview?.image)
        XCTAssertNil(preview?.fallbackData)
        XCTAssertEqual(preview?.visualReport.inspectedFrameCount, 0)
        print("IMAGE_PREFLIGHT_METRIC fixture=oversized-png-v1 encodedBytes=\(data.count) declaredPixels=16781312 decodedFrames=0 avoidedDeclaredRGBABytes=67125248")
    }

    func testEncodedMalformedFrameAndOverflowBounds() throws {
        XCTAssertEqual(ImageInspectionPreflight.inspect(Data(repeating: 0, count: ImageInspectionPreflight.maximumEncodedBytes + 1)).reason, "encoded_byte_limit")
        XCTAssertEqual(ImageInspectionPreflight.inspect(Data("invalid".utf8)).reason, "malformed_metadata")
        XCTAssertEqual(ImageInspectionPreflight.rejection(width: Int64.max, height: Int64.max, frames: 1), "pixel_limit")
        XCTAssertEqual(ImageInspectionPreflight.rejection(width: 24, height: 12, frames: 257), "frame_limit")
        XCTAssertEqual(ImageInspectionPreflight.rejection(width: 24, height: 12, frames: 0), "frame_limit")
        XCTAssertNil(ImageInspectionPreflight.rejection(width: 4096, height: 4096, frames: 256))
    }

    func testOrientationAndFirstFrameCoverageAreExplicit() throws {
        let rotated = try imageData(type: .tiff, orientation: 6)
        let preflight = ImageInspectionPreflight.inspect(rotated)
        XCTAssertNil(preflight.reason)
        XCTAssertEqual(preflight.orientation, 6)
        let report = VisualWireInspectorEngine.analyze(imageData: rotated)
        XCTAssertEqual(report.orientation, 6)
        XCTAssertEqual(report.pixelWidth, 24, "Dimensions describe stored pixels, not an orientation-normalized rendering")
        XCTAssertEqual(report.pixelHeight, 12)
        let animation = VisualWireInspectorEngine.analyze(imageData: try imageData(type: .gif, frames: 2))
        XCTAssertEqual(animation.inspectedFrameCount, 1)
        XCTAssertEqual(animation.totalFrameCount, 2)
        let manyFrames = ImageInspectionPreflight.inspect(try imageData(type: .gif, frames: 257))
        XCTAssertEqual(manyFrames.reason, "frame_limit")
        XCTAssertNil(manyFrames.source)
    }

    func testCancelledAnalysisDoesNotDecode() async throws {
        let data = try imageData()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return VisualWireInspectorEngine.analyze(imageData: data)
        }
        let report = await task.value
        XCTAssertEqual(report.inspectedFrameCount, 0)
        XCTAssertTrue(report.anomalies.contains(.inspectionUnavailable(reason: "cancelled")))
    }

    func testRejectedHeaderMemoryAndLatencyTrend() throws {
        let data = try oversizedHeader()
        measure(metrics: [XCTMemoryMetric(), XCTClockMetric()]) {
            for _ in 0..<100 {
                XCTAssertEqual(VisualWireInspectorEngine.analyze(imageData: data).inspectedFrameCount, 0)
            }
        }
    }
}
