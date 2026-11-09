import AppKit
import SwiftUI

/// Explicit synthetic fault injection. Never resolves bookmarks or edits files in normal launches.
@MainActor
final class GuidedMockDriftUITestScenario {
    enum SourceChange: Equatable { case incomplete, sameIdentity, differentIdentity }
    enum FixtureError: Error, Equatable { case disabled, invalidArtwork }
    private let draft: CapturedMockAuthoringDraft
    private let artworkURL: URL
    private let originalBytes: Data

    static func isEnabled(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        ["--ui-test-fixture=guided-mock-authoring", "--ui-test-authoring-artwork",
         "--ui-test-batch-authoring", "--ui-test-authoring-drift"].allSatisfy(arguments.contains)
    }

    init(draft: CapturedMockAuthoringDraft,
         arguments: [String] = ProcessInfo.processInfo.arguments,
         environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard Self.isEnabled(arguments: arguments) else { throw FixtureError.disabled }
        guard let root = environment["JOESPROXY_UI_ARTIFACT_DIRECTORY"],
              let image = draft.additionalArtwork.first,
              let bookmark = Data(base64Encoded: image.bookmark) else { throw FixtureError.invalidArtwork }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        let parent = URL(fileURLWithPath: root).standardizedFileURL
        guard !stale, url.isFileURL, parent.path.contains("/build/HostTestResults/"),
              parent.lastPathComponent.hasSuffix("-artifacts"),
              parent.resolvingSymlinksInPath() == parent,
              url.deletingLastPathComponent().deletingLastPathComponent() == parent,
              url.deletingLastPathComponent().lastPathComponent.hasPrefix("runtime-"),
              url.lastPathComponent == "synthetic-artwork.png",
              url.resolvingSymlinksInPath() == url else { throw FixtureError.invalidArtwork }
        self.draft = draft
        artworkURL = url
        originalBytes = try Data(contentsOf: url)
    }

    func selectSource(_ change: SourceChange) {
        guard let current = draft.source else { return }
        let bytes = Data(#"{"items":[{"id":1,"title":"Drifted source","image":"original"}]}"#.utf8)
        let response = CapturedResponse(statusCode: 200,
            headers: [.init(name: "Content-Type", value: "application/json")],
            bodyData: bytes, bodySize: bytes.count, bodyTruncated: change == .incomplete)
        let candidate = SessionRecord(id: change == .differentIdentity ? UUID() : current.id,
            request: current.request, response: response, timing: current.timing)
        let reason = draft.selectSource(candidate)
        draft.errorMessage = reason
    }

    func removeArtwork() throws {
        try validatePath()
        try FileManager.default.removeItem(at: artworkURL)
    }

    func replaceArtworkBytes() throws {
        try validatePath()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 12, bitsPerPixel: 32) else { throw FixtureError.invalidArtwork }
        for x in 0..<3 { bitmap.setColor(.systemOrange, atX: x, y: 0) }
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw FixtureError.invalidArtwork }
        // Preserve the inode so the existing bookmark still selects the changed file.
        try bytes.write(to: artworkURL)
    }

    func restoreArtwork() throws {
        guard draft.prepared == nil, !draft.busy else { throw FixtureError.invalidArtwork }
        try validatePath()
        try originalBytes.write(to: artworkURL)
        let bookmark = try artworkURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        guard let previous = draft.additionalArtwork.first else { throw FixtureError.invalidArtwork }
        var restored = GuidedMockArtwork(name: previous.name, bookmark: bookmark.base64EncodedString())
        restored.primaryPointer = previous.primaryPointer
        draft.additionalArtwork[0] = restored
        for related in draft.relatedDrafts.indices {
            for binding in draft.relatedDrafts[related].artworkBindings.indices
                where draft.relatedDrafts[related].artworkBindings[binding].artworkID == previous.id {
                draft.relatedDrafts[related].artworkBindings[binding].artworkID = restored.id
            }
        }
    }

    private func validatePath() throws {
        guard artworkURL.resolvingSymlinksInPath() == artworkURL else { throw FixtureError.invalidArtwork }
    }
}

@MainActor
struct GuidedMockDriftUITestControls: View {
    @ObservedObject var draft: CapturedMockAuthoringDraft
    @Environment(\.appTextScale) private var textScale
    @State private var scenario: GuidedMockDriftUITestScenario?
    @State private var status = "Fixture ready"

    var body: some View {
        VStack(alignment: .leading) {
            Text("Synthetic recovery controls").appFont(.caption, scale: textScale)
            HStack {
                Button("Incomplete source") { scenario?.selectSource(.incomplete) }
                    .accessibilityIdentifier("mockDriftIncompleteSource")
                Button("Changed source") { scenario?.selectSource(.sameIdentity) }
                    .accessibilityIdentifier("mockDriftChangedSource")
                Button("Different capture") { scenario?.selectSource(.differentIdentity) }
                    .accessibilityIdentifier("mockDriftDifferentSource")
            }
            HStack {
                Button("Remove fixture file") { perform { try scenario?.removeArtwork() } }
                    .accessibilityIdentifier("mockDriftRemoveArtwork")
                Button("Replace fixture bytes") { perform { try scenario?.replaceArtworkBytes() } }
                    .accessibilityIdentifier("mockDriftReplaceArtwork")
                Button("Restore fixture file") { perform { try scenario?.restoreArtwork() } }
                    .accessibilityIdentifier("mockDriftRestoreArtwork")
                    .disabled(draft.prepared != nil)
            }
            Text(status).accessibilityIdentifier("mockDriftStatus")
        }
        .appFont(.caption, scale: textScale)
        .disabled(scenario == nil || draft.busy || draft.discoveringCollections)
        .onAppear {
            guard scenario == nil else { return }
            do { scenario = try GuidedMockDriftUITestScenario(draft: draft) }
            catch { status = "Synthetic recovery fixture unavailable" }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); status = "Fixture change applied" }
        catch { status = "Synthetic recovery fixture action failed" }
    }
}
