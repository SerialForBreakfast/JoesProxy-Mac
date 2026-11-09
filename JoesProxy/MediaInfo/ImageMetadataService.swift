//
//  ImageMetadataService.swift
//  JoesProxy
//
//  Extracts image metadata from captured response bytes using ImageIO.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol ImageMetadataProviding: Sendable {
    func loadMetadata(from data: Data) -> ImageMetadata
}

struct ImageMetadataService: ImageMetadataProviding, Sendable {
    func loadMetadata(from data: Data) -> ImageMetadata {
        guard data.count <= ImageInspectionPreflight.maximumEncodedBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return ImageMetadata(
                pixelWidth: nil,
                pixelHeight: nil,
                frameCount: 0,
                containerTypeIdentifier: nil,
                preferredMIMEType: nil,
                orientationDescription: nil,
                colorModel: nil,
                hasAlpha: nil,
                dpiDescription: nil,
                exifSummary: nil,
                auxiliaryDataTypes: [],
                loadError: "Invalid image data"
            )
        }

        let frameCount = CGImageSourceGetCount(source)
        let typeIdentifier = CGImageSourceGetType(source) as String?
        guard frameCount > 0 || typeIdentifier != nil else {
            return ImageMetadata(
                pixelWidth: nil,
                pixelHeight: nil,
                frameCount: 0,
                containerTypeIdentifier: nil,
                preferredMIMEType: nil,
                orientationDescription: nil,
                colorModel: nil,
                hasAlpha: nil,
                dpiDescription: nil,
                exifSummary: nil,
                auxiliaryDataTypes: [],
                loadError: "Invalid image data"
            )
        }
        let preferredMIMEType = typeIdentifier.flatMap { UTType($0)?.preferredMIMEType }

        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]

        let pixelWidth = integerValue(for: kCGImagePropertyPixelWidth, in: properties)
        let pixelHeight = integerValue(for: kCGImagePropertyPixelHeight, in: properties)
        let orientationDescription = orientationDescription(for: integerValue(for: kCGImagePropertyOrientation, in: properties))
        let colorModel = stringValue(for: kCGImagePropertyColorModel, in: properties)
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool
        let dpiDescription = dpiDescription(from: properties)
        let exifSummary = exifSummary(from: properties)
        let auxiliaryDataTypes = ImageInspectionPreflight.inspect(data).reason == nil ? auxiliaryDataTypes(in: source) : []

        return ImageMetadata(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            frameCount: frameCount,
            containerTypeIdentifier: typeIdentifier,
            preferredMIMEType: preferredMIMEType,
            orientationDescription: orientationDescription,
            colorModel: colorModel,
            hasAlpha: hasAlpha,
            dpiDescription: dpiDescription,
            exifSummary: exifSummary,
            auxiliaryDataTypes: auxiliaryDataTypes,
            loadError: nil
        )
    }

    private func integerValue(for key: CFString, in properties: [CFString: Any]) -> Int? {
        if let value = properties[key] as? Int {
            return value
        }
        if let value = properties[key] as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private func stringValue(for key: CFString, in properties: [CFString: Any]) -> String? {
        properties[key] as? String
    }

    private func dpiDescription(from properties: [CFString: Any]) -> String? {
        let width = integerValue(for: kCGImagePropertyDPIWidth, in: properties)
        let height = integerValue(for: kCGImagePropertyDPIHeight, in: properties)

        switch (width, height) {
        case let (w?, h?) where w == h:
            return "\(w) DPI"
        case let (w?, h?):
            return "\(w) x \(h) DPI"
        case let (w?, nil):
            return "\(w) DPI"
        case let (nil, h?):
            return "\(h) DPI"
        default:
            return nil
        }
    }

    private func exifSummary(from properties: [CFString: Any]) -> ImageEXIFSummary? {
        let tiffProperties = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exifProperties = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]

        let make = tiffProperties?[kCGImagePropertyTIFFMake] as? String
        let model = tiffProperties?[kCGImagePropertyTIFFModel] as? String
        let lensModel = exifProperties?[kCGImagePropertyExifLensModel] as? String
        let dateTimeOriginal = exifProperties?[kCGImagePropertyExifDateTimeOriginal] as? String

        if make == nil, model == nil, lensModel == nil, dateTimeOriginal == nil {
            return nil
        }

        return ImageEXIFSummary(
            make: make,
            model: model,
            lensModel: lensModel,
            dateTimeOriginal: dateTimeOriginal
        )
    }

    private func auxiliaryDataTypes(in source: CGImageSource) -> [String] {
        let knownTypes: [(CFString, String)] = [
            (kCGImageAuxiliaryDataTypeDepth, "Depth"),
            (kCGImageAuxiliaryDataTypeDisparity, "Disparity"),
            (kCGImageAuxiliaryDataTypePortraitEffectsMatte, "Portrait Matte"),
            (kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte, "Skin Matte"),
            (kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte, "Hair Matte"),
            (kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte, "Teeth Matte"),
            (kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte, "Glasses Matte"),
            (kCGImageAuxiliaryDataTypeHDRGainMap, "HDR Gain Map")
        ]

        return knownTypes.compactMap { type, label in
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) != nil ? label : nil
        }
    }

    private func orientationDescription(for rawValue: Int?) -> String? {
        guard let rawValue else { return nil }

        switch rawValue {
        case 1: return "Up"
        case 2: return "Up Mirrored"
        case 3: return "Down"
        case 4: return "Down Mirrored"
        case 5: return "Left Mirrored"
        case 6: return "Right"
        case 7: return "Right Mirrored"
        case 8: return "Left"
        default: return "Unknown (\(rawValue))"
        }
    }
}
