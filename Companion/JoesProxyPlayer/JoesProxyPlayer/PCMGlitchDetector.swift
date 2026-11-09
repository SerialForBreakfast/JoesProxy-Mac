//
//  PCMGlitchDetector.swift
//  JoesProxyPlayer
//
/// Phase 3 PCM probe facade. Live `AVPlayerItemSampleBufferOutput` attach is gated on an SDK
/// that exposes the type to Swift (spike 2026-08-07: **not** visible on iPhoneSimulator 26.5).
/// Until that SDK lands, enabling the launch flag records `pcmAttachError` and still exercises
/// shared `PCMEnergyHeuristic` via unit tests / future attach.
///

import AVFoundation
import Foundation

/// Launch-argument and availability helpers for PCM glitch detection.
enum PCMGlitchDetectorLaunch {
    /// `--joeplayer-pcm-glitch-detect=1` enables Phase 3 probe attempts.
    static let flagPrefix = "--joeplayer-pcm-glitch-detect="

    /// Optional trigger time override: `--joeplayer-pcm-trigger-time=<seconds>`.
    static let triggerTimePrefix = "--joeplayer-pcm-trigger-time="

    /// Whether the process requested PCM detection.
    nonisolated static func isEnabled(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        guard let raw = arguments.first(where: { $0.hasPrefix(flagPrefix) }) else {
            return false
        }
        let value = String(raw.dropFirst(flagPrefix.count)).lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    /// Optional analysis center time from launch args.
    nonisolated static func triggerTimeSeconds(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Double? {
        guard let raw = arguments.first(where: { $0.hasPrefix(triggerTimePrefix) }) else {
            return nil
        }
        return Double(String(raw.dropFirst(triggerTimePrefix.count)))
    }
}

/// Attempts to attach a decoded-PCM probe to an `AVPlayerItem`.
///
/// Concurrency: create/use on the main actor. Pull loops (when SDK-backed attach exists) must run
/// off the main actor and hop back only to emit diagnostic events.
@MainActor
final class PCMGlitchDetector {
    /// Compile-time / spike result for this workspace Xcode: SampleBufferOutput is listed in the
    /// AVFoundation TBD but is **not** importable from Swift against iPhoneSimulator 26.5.
    /// Flip to `true` only after a successful compile reference in a future SDK spike.
    nonisolated static let sampleBufferOutputVisibleToSwiftSDK = false

    private var isAttached = false
    private var onEvent: ((String, String) -> Void)?

    /// Attaches the probe when enabled. Records `pcmAttachError` when the SDK cannot provide
    /// `AVPlayerItemSampleBufferOutput` (current gate).
    ///
    /// - Parameters:
    ///   - item: Active player item (reserved for future SampleBufferOutput addOutput).
    ///   - triggerPlayerTimeSeconds: Center of the analysis window (usually switch time).
    ///   - onEvent: Diagnostic sink (`kind`, `detail`) — typically `PlaybackDiagnosticsRecorder.record`.
    func attach(
        to item: AVPlayerItem,
        triggerPlayerTimeSeconds: Double,
        onEvent: @escaping (String, String) -> Void
    ) {
        detach()
        self.onEvent = onEvent
        _ = item

        guard Self.sampleBufferOutputVisibleToSwiftSDK else {
            onEvent(
                "pcmAttachError",
                "AVPlayerItemSampleBufferOutput not visible to Swift on this SDK (spike failed on iPhoneSimulator 26.5). Heuristics ready in PCMEnergyHeuristic; retry when iOS 27+ SDK exposes the type. trigger=\(triggerPlayerTimeSeconds)"
            )
            return
        }

        // Future: construct AVPlayerItemSampleBufferOutput, add to item, pull CMSampleBuffers,
        // convert to PCMEnergyWindow via PCMEnergyHeuristic.rms, classify near trigger, emit
        // pcmMute / pcmGlitch / pcmOk. Do not compile those symbols until the spike passes.
        onEvent("pcmAttachError", "SampleBufferOutput path not implemented despite availability flag")
    }

    /// Tears down any active probe.
    func detach() {
        isAttached = false
        onEvent = nil
    }

    /// Classifies precomputed windows (unit tests and future live pull loop).
    nonisolated static func classifyWindows(
        _ windows: [PCMEnergyWindow],
        triggerPlayerTimeSeconds: Double,
        configuration: PCMEnergyHeuristicConfiguration = .default
    ) -> PCMRenderClassification {
        PCMEnergyHeuristic.classify(
            windows: windows,
            triggerPlayerTimeSeconds: triggerPlayerTimeSeconds,
            configuration: configuration
        )
    }

    /// Maps a classification to a diagnostic event kind string.
    nonisolated static func diagnosticKind(for classification: PCMRenderClassification) -> String {
        switch classification {
        case .ok: return "pcmOk"
        case .mute: return "pcmMute"
        case .glitch: return "pcmGlitch"
        }
    }
}
