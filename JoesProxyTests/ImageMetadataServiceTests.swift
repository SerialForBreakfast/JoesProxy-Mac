import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import JoesProxy

final class ImageMetadataServiceTests: XCTestCase {
    private let service = ImageMetadataService()

    func testPNGMetadataReportsContainerDimensionsAndAlpha() throws {
        let data = try makePNGData(width: 2, height: 1)

        let metadata = service.loadMetadata(from: data)

        XCTAssertEqual(metadata.containerTypeIdentifier, "public.png")
        XCTAssertEqual(metadata.preferredMIMEType, "image/png")
        XCTAssertEqual(metadata.pixelWidth, 2)
        XCTAssertEqual(metadata.pixelHeight, 1)
        XCTAssertEqual(metadata.frameCount, 1)
        XCTAssertEqual(metadata.hasAlpha, true)
        XCTAssertNil(metadata.loadError)
    }

    func testJPEGMetadataReportsExifAndOrientation() throws {
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyDPIWidth: 144,
            kCGImagePropertyDPIHeight: 144,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Canon",
                kCGImagePropertyTIFFModel: "EOS"
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensModel: "24-70mm",
                kCGImagePropertyExifDateTimeOriginal: "2026:04:07 18:30:00"
            ]
        ]
        let data = try makeJPEGData(width: 3, height: 2, properties: properties)

        let metadata = service.loadMetadata(from: data)

        XCTAssertEqual(metadata.containerTypeIdentifier, "public.jpeg")
        XCTAssertEqual(metadata.preferredMIMEType, "image/jpeg")
        XCTAssertEqual(metadata.pixelWidth, 3)
        XCTAssertEqual(metadata.pixelHeight, 2)
        XCTAssertEqual(metadata.orientationDescription, "Right")
        XCTAssertEqual(metadata.dpiDescription, "144 DPI")
        XCTAssertEqual(metadata.exifSummary?.make, "Canon")
        XCTAssertEqual(metadata.exifSummary?.model, "EOS")
        XCTAssertEqual(metadata.exifSummary?.lensModel, "24-70mm")
        XCTAssertEqual(metadata.exifSummary?.dateTimeOriginal, "2026:04:07 18:30:00")
    }

    func testGIFMetadataReportsFrameCount() throws {
        let data = try makeGIFData(width: 2, height: 2, frameCount: 2)

        let metadata = service.loadMetadata(from: data)

        XCTAssertEqual(metadata.containerTypeIdentifier, "com.compuserve.gif")
        XCTAssertEqual(metadata.preferredMIMEType, "image/gif")
        XCTAssertEqual(metadata.frameCount, 2)
        XCTAssertTrue(metadata.isAnimated)
    }

    func testInvalidDataProducesLoadError() {
        let metadata = service.loadMetadata(from: Data("not-an-image".utf8))

        XCTAssertEqual(metadata.frameCount, 0)
        XCTAssertEqual(metadata.loadError, "Invalid image data")
    }

    private func makePNGData(width: Int, height: Int) throws -> Data {
        try makeImageData(type: UTType.png.identifier as CFString, width: width, height: height, properties: [:], frameCount: 1)
    }

    private func makeJPEGData(width: Int, height: Int, properties: [CFString: Any]) throws -> Data {
        try makeImageData(type: UTType.jpeg.identifier as CFString, width: width, height: height, properties: properties, frameCount: 1)
    }

    private func makeGIFData(width: Int, height: Int, frameCount: Int) throws -> Data {
        try makeImageData(
            type: UTType.gif.identifier as CFString,
            width: width,
            height: height,
            properties: [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFLoopCount: 0
                ]
            ],
            frameCount: frameCount
        )
    }

    private func makeImageData(
        type: CFString,
        width: Int,
        height: Int,
        properties: [CFString: Any],
        frameCount: Int
    ) throws -> Data {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, type, frameCount, nil) else {
            throw TestError.encodingFailed
        }

        if frameCount > 1 {
            CGImageDestinationSetProperties(destination, properties as CFDictionary)
        }

        for frameIndex in 0..<frameCount {
            let frameProperties: [CFString: Any]
            if type == UTType.gif.identifier as CFString {
                frameProperties = [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: 0.1
                    ]
                ]
            } else {
                frameProperties = properties
            }

            CGImageDestinationAddImage(destination, try makeTestImage(width: width, height: height, seed: frameIndex), frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw TestError.encodingFailed
        }

        return mutableData as Data
    }

    private func makeTestImage(width: Int, height: Int, seed: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitsPerComponent = 8

        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = UInt8((32 + seed * 40) % 255)
            pixels[index + 1] = UInt8((96 + seed * 20) % 255)
            pixels[index + 2] = UInt8((160 + seed * 10) % 255)
            pixels[index + 3] = 255
        }

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw TestError.imageCreationFailed
        }

        return image
    }

    private enum TestError: Error {
        case encodingFailed
        case imageCreationFailed
    }
}
