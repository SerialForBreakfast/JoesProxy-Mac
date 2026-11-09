import AVFoundation
import XCTest
@testable import JoesProxy

/// Opt-in host acceptance: run through host_ui_test.sh with
/// TEST_RUNNER_JOESPROXY_CAPTION_PLAYER_ACCEPTANCE=1. Ordinary Policy runs skip playback.
@MainActor
final class CaptionPlayerAcceptanceTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
    }

    private var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/HLS/multilingual-text-vod-v1")
    }

    func testDiscoversUnambiguousLanguageAndRoleMetadata() async throws {
        try requireHostOptIn()
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .vodStatic
        try await withPlayer(configuration: configuration) { _, _, group, _, _ in
            XCTAssertEqual(group.options.count, 7)
            for (language, role) in [("en", "subtitles"), ("es", "subtitles"), ("fr", "subtitles"),
                                     ("en", "sdh"), ("en", "forced"), ("ar", "subtitles"), ("ja", "subtitles")] {
                _ = try self.option(in: group, language: language, role: role)
            }
            self.attach("Seven unambiguous language/role options discovered. No playback/decoding claim.",
                        name: "caption-discovery-receipt")
        }
    }

    func testDecodesOneEnglishCue() async throws {
        try requireHostOptIn()
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .vodStatic
        try await withPlayer(configuration: configuration) { player, item, group, cues, _ in
            item.select(try self.option(in: group, language: "en", role: "subtitles"), in: group)
            await self.seek(player, to: 0)
            cues.reset()
            player.play()
            try await self.waitFor("first English cue", timeout: 12) { cues.contains("English caption test.") }
            player.pause()
            self.attach(cues.snapshot().joined(separator: "\n"), name: "caption-one-cue-receipt")
        }
    }

    func testVODExplicitLanguageRoleSwitchingAndOff() async throws {
        try requireHostOptIn()
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .vodStatic
        try await withPlayer(configuration: configuration) { player, item, group, cues, _ in
            item.select(nil, in: group)
            XCTAssertNil(item.currentMediaSelection.selectedMediaOption(in: group))
            let expected: [(String, String, String, Double)] = [
                ("en", "subtitles", "English caption test.", 0),
                ("es", "subtitles", "Prueba de subtítulos en español.", 0),
                ("fr", "subtitles", "Test de sous-titres en français.", 0),
                ("en", "sdh", "[Steady synthetic tone; no speech]", 0),
                ("en", "forced", "Forced-only diagnostic marker", 16),
                ("ar", "subtitles", "اختبار الترجمة العربية 123", 0),
                ("ja", "subtitles", "日本語字幕のテスト。", 0)
            ]
            XCTAssertEqual(group.options.count, 7)
            var receipts: [String] = []
            for (language, role, text, seekTime) in expected {
                let name = "\(language)/\(role)"
                player.pause()
                let option = try self.option(in: group, language: language, role: role)
                item.select(option, in: group)
                XCTAssertEqual(item.currentMediaSelection.selectedMediaOption(in: group), option)
                await self.seek(player, to: seekTime)
                cues.reset()
                player.play()
                try await waitFor("decoded cue for \(name)", timeout: 12) { cues.contains(text) }
                player.pause()
                receipts.append("\(name): selected; decoder produced \(cues.snapshot())")
            }
            item.select(nil, in: group)
            XCTAssertNil(item.currentMediaSelection.selectedMediaOption(in: group))
            await self.seek(player, to: 0)
            cues.reset()
            player.play()
            try await waitFor("Off playback advances", timeout: 10) { player.currentTime().seconds >= 3 }
            player.pause()
            XCTAssertTrue(cues.snapshot().isEmpty, "Explicit Off emitted text: \(cues.snapshot())")
            self.attach(receipts.joined(separator: "\n") + "\nOff: no nonempty decoded cue through 3 seconds.\nDecoder evidence is not a visual/VoiceOver or automatic-selection claim.", name: "caption-vod-player-receipt")
        }
    }

    func testLiveDVRSeekAcrossLoopAndCompletion() async throws {
        try requireHostOptIn()
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .liveLoop
        configuration.timeShiftMode = .warmDVR
        configuration.windowSegmentCount = 12
        try await withPlayer(configuration: configuration) { player, item, group, cues, server in
            let option = try self.option(in: group, language: "es", role: "subtitles")
            item.select(option, in: group)
            try await waitFor("live seekable range", timeout: 15) { !item.seekableTimeRanges.isEmpty }
            let range = try XCTUnwrap(item.seekableTimeRanges.first?.timeRangeValue)
            let start = range.start.seconds
            XCTAssertTrue(start.isFinite)
            await self.seek(player, to: start)
            cues.reset()
            player.play()
            try await waitFor("live Spanish cue", timeout: 15) { cues.contains("[es · subtitles") }
            player.pause()
            let first = cues.snapshot()
            let end = CMTimeRangeGetEnd(range).seconds
            let boundary = (floor(start / 24) + 1) * 24
            XCTAssertLessThan(boundary + 3, end, "Warm DVR must contain a loop boundary for this probe")
            await self.seek(player, to: boundary - 1)
            cues.reset()
            player.play()
            try await waitFor("caption after loop discontinuity", timeout: 15) { cues.contains("Prueba de subtítulos en español.") }
            player.pause()
            try server.completeLive()
            let (data, _) = try await URLSession.shared.data(from: try XCTUnwrap(server.baseURL)
                .appendingPathComponent("text/es/stream.m3u8"))
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("#EXT-X-ENDLIST"))
            self.attach("Live seek range: \(start)...\(end)\nInitial cue: \(first)\nPost-loop cue: \(cues.snapshot())\nServer completed with ENDLIST. Player end-of-stream and visible rendering remain separate acceptance.", name: "caption-live-player-receipt")
        }
    }

    private func requireHostOptIn() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JOESPROXY_CAPTION_PLAYER_ACCEPTANCE"] == "1",
            "Requires explicit host approval and the serial host wrapper; no playback in Policy.")
    }

    private func option(in group: AVMediaSelectionGroup, language: String, role: String) throws -> AVMediaSelectionOption {
        let matches = group.options.filter {
            $0.extendedLanguageTag == language &&
            $0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) == (role == "forced") &&
            $0.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility) == (role == "sdh")
        }
        XCTAssertEqual(matches.count, 1, "Expected an unambiguous \(language)/\(role) track; offered \(group.options.map(\.displayName))")
        return try XCTUnwrap(matches.first)
    }

    private func withPlayer(
        configuration: HLSPlaybackConfiguration,
        body: (AVPlayer, AVPlayerItem, AVMediaSelectionGroup, CaptionCueCollector, HLSFixtureServer) async throws -> Void
    ) async throws {
        let server = try await HLSFixtureServer.make(profileDirectory: directory, playbackConfiguration: configuration)
        do {
            try await server.start()
            let asset = AVURLAsset(url: try XCTUnwrap(server.baseURL).appendingPathComponent("master.m3u8"))
            let item = AVPlayerItem(asset: asset)
            let cues = CaptionCueCollector()
            let output = AVPlayerItemLegibleOutput()
            output.setDelegate(cues, queue: .main)
            item.add(output)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.appliesMediaSelectionCriteriaAutomatically = false
            defer { player.pause(); player.replaceCurrentItem(with: nil); output.setDelegate(nil, queue: nil) }
            try await waitFor("player readiness", timeout: 20) { item.status != .unknown }
            XCTAssertEqual(item.status, .readyToPlay, item.error?.localizedDescription ?? "No player error")
            let loadedGroup = try await asset.loadMediaSelectionGroup(for: .legible)
            let group = try XCTUnwrap(loadedGroup)
            try await body(player, item, group, cues, server)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
        XCTAssertFalse(server.isRunning)
    }

    private func seek(_ player: AVPlayer, to seconds: Double) async {
        let finished = await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                                        toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(finished, "Player seek was interrupted")
    }

    private func waitFor(_ description: String, timeout: TimeInterval, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard condition() else {
            XCTFail("Timed out: \(description)")
            throw AcceptanceFailure.timeout(description)
        }
    }

    private func attach(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private enum AcceptanceFailure: Error { case timeout(String) }
}

/// Delegate calls and test reads synchronize through one lock; storage never exceeds 64 cues.
private final class CaptionCueCollector: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    private let lock = NSLock()
    private var values: [String] = []

    func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
                       nativeSampleBuffers: [Any], forItemTime itemTime: CMTime) {
        let text = strings.map(\.string).filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        lock.lock()
        if values.count == 64 { values.removeFirst() }
        values.append("\(itemTime.seconds): \(text.prefix(1024))")
        lock.unlock()
    }

    func reset() { lock.lock(); values.removeAll(keepingCapacity: true); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
    func contains(_ text: String) -> Bool { snapshot().contains { $0.contains(text) } }
}
