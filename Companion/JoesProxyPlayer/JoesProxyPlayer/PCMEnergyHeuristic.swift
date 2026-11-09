//
//  PCMEnergyHeuristic.swift
//  JoesProxyPlayer
//
/// Pure RMS-window heuristics for mute / glitch classification. Independent of
/// `AVPlayerItemSampleBufferOutput` so unit tests and future SDK attach share one algorithm.
///

import Foundation

/// One analyzed PCM energy window.
struct PCMEnergyWindow: Equatable, Sendable {
    /// Player timeline seconds for the window center (or start).
    let playerTimeSeconds: Double
    /// Root-mean-square amplitude in linear units (0...1 typical for normalized float PCM).
    let rms: Double
}

/// Classification emitted by Phase 3 PCM analysis.
enum PCMRenderClassification: String, Equatable, Sendable {
    case ok = "pcm_ok"
    case mute = "pcm_mute"
    case glitch = "pcm_glitch"
}

/// Tunable thresholds for v1 mute / glitch detection.
struct PCMEnergyHeuristicConfiguration: Equatable, Sendable {
    /// RMS at or below this value counts as near-silence.
    var muteFloorRMS: Double = 0.008
    /// Minimum consecutive silent windows to call mute.
    var muteMinConsecutiveWindows: Int = 4
    /// Minimum silent span in seconds to call mute.
    var muteMinDurationSeconds: Double = 0.08
    /// Adjacent-window RMS drop ratio (prev/current) that starts a glitch candidate.
    var glitchDropRatio: Double = 8.0
    /// Maximum near-silence span still treated as a glitch (shorter than mute).
    var glitchMaxGapSeconds: Double = 0.07
    /// Analysis focus around the audio-switch trigger (± seconds).
    var analysisRadiusSeconds: Double = 1.0

    static let `default` = PCMEnergyHeuristicConfiguration()
}

/// Classifies a sequence of RMS windows around a trigger time.
enum PCMEnergyHeuristic {
    /// Returns the strongest render defect found near `triggerPlayerTimeSeconds`, or `.ok`.
    ///
    /// Mute wins over glitch when both match. Windows outside the analysis radius are ignored.
    static func classify(
        windows: [PCMEnergyWindow],
        triggerPlayerTimeSeconds: Double,
        configuration: PCMEnergyHeuristicConfiguration = .default
    ) -> PCMRenderClassification {
        let radius = configuration.analysisRadiusSeconds
        let focused = windows
            .filter { abs($0.playerTimeSeconds - triggerPlayerTimeSeconds) <= radius }
            .sorted { $0.playerTimeSeconds < $1.playerTimeSeconds }

        guard focused.count >= 2 else { return .ok }

        if let mute = detectMute(in: focused, configuration: configuration) {
            return mute
        }
        if let glitch = detectGlitch(in: focused, configuration: configuration) {
            return glitch
        }
        return .ok
    }

    /// Computes RMS for interleaved float32 mono or stereo samples (uses first channel when stereo).
    static func rms(float32Samples: [Float], channelCount: Int) -> Double {
        let channels = max(channelCount, 1)
        guard !float32Samples.isEmpty else { return 0 }
        var sumSquares = 0.0
        var count = 0
        var index = 0
        while index < float32Samples.count {
            let sample = Double(float32Samples[index])
            sumSquares += sample * sample
            count += 1
            index += channels
        }
        guard count > 0 else { return 0 }
        return sqrt(sumSquares / Double(count))
    }

    private static func detectMute(
        in windows: [PCMEnergyWindow],
        configuration: PCMEnergyHeuristicConfiguration
    ) -> PCMRenderClassification? {
        var runStart: Int?
        for (index, window) in windows.enumerated() {
            if window.rms <= configuration.muteFloorRMS {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                if isMuteRun(windows[start..<index], configuration: configuration) {
                    return .mute
                }
                runStart = nil
            }
        }
        if let start = runStart,
           isMuteRun(windows[start..<windows.count], configuration: configuration) {
            return .mute
        }
        return nil
    }

    private static func isMuteRun(
        _ slice: ArraySlice<PCMEnergyWindow>,
        configuration: PCMEnergyHeuristicConfiguration
    ) -> Bool {
        guard slice.count >= configuration.muteMinConsecutiveWindows else { return false }
        guard let first = slice.first, let last = slice.last else { return false }
        let duration = max(0, last.playerTimeSeconds - first.playerTimeSeconds)
        return duration >= configuration.muteMinDurationSeconds
    }

    private static func detectGlitch(
        in windows: [PCMEnergyWindow],
        configuration: PCMEnergyHeuristicConfiguration
    ) -> PCMRenderClassification? {
        guard windows.count >= 3 else { return nil }
        for index in 1..<(windows.count - 1) {
            let previous = windows[index - 1]
            let current = windows[index]
            let next = windows[index + 1]
            guard previous.rms > configuration.muteFloorRMS * 2,
                  next.rms > configuration.muteFloorRMS * 2,
                  current.rms <= configuration.muteFloorRMS else {
                continue
            }
            let dropRatio = previous.rms / max(current.rms, 1e-9)
            let gap = max(0, next.playerTimeSeconds - previous.playerTimeSeconds)
            if dropRatio >= configuration.glitchDropRatio,
               gap <= configuration.glitchMaxGapSeconds {
                return .glitch
            }
        }
        return nil
    }
}
