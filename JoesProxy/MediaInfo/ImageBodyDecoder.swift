//
//  ImageBodyDecoder.swift
//  JoesProxy
//
//  Decodes captured image response bytes into AppKit images for preview UI.
//

import AppKit
import Foundation
import ImageIO

enum ImageBodyDecoder {
    static func makeImage(from data: Data) -> NSImage? {
        guard ImageInspectionPreflight.inspect(data).reason == nil else { return nil }
        if let image = makeImageWithImageIO(from: data) {
            return image
        }

        return nil
    }

    private static func makeImageWithImageIO(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }
}
