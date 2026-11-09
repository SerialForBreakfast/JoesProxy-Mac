// Deterministic, repository-local fixture renderer. No network or application control.
// Compile with swiftc; run from the repository root with a NEW output directory below assets/.
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

struct Asset: Codable {
    let file: String
    let width: Int
    let height: Int
    let variant: String
    let gridCellPixels: Int
    let circleDiameterPixels: Int
    let sealSidePixels: Int
    let sha256: String
    let byteCount: Int
}

struct Manifest: Encodable {
    let schemaVersion = 1
    let rendererRevision = 3
    let source: String
    let sourceSHA256: String
    let colorSpace = "sRGB"
    let overlayOpacity = 0.0
    let sealPlacement = "aspect-fit within 10% side margins and reserved header/footer"
    let variantColorPlacement = "background only; seal is never tinted"
    let assets: [Asset]
}

enum RenderError: Error { case invalidPath, existingOutput, image, context, encoding, verification }

func hash(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
let sourceURL = root.appendingPathComponent("assets/JoeSealOfApproval.PNG")
let joeData = CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--joedata"
guard (CommandLine.arguments.count == 2 || joeData),
      FileManager.default.fileExists(atPath: root.appendingPathComponent("AGENTS.md").path),
      CommandLine.arguments[1].hasPrefix("assets/DiagnosticPosters/"),
      !CommandLine.arguments[1].split(separator: "/").contains("..") else { throw RenderError.invalidPath }
let output = root.appendingPathComponent(CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
guard output.path.hasPrefix(root.path + "/assets/DiagnosticPosters/"),
      sourceURL.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw RenderError.invalidPath }
guard !FileManager.default.fileExists(atPath: output.path) else { throw RenderError.existingOutput }
let sourceBytes = try Data(contentsOf: sourceURL)
guard let source = CGImageSourceCreateWithData(sourceBytes as CFData, nil),
      let seal = CGImageSourceCreateImageAtIndex(source, 0, nil), seal.width == seal.height,
      let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw RenderError.image }

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [red, green, blue, alpha])!
}

func render(width: Int, height: Int, variant: String, tint: CGColor?, cell: Int) throws -> (Data, Int, Int) {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RenderError.context }
    let w = CGFloat(width), h = CGFloat(height), short = min(w, h)
    context.setFillColor(color(0.035, 0.045, 0.065))
    context.fill(CGRect(x: 0, y: 0, width: w, height: h))
    if let tint {
        context.saveGState()
        context.setAlpha(0.24)
        context.setFillColor(tint)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.restoreGState()
    }
    let side = Int(min(w * 0.8, h - short * 0.36)) / 2 * 2
    let diameter = Int(short * 0.64) / 2 * 2
    let sealRect = CGRect(x: (w - CGFloat(side)) / 2, y: (h - CGFloat(side)) / 2,
                          width: CGFloat(side), height: CGFloat(side))
    context.interpolationQuality = .high
    context.draw(seal, in: sealRect)
    // Equal pixel spacing, not equal normalized spacing: every cell is square in every aspect ratio.
    context.setStrokeColor(color(0.7, 0.8, 1, 0.25))
    context.setLineWidth(1)
    for x in stride(from: 0, through: width, by: cell) {
        context.move(to: CGPoint(x: CGFloat(x) + 0.5, y: 0))
        context.addLine(to: CGPoint(x: CGFloat(x) + 0.5, y: h))
    }
    for y in stride(from: 0, through: height, by: cell) {
        context.move(to: CGPoint(x: 0, y: CGFloat(y) + 0.5))
        context.addLine(to: CGPoint(x: w, y: CGFloat(y) + 0.5))
    }
    context.strokePath()
    context.setStrokeColor(color(1, 1, 1))
    context.setLineWidth(4)
    context.strokeEllipse(in: CGRect(x: (w - CGFloat(diameter)) / 2, y: (h - CGFloat(diameter)) / 2,
                                    width: CGFloat(diameter), height: CGFloat(diameter)))
    context.setLineWidth(2)
    context.setLineDash(phase: 0, lengths: [10, 8])
    context.move(to: CGPoint(x: w / 2, y: 0)); context.addLine(to: CGPoint(x: w / 2, y: h))
    context.move(to: CGPoint(x: 0, y: h / 2)); context.addLine(to: CGPoint(x: w, y: h / 2))
    context.strokePath()
    context.setLineDash(phase: 0, lengths: [])
    for fraction: CGFloat in [0.025, 0.05, 0.10] {
        context.setStrokeColor(color(1, 1, 1, fraction == 0.05 ? 0.9 : 0.4))
        context.stroke(CGRect(x: w * fraction, y: h * fraction,
                              width: w * (1 - 2 * fraction), height: h * (1 - 2 * fraction)))
    }
    func text(_ string: String, y: CGFloat, size: CGFloat) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(1, 1, 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.setFillColor(color(0.035, 0.045, 0.065))
        context.fill(CGRect(x: (w - bounds.width) / 2 - 12, y: y - 10,
                            width: bounds.width + 24, height: size + 22))
        context.textPosition = CGPoint(x: (w - bounds.width) / 2, y: y)
        CTLineDraw(line, context)
    }
    text("JOESPROXY", y: h - short * 0.12, size: short * 0.052)
    let ratio = width == height ? "1:1" : width > height ? "16:9" : "2:3"
    text("\(ratio)  \(variant.uppercased())  V3", y: short * 0.115, size: short * 0.029)
    text("\(width) x \(height) | GRID \(cell) PX", y: short * 0.075, size: short * 0.019)
    // Exact opaque RGB reference patches; the seal itself is never tinted.
    let swatch = short * 0.025
    for (index, patch) in [color(1, 0, 0), color(0, 1, 0), color(0, 0, 1)].enumerated() {
        context.setFillColor(patch)
        context.fill(CGRect(x: w / 2 + CGFloat(index - 1) * swatch - swatch / 2,
                            y: short * 0.025, width: swatch, height: swatch))
    }
    guard let image = context.makeImage() else { throw RenderError.image }
    let bytes = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { throw RenderError.encoding }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw RenderError.encoding }
    return (bytes as Data, diameter, side)
}

