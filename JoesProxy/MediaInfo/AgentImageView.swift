import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum AgentImageView {
    /// A single worker performs the request. Vision exposes cancellation to the caller.
    final class TextRecognition: @unchecked Sendable {
        let request = VNRecognizeTextRequest()
        func cancel() { request.cancel() }
    }
    struct Options: Decodable, Sendable {
        enum Mode: String, Decodable, Sendable { case preview, ocr }
        let mode: Mode
        let maxEdge: Int?
        let crop: [Double]?
        let grayscale: Bool?
        let quality: Double?
        let includeBoxes: Bool?

        func validate() throws {
            guard (32...1024).contains(maxEdge ?? 384), (0.1...1).contains(quality ?? 0.75) else {
                throw MCPStructuredError.malformedRequest(message: "maxEdge must be 32...1024 and quality 0.1...1.")
            }
            if let crop {
                guard crop.count == 4, crop.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                      crop[2] > 0, crop[3] > 0, crop[0] + crop[2] <= 1, crop[1] + crop[3] <= 1 else {
                    throw MCPStructuredError.malformedRequest(message: "crop must be normalized top-left x,y,width,height within the image.")
                }
            }
        }
    }

    struct Line: Encodable, Sendable {
        let text: String
        let confidence: Float
        let box: [Double]?
    }
    struct Metadata: Encodable, Sendable {
        let sourceWidth: Int
        let sourceHeight: Int
        let orientation: Int
        let frameIndex: Int
        let frameCount: Int
        let crop: [Double]
        let width: Int
        let height: Int
        let method: String
        let sourceSHA256: String
        let lines: [Line]?
        let omittedLines: Int?
    }
    struct Result: Sendable {
        let metadata: Metadata
        let jpeg: Data?
    }

    static func render(_ response: CapturedResponse, options: Options, recognition: TextRecognition? = nil) throws -> Result {
        try options.validate()
        try Task.checkCancellation()
        guard response.statusCode == 200, !response.bodyDeferred, !response.bodyTruncated,
              response.recordingBodyOmissionReason == nil, let data = response.bodyData,
              !response.headers.contains(where: { $0.name.lowercased() == "content-range" }),
              response.bodySize.map({ $0 == data.count }) ?? true,
              data.count <= ImageInspectionPreflight.maximumEncodedBytes,
              let decoded = CapturedBodyDecoder.decode(response: response, maxDecodedBytes: ImageInspectionPreflight.maximumEncodedBytes),
              decoded.canUseAnalysisDataForInspection else { throw ArtifactAnalysisFailure.sourceUnavailable }
        let bytes = decoded.analysisData
        let inspected = ImageInspectionPreflight.inspect(bytes)
        guard let source = inspected.source, let w = inspected.width, let h = inspected.height else {
            throw MCPStructuredError.malformedRequest(message: "Image unavailable: \(inspected.reason ?? "metadata_unavailable").")
        }
        let edge = options.maxEdge ?? (options.mode == .ocr ? 1024 : 384)
        let region = options.crop ?? [0, 0, 1, 1]
        let decodeEdge = options.crop == nil ? edge : max(w, h)
        let settings: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: decodeEdge]
        guard let oriented = CGImageSourceCreateThumbnailAtIndex(source, 0, settings as CFDictionary) else {
            throw ArtifactAnalysisFailure.sourceUnavailable
        }
        let rect = CGRect(x: region[0] * Double(oriented.width), y: region[1] * Double(oriented.height),
                          width: region[2] * Double(oriented.width), height: region[3] * Double(oriented.height)).integral
        guard let cropped = oriented.cropping(to: rect) else { throw ArtifactAnalysisFailure.sourceUnavailable }
        let scale = min(1, Double(edge) / Double(max(cropped.width, cropped.height)))
        let width = max(1, Int((Double(cropped.width) * scale).rounded()))
        let height = max(1, Int((Double(cropped.height) * scale).rounded()))
        let gray = options.grayscale == true
        guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: (gray ? CGImageAlphaInfo.none : .noneSkipLast).rawValue) else { throw ArtifactAnalysisFailure.inputLimit }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        canvas.setFillColor(gray: 1, alpha: 1)
        canvas.fill(bounds)
        canvas.interpolationQuality = .high
        canvas.draw(cropped, in: bounds)
        guard let image = canvas.makeImage() else { throw ArtifactAnalysisFailure.sourceUnavailable }
        try Task.checkCancellation()
        var jpeg: Data?
        var lines: [Line]?
        var omittedLines: Int?
        switch options.mode {
        case .preview:
            let buffer = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil)
                else { throw ArtifactAnalysisFailure.sourceUnavailable }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: options.quality ?? 0.75] as CFDictionary)
            guard CGImageDestinationFinalize(destination), buffer.length <= 48_000 else {
                throw MCPStructuredError.malformedRequest(message: "Preview exceeds output budget. Reduce maxEdge or quality.")
            }
            jpeg = buffer as Data
        case .ocr:
            let request = recognition?.request ?? VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try Task.checkCancellation()
            try VNImageRequestHandler(cgImage: image).perform([request])
            let observations = request.results ?? []
            var result: [Line] = []
            var remaining = 12_000
            for observation in observations.prefix(64) {
                guard let candidate = observation.topCandidates(1).first else { continue }
                guard candidate.string.utf8.count <= remaining else { break }
                remaining -= candidate.string.utf8.count
                let box = observation.boundingBox
                result.append(Line(text: candidate.string, confidence: candidate.confidence,
                    box: options.includeBoxes == true ? [box.minX, 1 - box.maxY, box.width, box.height] : nil))
            }
            lines = result
            omittedLines = observations.count - result.count
        }
        try Task.checkCancellation()
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return Result(metadata: .init(sourceWidth: w, sourceHeight: h, orientation: inspected.orientation ?? 1,
            frameIndex: 0, frameCount: inspected.frameCount, crop: region, width: width, height: height,
            method: options.mode == .ocr ? "heuristic_vision_ocr" : "imageio_jpeg", sourceSHA256: digest,
            lines: lines, omittedLines: omittedLines), jpeg: jpeg)
    }
}
