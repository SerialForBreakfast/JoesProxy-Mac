import AVKit
import SwiftUI

/// Explicit, isolated acceptance fixture. It never registers proxy rules or changes caption preferences.
struct CaptionPlayerUITestView: View {
    @StateObject private var model = CaptionPlayerUITestModel()
    @State private var selection = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Native caption rendering review").font(.headline)
            Text("Synthetic muted playback. Decoder readiness is not visual acceptance; inspect the player image.")
            CaptionNativePlayerView(player: model.player)
                .frame(width: 960, height: 540)
                .accessibilityIdentifier("captionNativePlayer")
            HStack {
                ForEach(model.tracks) { track in
                    Button(track.id) { selection = track.id }
                        .accessibilityIdentifier("captionSelect-\(track.id)")
                }
                Button("Off") { selection = "off" }.accessibilityIdentifier("captionSelect-off")
            }
            .disabled(!model.isReady || model.stopRequested)
            Text(model.status).accessibilityIdentifier("captionPlayerStatus")
            Button("Stop and release fixture") { model.requestStop() }
                .accessibilityIdentifier("captionPlayerStop")
        }
        .padding(20)
        .background(UITestPrimaryScreenWindowConfigurator().frame(width: 0, height: 0))
        .task { await model.run() }
        .task(id: selection) {
            guard !selection.isEmpty else { return }
            await model.select(selection)
        }
    }
}

private struct CaptionNativePlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}

@MainActor
private final class CaptionPlayerUITestModel: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var tracks: [HLSWebVTTFixture.Track] = []
    @Published private(set) var isReady = false
    @Published private(set) var stopRequested = false
    @Published private(set) var status = "Preparing synthetic player"
    private var group: AVMediaSelectionGroup?
    private let cues = CaptionVisualProbeCueCollector()

    func requestStop() {
        stopRequested = true
        isReady = false
        player.pause()
    }

    /// The view task owns the server until Stop or cancellation and awaits shutdown before returning.
    func run() async {
        guard ProcessInfo.processInfo.environment["JOESPROXY_CAPTION_PLAYER_ACCEPTANCE"] == "1" else {
            status = "Playback disabled: explicit caption-player acceptance opt-in required"
            return
        }
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Fixtures/HLS/multilingual-text-vod-v1") else {
            status = "Failed: bundled caption profile unavailable"
            return
        }
        var server: HLSFixtureServer?
        let output = AVPlayerItemLegibleOutput()
        output.suppressesPlayerRendering = false
        output.setDelegate(cues, queue: .main)
        do {
            let preparation = Task.detached(priority: .utility) { HLSFixtureProfileDescriptor.load(from: directory) }
            let profile = await withTaskCancellationHandler { await preparation.value } onCancel: { preparation.cancel() }
            try Task.checkCancellation()
            guard !stopRequested else { throw CancellationError() }
            guard let specification = profile.textFixture else { throw ProbeError.unavailable }
            tracks = specification.tracks
            var configuration = HLSPlaybackConfiguration.conformant
            configuration.presentationMode = .vodStatic
            let fixture = try await HLSFixtureServer.make(profileDirectory: directory, playbackConfiguration: configuration)
            server = fixture
            try Task.checkCancellation()
            guard !stopRequested else { throw CancellationError() }
            try await fixture.start()
            guard let base = fixture.baseURL else { throw ProbeError.unavailable }
            let item = AVPlayerItem(url: base.appendingPathComponent("master.m3u8"))
            item.add(output)
            player.isMuted = true
            player.appliesMediaSelectionCriteriaAutomatically = false
            player.replaceCurrentItem(with: item)
            try await waitUntil { item.status != .unknown }
            guard item.status == .readyToPlay else { throw item.error ?? ProbeError.unavailable }
            group = try await item.asset.loadMediaSelectionGroup(for: .legible)
            guard let group, group.options.count == tracks.count else { throw ProbeError.unavailable }
            item.select(nil, in: group)
            isReady = true
            status = "Ready: \(tracks.count) tracks; no visual acceptance recorded"
            while !stopRequested { try await Task.sleep(for: .milliseconds(100)) }
        } catch is CancellationError {
            stopRequested = true
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
        isReady = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        output.setDelegate(nil, queue: nil)
        group = nil
        if let server { await server.stop() }
        if stopRequested { status = "Stopped: player released; fixture listener stopped" }
    }

    func select(_ id: String) async {
        guard isReady, !stopRequested, let item = player.currentItem, let group else { return }
        player.pause()
        status = "Preparing selection: \(id)"
        do {
            let track = tracks.first { $0.id == id }
            let option: AVMediaSelectionOption?
            let cue: HLSWebVTTFixture.Cue?
            if id == "off" {
                option = nil
                cue = nil
            } else {
                guard let track, let first = track.cues.first else { throw ProbeError.unavailable }
                let matches = group.options.filter {
                    $0.extendedLanguageTag == track.language &&
                    $0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) == (track.role == .forced) &&
                    $0.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility) == (track.role == .sdh)
                }
                guard matches.count == 1 else { throw ProbeError.unavailable }
                option = matches[0]
                cue = first
            }
            item.select(option, in: group)
            let time = max(0, Double(cue?.startMilliseconds ?? 0) / 1000 - 0.5)
            let completed = await player.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                                              toleranceBefore: .zero, toleranceAfter: .zero)
            try Task.checkCancellation()
            guard completed, !stopRequested else { return }
            cues.reset()
            player.play()
            if let cue {
                try await waitUntil { self.cues.contains(cue.text) && self.player.currentTime().seconds >= Double(cue.startMilliseconds) / 1000 + 0.25 }
                guard player.currentTime().seconds < Double(cue.endMilliseconds) / 1000 else { throw ProbeError.missedCue }
            } else {
                try await waitUntil { self.player.currentTime().seconds >= 1.5 }
                guard cues.isEmpty else { throw ProbeError.unexpectedCue }
            }
            try Task.checkCancellation()
            player.pause()
            status = "Ready for visual review: \(id)"
        } catch is CancellationError {
            // The next selection owns player state; cancelled work must not pause or relabel it.
        } catch {
            guard !Task.isCancelled, !stopRequested else { return }
            player.pause()
            status = "Failed: \(error.localizedDescription)"
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition() {
            try Task.checkCancellation()
            guard !stopRequested, ContinuousClock.now < deadline else { throw ProbeError.timeout }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
    }
    private enum ProbeError: Error { case unavailable, missedCue, unexpectedCue, timeout }
}

/// Latest decoder text only, bounded independently of playback duration. No custom caption renderer.
private final class CaptionVisualProbeCueCollector: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    private let lock = NSLock()
    private var value = ""
    func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
                       nativeSampleBuffers: [Any], forItemTime itemTime: CMTime) {
        lock.withLock { value = String(strings.map(\.string).joined(separator: "\n").prefix(2048)) }
    }
    func reset() { lock.withLock { value = "" } }
    func contains(_ text: String) -> Bool { lock.withLock { value.contains(text) } }
    var isEmpty: Bool { lock.withLock { value.isEmpty } }
}
