//
//  TriggerPlanRunner.swift
//  JoesProxyPlayer
//
/// Executes timed media-selection / transport actions against an `AVPlayerItem` periodic observer
/// so switch timing follows AVFoundation's clock, not external UI taps.
///

import AVFoundation
import Foundation

/// One scheduled action in a JoePlayer trigger plan.
struct JoePlayerTriggerAction: Codable, Equatable, Sendable {
    /// Player time (seconds) at which to fire. Compared against `AVPlayerItem.currentTime()`.
    let atPlayerTimeSeconds: Double
    /// Action kind: `selectAudio`, `play`, `pause`, or `seek`.
    let action: String
    /// Optional target (audio option display name / language / index string, or seek seconds).
    let target: String?
}

/// Decoded launch-argument trigger plan.
struct JoePlayerTriggerPlan: Codable, Equatable, Sendable {
    let actions: [JoePlayerTriggerAction]
}

/// Parses and runs `--joeplayer-trigger-plan=<base64-JSON>` against a live player item.
///
/// Concurrency: create on the main actor; observer callbacks hop to the main actor before mutating
/// selection state. Cancel via `stop()` when the item is replaced or the view disappears.
/// Pure plan encode/decode helpers are `nonisolated` so unit tests can exercise them off the main actor.
@MainActor
final class TriggerPlanRunner {
    /// Launch argument key including the trailing `=` used by `ProcessInfo` parsing.
    nonisolated static let launchArgumentPrefix = "--joeplayer-trigger-plan="

    private var pending: [JoePlayerTriggerAction] = []
    private var timeObserver: Any?
    private weak var player: AVPlayer?
    private var onEvent: ((String) -> Void)?

    /// Loads a plan from process launch arguments when present.
    nonisolated static func planFromLaunchArguments(
        _ arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> JoePlayerTriggerPlan? {
        guard let raw = arguments.first(where: { $0.hasPrefix(launchArgumentPrefix) }) else {
            return nil
        }
        let encoded = String(raw.dropFirst(launchArgumentPrefix.count))
        guard let data = Data(base64Encoded: encoded) else {
            return nil
        }
        return try? JSONDecoder().decode(JoePlayerTriggerPlan.self, from: data)
    }

    /// Encodes a plan for launch-argument injection (tests / scripts).
    nonisolated static func launchArgument(for plan: JoePlayerTriggerPlan) throws -> String {
        let data = try JSONEncoder().encode(plan)
        return launchArgumentPrefix + data.base64EncodedString()
    }

    /// Returns whether `option` matches a trigger-plan audio target string.
    ///
    /// Matching order: `ad` → accessibility describes-video characteristic (fixture NAME
    /// `"English (Audio Description)"` does **not** contain the substring `"ad"`), then exact
    /// BCP-47 / extended language tag, display-name substring, then extended-language-tag
    /// substring. Used by the trial suite for `en` / `es` / `ad` targets.
    nonisolated static func audioOption(
        _ option: AVMediaSelectionOption,
        matchesTarget target: String
    ) -> Bool {
        let normalizedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTarget.isEmpty else { return false }

        if Int(normalizedTarget) != nil {
            return false
        }

        let lowered = normalizedTarget.lowercased()

        // Trial suite audioTarget "ad" maps to the describes-video rendition (`audio-ad/`), not a
        // language tag. Fixture NAME is typically "English (Audio Description)" which does **not**
        // contain the substring "ad", so match characteristic and/or "description" in displayName.
        if lowered == "ad" || lowered == "audio-ad" || lowered == "audiodescription" {
            if option.hasMediaCharacteristic(.describesVideoForAccessibility) {
                return true
            }
            if option.displayName.localizedCaseInsensitiveContains("description") {
                return true
            }
        }

        if let tag = option.extendedLanguageTag?.lowercased(),
           tag == lowered {
            return true
        }

        if normalizedTarget.contains("-"),
           let tag = option.extendedLanguageTag?.lowercased(),
           tag.hasPrefix(lowered) {
            return true
        }

        if option.displayName.localizedCaseInsensitiveContains(normalizedTarget) {
            return true
        }

        if let tag = option.extendedLanguageTag?.lowercased(),
           tag.localizedCaseInsensitiveContains(lowered) {
            return true
        }

        return false
    }

    /// Starts observing `player` and fires pending actions once player time crosses each threshold.
    ///
    /// - Parameters:
    ///   - plan: Actions sorted ascending by time before arming.
    ///   - player: Active player whose item clock drives thresholds.
    ///   - onEvent: Optional diagnostic callback (e.g. recorder) for fired actions.
    func start(
        plan: JoePlayerTriggerPlan,
        player: AVPlayer,
        onEvent: ((String) -> Void)? = nil
    ) {
        stop()
        self.player = player
        self.onEvent = onEvent
        pending = plan.actions.sorted { $0.atPlayerTimeSeconds < $1.atPlayerTimeSeconds }
        guard !pending.isEmpty else { return }

        // Fire due-at-zero actions immediately so a leading `play@0` (or `@0.1` once time moves)
        // is not stuck behind a paused clock. Also kick playback when the plan schedules play,
        // so `playAtSeconds: 0.1` cannot deadlock waiting for time to advance while paused.
        if pending.contains(where: { $0.action == "play" }) {
            player.play()
        }
        handle(time: player.currentTime())

        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                self?.handle(time: time)
            }
        }
    }

    /// Removes the periodic observer and clears pending actions.
    func stop() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        pending.removeAll()
        player = nil
        onEvent = nil
    }

    private func handle(time: CMTime) {
        guard let player, time.isNumeric else { return }
        let seconds = time.seconds
        while let next = pending.first, seconds + 0.001 >= next.atPlayerTimeSeconds {
            pending.removeFirst()
            perform(next, on: player)
        }
    }

    private func perform(_ action: JoePlayerTriggerAction, on player: AVPlayer) {
        onEvent?("trigger:\(action.action)@\(action.atPlayerTimeSeconds) target=\(action.target ?? "")")
        switch action.action {
        case "play":
            player.play()
        case "pause":
            player.pause()
        case "seek":
            let seekSeconds = Double(action.target ?? "") ?? action.atPlayerTimeSeconds
            player.seek(to: CMTime(seconds: seekSeconds, preferredTimescale: 600))
        case "selectAudio":
            selectAudio(named: action.target, on: player.currentItem)
        default:
            onEvent?("trigger:unknownAction \(action.action)")
        }
    }

    private func selectAudio(named target: String?, on item: AVPlayerItem?) {
        guard let item,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) else {
            onEvent?("trigger:selectAudio missing audible group")
            return
        }
        let options = group.options
        let chosen: AVMediaSelectionOption?
        if let target, let index = Int(target), options.indices.contains(index) {
            chosen = options[index]
        } else if let target {
            chosen = options.first { Self.audioOption($0, matchesTarget: target) }
        } else {
            chosen = options.dropFirst().first ?? options.first
        }
        guard let chosen else {
            onEvent?("trigger:selectAudio no matching option")
            return
        }
        item.select(chosen, in: group)
        onEvent?("trigger:selectAudio chose \(chosen.displayName)")
    }
}
