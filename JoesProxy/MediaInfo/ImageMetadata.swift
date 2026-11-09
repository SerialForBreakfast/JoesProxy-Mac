//
//  ImageMetadata.swift
//  JoesProxy
//
//  Capture-derived image metadata used by Media Info.
//

import Foundation

struct ImageMetadata: Sendable {
    let pixelWidth: Int?
    let pixelHeight: Int?
    let frameCount: Int
    let containerTypeIdentifier: String?
    let preferredMIMEType: String?
    let orientationDescription: String?
    let colorModel: String?
    let hasAlpha: Bool?
    let dpiDescription: String?
    let exifSummary: ImageEXIFSummary?
    let auxiliaryDataTypes: [String]
    let loadError: String?

    var isAnimated: Bool {
        frameCount > 1
    }
}

struct ImageEXIFSummary: Sendable {
    let make: String?
    let model: String?
    let lensModel: String?
    let dateTimeOriginal: String?
}
