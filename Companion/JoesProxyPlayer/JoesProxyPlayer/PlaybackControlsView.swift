//
//  PlaybackControlsView.swift
//  JoesProxyPlayer
//
/// Minimal streaming controls for JoePlayer Phase 0/1: URL entry, transport, audio selection,
/// certificate setup, and automatic trigger-plan / diagnostics attachment.
///

import AVFoundation
import Combine
import SwiftUI

/// Owns the `AVPlayer` session and wires diagnostics + trigger plans when a stream loads.
@MainActor
final class PlaybackSessionController: ObservableObject {
    let player = AVPlayer()
    let diagnostics = PlaybackDiagnosticsRecorder()
    let triggerRunner = TriggerPlanRunner()
    let pcmGlitchDetector = PCMGlitchDetector()

    @Published var streamURLString: String = ""
    @Published var statusText: String = "Idle"
    @Published var audioOptions: [String] = []
    @Published var selectedAudioIndex: Int = 0

    private var currentItem: AVPlayerItem?

    /// Loads `url`, attaches diagnostics, and arms a launch-argument trigger plan when present.
    func load(url: URL) {
        triggerRunner.stop()
        pcmGlitchDetector.detach()
        diagnostics.detach()
        let item = AVPlayerItem(url: url)
        currentItem = item
        player.replaceCurrentItem(with: item)
        diagnostics.attach(to: item, streamURL: url)
        refreshAudioOptions()

        if PCMGlitchDetectorLaunch.isEnabled() {
            let trigger = PCMGlitchDetectorLaunch.triggerTimeSeconds()
                ?? TriggerPlanRunner.planFromLaunchArguments()?
                .actions
                .first(where: { $0.action == "selectAudio" })?
                .atPlayerTimeSeconds
                ?? 0
            pcmGlitchDetector.attach(to: item, triggerPlayerTimeSeconds: trigger) { [weak self] kind, detail in
                self?.diagnostics.record(kind: kind, detail: detail)
            }
        }

        if let plan = TriggerPlanRunner.planFromLaunchArguments() {
            triggerRunner.start(plan: plan, player: player) { [weak self] message in
                self?.diagnostics.record(kind: "trigger", detail: message)
                self?.statusText = message
            }
            statusText = "Loaded with trigger plan (\(plan.actions.count) actions)"
        } else {
            statusText = "Loaded \(url.absoluteString)"
        }
    }

    func play() {
        player.play()
        statusText = "Playing"
    }

    func pause() {
        player.pause()
        statusText = "Paused"
    }

    func selectAudio(at index: Int) {
        guard let item = currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible),
              group.options.indices.contains(index) else {
            statusText = "Audio option unavailable"
            return
        }
        selectedAudioIndex = index
        item.select(group.options[index], in: group)
        diagnostics.record(kind: "manualAudioSelect", detail: group.options[index].displayName)
        statusText = "Audio: \(group.options[index].displayName)"
    }

    private func refreshAudioOptions() {
        guard let item = currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) else {
            audioOptions = []
            return
        }
        audioOptions = group.options.map(\.displayName)
        if let selected = item.selectedMediaOption(in: group),
           let index = group.options.firstIndex(of: selected) {
            selectedAudioIndex = index
        }
    }
}

/// Primary JoePlayer screen.
struct PlaybackControlsView: View {
    @StateObject private var session = PlaybackSessionController()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                PlayerView(player: session.player)
                    .frame(minHeight: 220)
                    .background(Color.black)
                    .accessibilityIdentifier("joePlayerVideoSurface")

                TextField("Fixture master.m3u8 URL", text: $session.streamURLString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("joePlayerStreamURLField")

                HStack {
                    Button("Load") { loadStream() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("joePlayerLoadButton")
                    Button("Play", action: session.play)
                        .accessibilityIdentifier("joePlayerPlayButton")
                    Button("Pause", action: session.pause)
                        .accessibilityIdentifier("joePlayerPauseButton")
                    Button("Cert Setup") {
                        _ = CertTrustSetup.present()
                    }
                    .accessibilityIdentifier("joePlayerCertSetupButton")
                }

                if !session.audioOptions.isEmpty {
                    Picker("Audio", selection: $session.selectedAudioIndex) {
                        ForEach(Array(session.audioOptions.enumerated()), id: \.offset) { index, name in
                            Text(name).tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: session.selectedAudioIndex) { _, newValue in
                        session.selectAudio(at: newValue)
                    }
                    .accessibilityIdentifier("joePlayerAudioPicker")
                }

                Text(session.statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("joePlayerStatusLabel")

                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("JoePlayer")
            .onAppear {
                if session.streamURLString.isEmpty,
                   let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--joeplayer-stream-url=") }) {
                    session.streamURLString = String(arg.dropFirst("--joeplayer-stream-url=".count))
                    loadStream()
                }
            }
        }
    }

    private func loadStream() {
        let trimmed = session.streamURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            session.statusText = "Invalid stream URL"
            return
        }
        session.load(url: url)
    }
}
