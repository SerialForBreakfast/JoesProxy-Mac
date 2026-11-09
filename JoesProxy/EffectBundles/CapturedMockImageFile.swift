import Darwin
import Foundation
import ImageIO

struct CapturedMockImageFile: Sendable {
    let itemPointer: String?
    let bookmarkRef: String
    let originalURL: URL?
    var deliveryURL: URL? = nil
    var imageReference: String? = nil
    var generatedPNG: Data? = nil

    /// Run on the authoring actor. Never return resolved paths or underlying filesystem errors.
    func read() throws -> CapturedMockImageBinding {
        if let generatedPNG {
            guard bookmarkRef.isEmpty, !generatedPNG.isEmpty,
                  generatedPNG.count <= MockIconArtwork.maximumPNGBytes,
                  generatedPNG.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
                  let source = CGImageSourceCreateWithData(generatedPNG as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (1...2048).contains(width), (1...2048).contains(height),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width <= 2048, image.height <= 2048 else { throw ImageFileError.invalidReference }
            return CapturedMockImageBinding(itemPointer: itemPointer, bytes: generatedPNG,
                originalURL: originalURL, deliveryURL: deliveryURL, imageReference: imageReference)
        }
        guard bookmarkRef.utf8.count <= 64 * 1_024,
              let bookmark = Data(base64Encoded: bookmarkRef), !bookmark.isEmpty else {
            throw ImageFileError.invalidReference
        }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch { throw ImageFileError.invalidReference }
        guard !stale, url.isFileURL else { throw ImageFileError.invalidReference }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ImageFileError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ImageFileError.notRegularFile
        }
        guard info.st_size > 0, info.st_size <= EffectBundleBudget.maxFileBytes else {
            throw ImageFileError.sizeLimit
        }
        let bytes: Data
        do { bytes = try handle.read(upToCount: EffectBundleBudget.maxFileBytes + 1) ?? Data() }
        catch { throw ImageFileError.unavailable }
        guard !bytes.isEmpty, bytes.count <= EffectBundleBudget.maxFileBytes else { throw ImageFileError.sizeLimit }
        guard bytes.count == info.st_size else { throw ImageFileError.changedDuringRead }
        return CapturedMockImageBinding(itemPointer: itemPointer, bytes: bytes, originalURL: originalURL,
            deliveryURL: deliveryURL, imageReference: imageReference)
    }

    enum ImageFileError: String, Error, Sendable {
        case invalidReference, unavailable, notRegularFile, sizeLimit, changedDuringRead
    }
}
