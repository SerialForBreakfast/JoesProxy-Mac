import Foundation
import AppKit

/// Synthetic in-memory authoring only. No file import, approval, listener or effect activation.
@MainActor
enum GuidedMockAuthoringUITestFixture {
    static let primary = capture(path: "/items", json: #"{"items":[{"id":1,"title":"Before"}]}"#)
    static let detail = capture(path: "/detail/2", json: #"{"id":2,"title":"Before"}"#)

    static func configure(_ draft: CapturedMockAuthoringDraft,
                          arguments: [String] = ProcessInfo.processInfo.arguments,
                          environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard draft.source == nil else { return }
        let artwork = arguments.contains("--ui-test-authoring-artwork")
        let editorial = artwork && arguments.contains("--ui-test-authoring-editorial")
        _ = draft.selectSource(artwork
            ? capture(path: "/items", json: editorial
                ? #"{"items":[{"id":1,"title":"Harbor","image":"original"}]}"#
                : #"{"items":[{"id":1,"title":"Before","image":"original"}]}"#) : primary)
        if editorial { draft.name = "Weekend collection — demonstration" }
        draft.clientAddress = "192.0.2.1"
        draft.guidedDraft.useTemplate = true
        draft.guidedDraft.edits = [.init(pointer: "/id", valueJSON: "2")]
        draft.addRelatedSource(artwork
            ? capture(path: "/detail/2", json: #"{"id":2,"title":"Before","image":"original"}"#) : detail)
        draft.relatedDrafts[0].identityLinks[0].primaryPointer = "/items/1/id"
        draft.relatedDrafts[0].edits = [.init(pointer: "/title", valueJSON: #""After""#)]
        if arguments.contains("--ui-test-batch-authoring") {
            draft.guidedDraft.edits = []
            draft.guidedDraft.expandTemplate = true
            draft.guidedDraft.expansionItemsJSON = #"[{"edits":[{"pointer":"/id","value":2}]},{"edits":[{"pointer":"/id","value":3}]}]"#
        }
        if artwork {
            do {
                let scope = try RuntimeStorageScope.uiTest(environment: environment)
                let url = scope.file("synthetic-artwork.png")
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32) else { return }
                for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.systemBlue, atX: x, y: y) } }
                guard let bytes = editorial ? editorialArtwork() : bitmap.representation(using: .png, properties: [:]) else { return }
                try bytes.write(to: url, options: .atomic)
                let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                let image = GuidedMockArtwork(name: editorial ? "Coast — owned demonstration artwork" : "Synthetic artwork",
                    bookmark: bookmark.base64EncodedString())
                draft.additionalArtwork = [image]
                draft.relatedDrafts[0].artworkBindings = [.init(artworkID: image.id, pointer: "/image")]
                draft.guidedDraft.expansionItemsJSON = #"[{"edits":[{"pointer":"/id","value":2}],"images":[{"pointer":"/image","assetID":"image-0"}]},{"edits":[{"pointer":"/id","value":3}]}]"#
                if editorial {
                    draft.guidedDraft.expansionItemsJSON = """
                    [
                      {"edits":[{"pointer":"/id","value":2},{"pointer":"/title","value":"Coast"}],
                       "images":[{"pointer":"/image","assetID":"image-0"}]},
                      {"edits":[{"pointer":"/id","value":3},{"pointer":"/title","value":"Ridge"}]}
                    ]
                    """
                    draft.relatedDrafts[0].edits = [.init(pointer: "/title", valueJSON: #""Coast""#)]
                }
            } catch { draft.errorMessage = "Synthetic artwork fixture could not be prepared." }
        }
    }

    /// Original geometric landscape for owned demonstration data, not a reconstructed UI.
    private static func editorialArtwork() -> Data? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 360,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 2560, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor(calibratedRed: 0.08, green: 0.19, blue: 0.29, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 640, height: 360)).fill()
        NSColor(calibratedRed: 0.97, green: 0.67, blue: 0.34, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 440, y: 220, width: 80, height: 80)).fill()
        NSColor(calibratedRed: 0.16, green: 0.49, blue: 0.56, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 640, height: 150)).fill()
        NSColor(calibratedRed: 0.25, green: 0.36, blue: 0.31, alpha: 1).setFill()
        let coast = NSBezierPath()
        coast.move(to: NSPoint(x: 0, y: 0))
        coast.line(to: NSPoint(x: 0, y: 260))
        coast.line(to: NSPoint(x: 380, y: 0))
        coast.close()
        coast.fill()
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func capture(path: String, json: String) -> SessionRecord {
        .init(request: .init(method: "GET", scheme: .https, host: "api.example.test", port: 443,
            path: path, headers: [], bodyData: nil, bodySize: nil),
            response: .init(statusCode: 200, headers: [.init(name: "Content-Type", value: "application/json")],
                bodyData: Data(json.utf8), bodySize: json.utf8.count), timing: .init(startedAt: Date()))
    }
}
