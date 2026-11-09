//
//  VisualWireInspectorEngineTests.swift
//  JoesProxyTests
//
//  Unit tests for Visual Wire Inspector color quantization and visual anomaly detection.
//

import XCTest
import AppKit
@testable import JoesProxy

final class VisualWireInspectorEngineTests: XCTestCase {

    func testSolidColorImagePaletteAndMonochromeDetection() {
        // 1. Create a 32x32 solid red bitmap image
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 32,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 32 * 4,
            bitsPerPixel: 32
        )!

        // Fill with red (255, 0, 0, 255)
        for x in 0..<32 {
            for y in 0..<32 {
                rep.setColor(NSColor(calibratedRed: 1.0, green: 0.0, blue: 0.0, alpha: 1.0), atX: x, y: y)
            }
        }

        let pngData = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])!
        let report = VisualWireInspectorEngine.analyze(imageData: pngData)

        XCTAssertEqual(report.pixelWidth, 32)
        XCTAssertEqual(report.pixelHeight, 32)
        XCTAssertEqual(report.aspectRatioString, "1:1")
        XCTAssertFalse(report.dominantPalette.isEmpty)
        XCTAssertEqual(report.dominantPalette.first?.hex, "#FF0000")
        XCTAssertFalse(report.isFullyTransparent)
        XCTAssertTrue(report.anomalies.contains(where: {
            if case .monochromeEmpty = $0 { return true }
            return false
        }))
    }

    func testFullyTransparentImageAnomalyDetection() {
        // 2. Create a 16x16 100% transparent pixel image
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 16,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 16 * 4,
            bitsPerPixel: 32
        )!

        // Fill with transparent (0, 0, 0, 0)
        for x in 0..<16 {
            for y in 0..<16 {
                rep.setColor(NSColor(calibratedRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.0), atX: x, y: y)
            }
        }

        let pngData = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])!
        let report = VisualWireInspectorEngine.analyze(imageData: pngData)

        XCTAssertEqual(report.pixelWidth, 16)
        XCTAssertEqual(report.pixelHeight, 16)
        XCTAssertTrue(report.hasTransparency)
        XCTAssertTrue(report.isFullyTransparent)
        XCTAssertTrue(report.anomalies.contains(.blankTransparent))
    }

    func testMalformedImageDataFailsGracefully() {
        let junkData = "Not an image file".data(using: .utf8)!
        let report = VisualWireInspectorEngine.analyze(imageData: junkData)

        XCTAssertEqual(report.pixelWidth, 0)
        XCTAssertEqual(report.pixelHeight, 0)
        XCTAssertTrue(report.anomalies.contains(.malformedPixelData))
    }
}
