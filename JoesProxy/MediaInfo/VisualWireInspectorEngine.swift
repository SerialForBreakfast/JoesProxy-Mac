//
//  VisualWireInspectorEngine.swift
//  JoesProxy
//
//  Analyzes decoded pixel data to extract color palettes, calculate BPP, and detect visual anomalies.
//

import Foundation
import CoreGraphics
import ImageIO
import AppKit

enum VisualWireInspectorEngine {

    /// Analyzes raw image data to produce a detailed VisualAssetReport.
    static func analyze(imageData: Data) -> VisualAssetReport {
        let preflight = ImageInspectionPreflight.inspect(imageData)
        guard let source = preflight.source, !Task.isCancelled,
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return VisualAssetReport(
                pixelWidth: 0,
                pixelHeight: 0,
                aspectRatio: 0,
                bytesPerPixel: 0,
                dominantPalette: [],
                hasTransparency: false,
                isFullyTransparent: false,
                anomalies: [preflight.reason == "malformed_metadata" ? .malformedPixelData : preflight.reason.map { .inspectionUnavailable(reason: $0) } ?? .malformedPixelData],
                totalFrameCount: preflight.frameCount, orientation: preflight.orientation
            )
        }

        let width = cgImage.width
        let height = cgImage.height
        let aspectRatio = height > 0 ? Double(width) / Double(height) : 0.0
        let totalPixels = width * height
        let bpp = totalPixels > 0 ? Double(imageData.count) / Double(totalPixels) : 0.0

        // Pixel sampling and color histogram
        let (palette, hasTransparency, isFullyTransparent, isMonochrome, dominantHex) = extractPaletteAndAlpha(from: cgImage)

        var anomalies: [VisualAssetAnomaly] = []

        if isFullyTransparent {
            anomalies.append(.blankTransparent)
        } else if isMonochrome, let hex = dominantHex {
            anomalies.append(.monochromeEmpty(hex: hex))
        }

        if bpp > 4.0 && totalPixels > 10000 {
            anomalies.append(.excessiveBPP(bpp: bpp))
        }

        return VisualAssetReport(
            pixelWidth: width,
            pixelHeight: height,
            aspectRatio: aspectRatio,
            bytesPerPixel: bpp,
            dominantPalette: palette,
            hasTransparency: hasTransparency,
            isFullyTransparent: isFullyTransparent,
            anomalies: anomalies, inspectedFrameCount: 1, totalFrameCount: preflight.frameCount,
            orientation: preflight.orientation
        )
    }

    // MARK: - Pixel Extraction & Color Quantization

    private static func extractPaletteAndAlpha(
        from cgImage: CGImage
    ) -> (palette: [ColorSwatch], hasTransparency: Bool, isFullyTransparent: Bool, isMonochrome: Bool, dominantHex: String?) {
        let sampleWidth = min(64, cgImage.width)
        let sampleHeight = min(64, cgImage.height)
        let totalSamples = sampleWidth * sampleHeight

        guard totalSamples > 0 else {
            return ([], false, false, false, nil)
        }

        let bytesPerPixel = 4
        let bytesPerRow = sampleWidth * bytesPerPixel
        var rawData = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)

        let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: &rawData,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return ([], false, false, false, nil)
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        var transparentCount = 0
        var colorHistogram: [UInt32: Int] = [:] // Quantized RGB bucket -> count
        var originalColors: [UInt32: (r: Double, g: Double, b: Double, a: Double)] = [:]

        for i in 0..<totalSamples {
            let offset = i * bytesPerPixel
            let r = rawData[offset]
            let g = rawData[offset + 1]
            let b = rawData[offset + 2]
            let a = rawData[offset + 3]

            if a < 10 {
                transparentCount += 1
                continue
            }

            // Quantize to 5 bits (32 levels per channel)
            let qR = UInt32((r >> 3) << 3)
            let qG = UInt32((g >> 3) << 3)
            let qB = UInt32((b >> 3) << 3)
            let key = (qR << 16) | (qG << 8) | qB

            colorHistogram[key, default: 0] += 1
            if originalColors[key] == nil {
                originalColors[key] = (Double(r) / 255.0, Double(g) / 255.0, Double(b) / 255.0, Double(a) / 255.0)
            }
        }

        let isFullyTransparent = transparentCount >= totalSamples
        let hasTransparency = transparentCount > 0

        let validColorSamples = totalSamples - transparentCount
        let sortedBuckets = colorHistogram.sorted(by: { $0.value > $1.value })

        var swatches: [ColorSwatch] = []
        for (key, count) in sortedBuckets.prefix(5) {
            if let col = originalColors[key] {
                let weight = validColorSamples > 0 ? Double(count) / Double(validColorSamples) : 0.0
                let hex = String(
                    format: "#%02X%02X%02X",
                    Int((col.r * 255.0).rounded()),
                    Int((col.g * 255.0).rounded()),
                    Int((col.b * 255.0).rounded())
                )
                swatches.append(
                    ColorSwatch(
                        hex: hex,
                        red: col.r,
                        green: col.g,
                        blue: col.b,
                        alpha: col.a,
                        weight: weight
                    )
                )
            }
        }

        let isMonochrome = (sortedBuckets.first?.value ?? 0) >= Int(Double(validColorSamples) * 0.98) && validColorSamples > 0
        let dominantHex = swatches.first?.hex

        return (swatches, hasTransparency, isFullyTransparent, isMonochrome, dominantHex)
    }
}
