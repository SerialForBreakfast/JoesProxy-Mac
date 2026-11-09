import Foundation
import ImageIO

enum ImageInspectionPreflight {
    static let maximumEncodedBytes = 32 * 1024 * 1024
    static let maximumPixels = 16_777_216
    static let maximumFrames = 256
    static let maximumDecodedBytes = 128 * 1024 * 1024

    struct Result {
        var source: CGImageSource?
        var reason: String?
        var frameCount: Int
        var orientation: Int?
        var width: Int?
        var height: Int?
    }
    static func inspect(_ data: Data) -> Result {
        guard !Task.isCancelled else { return .init(reason: "cancelled", frameCount: 0) }
        guard data.count <= maximumEncodedBytes else { return .init(reason: "encoded_byte_limit", frameCount: 0) }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value else {
            return .init(reason: "malformed_metadata", frameCount: 0)
        }
        let frames = CGImageSourceGetCount(source)
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        if let depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue, depth > 16 {
            return .init(reason: "sample_depth_limit", frameCount: frames, orientation: orientation)
        }
        let reason = rejection(width: width, height: height, frames: frames)
        return .init(source: reason == nil ? source : nil, reason: reason, frameCount: frames, orientation: orientation,
            width: Int(width), height: Int(height))
    }
    static func rejection(width: Int64, height: Int64, frames: Int) -> String? {
        guard width > 0, height > 0, width <= maximumPixels, height <= maximumPixels else { return "pixel_limit" }
        guard frames > 0, frames <= maximumFrames else { return "frame_limit" }
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow, pixels.partialValue <= maximumPixels else { return "pixel_limit" }
        // Conservative 8-byte working pixel allowance; inspection covers frame zero only.
        guard pixels.partialValue <= maximumDecodedBytes / 8 else { return "decoded_byte_limit" }
        return nil
    }
}
