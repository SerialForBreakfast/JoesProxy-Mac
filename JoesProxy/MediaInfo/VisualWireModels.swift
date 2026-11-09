//
//  VisualWireModels.swift
//  JoesProxy
//
//  Domain models for Visual Wire Inspection (palette extraction, quality scores, anomalies).
//

import Foundation

/// A dominant color swatch extracted from an image payload.
struct ColorSwatch: Identifiable, Codable, Equatable, Sendable {
    var id: String { hex }
    let hex: String
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
    let weight: Double // Percentage (0.0 to 1.0) of image pixels matching this color
}

/// Anomaly detected during visual inspection of wire image payloads.
enum VisualAssetAnomaly: Codable, Equatable, Sendable {
    case blankTransparent
    case monochromeEmpty(hex: String)
    case aspectRatioMismatch(expectedDescription: String, actualRatio: Double)
    case excessiveBPP(bpp: Double)
    case malformedPixelData
    case inspectionUnavailable(reason: String)

    var userFacingMessage: String {
        switch self {
        case .blankTransparent:
            return "Sampled pixels appear fully transparent."
        case .monochromeEmpty(let hex):
            return "Sampled pixels appear to be a single color (\(hex)); fine detail may be missed."
        case .aspectRatioMismatch(let expected, let actual):
            return "Aspect ratio mismatch: expected \(expected), actual ratio is \(String(format: "%.2f", actual))."
        case .excessiveBPP(let bpp):
            return "Uncompressed bloat: \(String(format: "%.1f", bpp)) bytes per pixel."
        case .malformedPixelData:
            return "Pixel data could not be decoded."
        case .inspectionUnavailable(let reason):
            return "Image inspection unavailable: \(reason)."
        }
    }
}

/// Complete report produced by the Visual Wire Inspector.
struct VisualAssetReport: Codable, Equatable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let aspectRatio: Double
    let bytesPerPixel: Double
    let dominantPalette: [ColorSwatch]
    let hasTransparency: Bool
    let isFullyTransparent: Bool
    let anomalies: [VisualAssetAnomaly]
    var inspectedFrameCount: Int = 0
    var totalFrameCount: Int = 0
    var orientation: Int? = nil

    var aspectRatioString: String {
        if pixelHeight == 0 { return "0:0" }
        let ratio = Double(pixelWidth) / Double(pixelHeight)
        if abs(ratio - (16.0 / 9.0)) < 0.05 { return "16:9" }
        if abs(ratio - (4.0 / 3.0)) < 0.05 { return "4:3" }
        if abs(ratio - 1.0) < 0.05 { return "1:1" }
        if abs(ratio - (9.0 / 16.0)) < 0.05 { return "9:16" }
        return String(format: "%.2f:1", ratio)
    }
}
