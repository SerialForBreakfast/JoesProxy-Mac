// Read-only verification of saved diagnostic poster pixels and manifest integrity.
import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

struct Manifest: Decodable {
    let source: String
    let sourceSHA256: String
    let assets: [Asset]
}
struct Asset: Decodable {
    let file: String
    let width: Int
    let height: Int
    let sealSidePixels: Int
    let variant: String
    let sha256: String
    let byteCount: Int
}
enum VerificationError: Error { case invalidPath, invalidManifest, decoding, mismatch(String) }
func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
guard CommandLine.arguments.count == 2 else { throw VerificationError.invalidPath }
let directory = root.appendingPathComponent(CommandLine.arguments[1]).resolvingSymlinksInPath()
guard directory.path.hasPrefix(root.path + "/assets/DiagnosticPosters/") else {
    throw VerificationError.invalidPath
}
let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
let source = root.appendingPathComponent(manifest.source).resolvingSymlinksInPath()
guard source.path.hasPrefix(root.path + "/"),
      hash(try Data(contentsOf: source)) == manifest.sourceSHA256 else { throw VerificationError.invalidManifest }
let groups = Dictionary(grouping: manifest.assets, by: { "\($0.width)x\($0.height)" })
guard groups.count == 3, manifest.assets.count == 12 else { throw VerificationError.invalidManifest }
for key in groups.keys.sorted() {
    let assets = groups[key]!
    guard assets.count == 4, Set(assets.map(\.variant)) == Set(["clean", "red", "green", "blue"]) else {
        throw VerificationError.invalidManifest
    }
    var reference: Data?
    for asset in assets.sorted(by: { $0.variant < $1.variant }) {
        let file = directory.appendingPathComponent(asset.file).resolvingSymlinksInPath()
        guard file.path.hasPrefix(directory.path + "/") else { throw VerificationError.invalidPath }
        let bytes = try Data(contentsOf: file)
        guard hash(bytes) == asset.sha256, bytes.count == asset.byteCount else {
            throw VerificationError.mismatch(asset.file + " manifest hash/size")
        }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == asset.width, image.height == asset.height,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw VerificationError.decoding }
        let side = asset.sealSidePixels
        guard side > 0, side <= min(asset.width, asset.height),
              let crop = image.cropping(to: CGRect(x: (asset.width - side) / 2, y: (asset.height - side) / 2,
                                                  width: side, height: side)),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw VerificationError.decoding
        }
        context.setBlendMode(.copy)
        context.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let pixels = context.data else { throw VerificationError.decoding }
        let decoded = Data(bytes: pixels, count: side * side * 4)
        if let reference, reference != decoded { throw VerificationError.mismatch(asset.file + " seal pixels") }
        reference = decoded
    }
    print("PASS \(key): all four full seal rectangles pixel-identical, including guides and edges; SHA256 \(hash(reference!))")
}
print("PASS: 12 saved PNG hashes/sizes/dimensions and original source hash verified. No files modified.")