// Render and verify everything before creating output; never overwrite a previous round.
// Presentation artwork is deliberately separate from the historical calibration fixtures.
func renderJoeData(width: Int, height: Int) throws -> Data {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RenderError.context }
    let w = CGFloat(width), h = CGFloat(height)
    let avatar = width == height
    context.setFillColor(avatar ? color(1, 1, 1) : color(0.035, 0.055, 0.095))
    context.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let side = avatar ? w * 0.68 : h * 0.62
    let rect = CGRect(x: avatar ? (w - side) / 2 : h * 0.12,
                      y: (h - side) / 2, width: side, height: side)
    context.interpolationQuality = .high
    context.draw(seal, in: rect)
    if !avatar {
        let x = rect.maxX + h * 0.12
        func label(_ text: String, y: CGFloat, size: CGFloat, ink: CGColor) throws {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            guard CTLineGetBoundsWithOptions(line, []).width <= w - x - h * 0.08 else { throw RenderError.verification }
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, context)
        }
        try label("JOEDATA", y: h * 0.60, size: h * 0.105, ink: color(1, 1, 1))
        try label("Build. Observe. Improve.", y: h * 0.46, size: h * 0.046, ink: color(0.65, 0.82, 1))
        try label("SYNTHETIC LOCAL DEMO", y: h * 0.30, size: h * 0.025, ink: color(0.7, 0.74, 0.81))
    }
    guard let image = context.makeImage() else { throw RenderError.image }
    let bytes = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { throw RenderError.encoding }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw RenderError.encoding }
    return bytes as Data
}

if joeData {
    var assets: [Asset] = []
    var payloads: [Data] = []
    for (name, width, height) in [("avatar", 1024, 1024), ("card", 1920, 1080), ("banner", 1920, 640)] {
        let bytes = try renderJoeData(width: width, height: height)
        guard bytes == (try renderJoeData(width: width, height: height)),
              let decoded = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(decoded, 0, nil),
              image.width == width, image.height == height else { throw RenderError.verification }
        assets.append(Asset(file: "joedata-\(name)-v1.png", width: width, height: height,
                            variant: "presentation-no-overlays", gridCellPixels: 0, circleDiameterPixels: 0,
                            sealSidePixels: Int(CGFloat(height) * (width == height ? 0.68 : 0.62)),
                            sha256: hash(bytes), byteCount: bytes.count))
        payloads.append(bytes)
    }
    guard hash(try Data(contentsOf: sourceURL)) == hash(sourceBytes) else { throw RenderError.verification }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for (asset, bytes) in zip(assets, payloads) {
        try bytes.write(to: output.appendingPathComponent(asset.file), options: .withoutOverwriting)
    }
    struct JoeDataManifest: Encodable {
        let schemaVersion = 1
        let purpose = "Provisional presentation masters; target dimensions and crop policy unverified"
        let source = "assets/JoeSealOfApproval.PNG"
        let sourceSHA256: String
        let sealPolicy = "Uniform scale-to-fit; no crop, tint, guides or overlays on the seal"
        let assets: [Asset]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(JoeDataManifest(sourceSHA256: hash(sourceBytes), assets: assets))
        .write(to: output.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
    print("Verified 3 JoeData PNGs; repeat renders byte-identical; source unchanged.")
    exit(0)
}

var rendered: [(Asset, Data)] = []
let variants: [(String, CGColor?)] = [("clean", nil), ("red", color(1, 0, 0)),
                                    ("green", color(0, 1, 0)), ("blue", color(0, 0, 1))]
for (ratio, width, height, cell) in [("2x3", 1024, 1536, 64), ("16x9", 1920, 1080, 60), ("1x1", 1024, 1024, 64)] {
    for (variant, tint) in variants {
        let (bytes, diameter, side) = try render(width: width, height: height, variant: variant, tint: tint, cell: cell)
        let (repeatBytes, _, _) = try render(width: width, height: height, variant: variant, tint: tint, cell: cell)
        guard bytes == repeatBytes, let decoded = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(decoded, 0, nil),
              image.width == width, image.height == height else { throw RenderError.verification }
        rendered.append((Asset(file: "joesproxy-seal-\(ratio)-\(variant)-v3.png", width: width, height: height,
                               variant: variant, gridCellPixels: cell, circleDiameterPixels: diameter,
                               sealSidePixels: side, sha256: hash(bytes), byteCount: bytes.count), bytes))
    }
}
guard hash(try Data(contentsOf: sourceURL)) == hash(sourceBytes) else { throw RenderError.verification }
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (asset, bytes) in rendered { try bytes.write(to: output.appendingPathComponent(asset.file), options: .withoutOverwriting) }
let manifest = Manifest(source: "assets/JoeSealOfApproval.PNG", sourceSHA256: hash(sourceBytes), assets: rendered.map(\.0))
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try encoder.encode(manifest).write(to: output.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
print("Verified and saved \(rendered.count) PNGs to \(output.path). Original source unchanged. Repeat renders byte-identical.")
