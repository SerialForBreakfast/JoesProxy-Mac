import AppKit
import ImageIO
import UniformTypeIdentifiers

struct MockIconArtwork: Sendable {
    static let maximumPNGBytes = 2 * 1_024 * 1_024
    let name: String
    let png: Data
    let usedFallback: Bool
}

/// Pinned, local non-brand artwork. No runtime downloads or system-symbol extraction.
enum MockIconCatalog {
    struct Entry: Identifiable, Decodable, Sendable {
        let id: String
        let name: String
        let category: String
        let tags: [String]
        let style: String
        let svg: String
        var label: String { id.replacingOccurrences(of: "-", with: " ").capitalized }
        var keywords: String { ([name, category] + tags).joined(separator: " ").lowercased() }
    }
    static let sealID = "joes-seal"
    static let entries: [Entry] = {
        guard let url = Bundle.main.url(forResource: "TablerCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }()
    static let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    static let license: String = {
        guard let url = Bundle.main.url(forResource: "Tabler-LICENSE", withExtension: "txt") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()
    static func matching(_ query: String) -> [Entry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        return entries.filter { entry in
            let text = "\(entry.label) \(entry.id) \(entry.keywords)".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// Retrieval only reduces the offered vocabulary; inference remains advisory and explicit.
    static func candidates(for input: String) -> [Entry] {
        let words = Set(input.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
            .subtracting(["a", "an", "the", "of", "and", "for", "with", "is", "in", "to",
                          "title", "description", "category", "image", "icon", "mock"])
        return entries.compactMap { entry -> (Entry, Int)? in
            let nameWords = Set(entry.name.split(separator: "-").map(String.init))
            let tagWords = Set(entry.keywords.split { !$0.isLetter && !$0.isNumber }.map(String.init))
            let score = words.intersection(nameWords).count * 8 + words.intersection(tagWords).count * 2
            return score > 0 ? (entry, score + (entry.style == "outline" ? 1 : 0)) : nil
        }.sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }.prefix(32).map(\.0)
    }
}

@MainActor
enum MockIconRenderer {
    enum Ink: String, CaseIterable { case black, blue, white
        var color: NSColor {
            switch self {
            case .black: return .black
            case .blue: return NSColor(srgbRed: 0.1, green: 0.35, blue: 0.8, alpha: 1)
            case .white: return .white
            }
        }
    }
    enum Failure: Error { case sealUnavailable, invalidSize, encoding }

    static func render(symbol: String, pixels: Int = 256, ink: Ink = .black,
                       opaque: Bool = false) throws -> MockIconArtwork {
        guard [64, 128, 256, 512].contains(pixels) else { throw Failure.invalidSize }
        guard symbol != MockIconCatalog.sealID,
              let entry = MockIconCatalog.byID[symbol], !MockIconCatalog.license.isEmpty else { return try seal() }
        let color: String
        switch ink {
        case .black: color = "#000000"
        case .blue: color = "#1a59cc"
        case .white: color = "#ffffff"
        }
        let svg = entry.svg.replacingOccurrences(of: "#000000", with: color)
            .replacingOccurrences(of: "currentColor", with: color)
        guard let image = NSImage(data: Data(svg.utf8)) else { return try seal() }
        // White-on-white would produce a valid but invisible mock; use the owned fallback.
        guard !(opaque && ink == .white), image.size.width > 0, image.size.height > 0 else { return try seal() }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw Failure.encoding }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        let side = CGFloat(pixels)
        context.cgContext.clear(CGRect(x: 0, y: 0, width: side, height: side))
        if opaque {
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side)).fill()
        }
        let scale = min(side * 0.7 / image.size.width, side * 0.7 / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                             width: size.width, height: size.height))
        guard let converted = bitmap.converting(to: .sRGB, renderingIntent: .default),
              let cgImage = converted.cgImage else { throw Failure.encoding }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)
            else { throw Failure.encoding }
        // Standalone mock PNGs carry the notice too, rather than relying only on the app bundle.
        let properties = [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription:
            "Tabler Icons v3.50.0: \(symbol)\n\(MockIconCatalog.license)"]]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), encoded.length <= MockIconArtwork.maximumPNGBytes
            else { throw Failure.encoding }
        let png = encoded as Data
        return .init(name: "\(entry.label) · \(symbol) · \(pixels) px", png: png, usedFallback: false)
    }

    static func seal() throws -> MockIconArtwork {
        guard let url = Bundle.main.url(forResource: "JoeSealOfApproval", withExtension: "png"),
              let bytes = try? Data(contentsOf: url), bytes.count <= MockIconArtwork.maximumPNGBytes,
              NSImage(data: bytes) != nil else { throw Failure.sealUnavailable }
        return .init(name: "Joe’s Seal of Approval", png: bytes, usedFallback: true)
    }
}
