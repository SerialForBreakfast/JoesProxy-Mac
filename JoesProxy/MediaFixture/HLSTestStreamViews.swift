import SwiftUI

struct HLSTestStreamSheetContext: Identifiable {
    let id = UUID()
    var session: SessionRecord?
}

struct HLSTestStreamSheet: View {
    @Environment(\.appTextScale) private var appTextScale

    let session: SessionRecord?
    let profiles: [HLSFixtureProfileDescriptor]
    let loadConflictSummary: (HLSSubstitutionOrigin, HLSSubstitutionScope) async -> HLSSubstitutionConflictSummary
    let onStart: (String, HLSSubstitutionOrigin, HLSSubstitutionScope, HLSSubstitutionConflictStrategy) -> Void
    let onCancel: () -> Void

    @State private var selectedProfileID: String
    @State private var useHostScope = false
    @State private var replaceConflicts = false
    @State private var scheme: SessionScheme
    @State private var host: String
    @State private var port: String
    @State private var playlistPath: String
    @State private var conflictSummary = HLSSubstitutionConflictSummary(experimentCount: 0, responseRuleCount: 0)

    init(
        session: SessionRecord?,
        profiles: [HLSFixtureProfileDescriptor],
        loadConflictSummary: @escaping (HLSSubstitutionOrigin, HLSSubstitutionScope) async -> HLSSubstitutionConflictSummary,
        onStart: @escaping (String, HLSSubstitutionOrigin, HLSSubstitutionScope, HLSSubstitutionConflictStrategy) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.session = session
        self.profiles = profiles
        self.loadConflictSummary = loadConflictSummary
        self.onStart = onStart
        self.onCancel = onCancel
        let recommended = profiles.first(where: \.isRecommended) ?? profiles.first
        _selectedProfileID = State(initialValue: recommended?.id ?? "")
        _scheme = State(initialValue: session?.request.scheme ?? .https)
        _host = State(initialValue: session?.request.host ?? "")
        _port = State(initialValue: session?.request.port.map(String.init) ?? "")
        _playlistPath = State(initialValue: session?.request.path ?? "")
    }

    private var selectedProfile: HLSFixtureProfileDescriptor? {
        profiles.first(where: { $0.id == selectedProfileID })
    }

    private var resolvedOrigin: HLSSubstitutionOrigin? {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else { return nil }
        let resolvedPort: Int?
        if port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedPort = nil
        } else {
            guard let parsed = Int(port), (1...65_535).contains(parsed) else { return nil }
            resolvedPort = parsed
        }
        return HLSSubstitutionOrigin(scheme: scheme, host: normalizedHost, port: resolvedPort)
    }

    private var canStart: Bool {
        guard !selectedProfileID.isEmpty, resolvedOrigin != nil else { return false }
        if useHostScope { return true }
        let path = String(playlistPath.split(separator: "?", maxSplits: 1).first ?? "")
        return path.lowercased().hasSuffix(".m3u8")
    }

    private var resolvedScope: HLSSubstitutionScope {
        useHostScope ? .host : .selectedPlaylist(path: playlistPath)
    }

    private var conflictLookupKey: String {
        "\(scheme.rawValue)|\(host)|\(port)|\(useHostScope)|\(playlistPath)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Replace with Test Stream")
                        .appFont(.title3, scale: appTextScale, weight: .semibold)
                    Text("Serve a bundled widescreen HLS stream without changing the player or upstream service.")
                        .appFont(.subheadline, scale: appTextScale)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView(.vertical) {
                configurationFields
                    .padding(2)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("hlsTestStreamConfigurationScroll")

            HStack {
                Label("Automatically stops after 30 minutes", systemImage: "clock")
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Start Test Stream") {
                    guard let origin = resolvedOrigin else { return }
                    onStart(
                        selectedProfileID,
                        origin,
                        resolvedScope,
                        replaceConflicts ? .replaceExisting : .cancel
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
                .accessibilityIdentifier("startHLSTestStreamButton")
            }
        }
        .padding(20)
        .frame(minWidth: 620, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hlsTestStreamSheet")
        .joesProxyResizableWorkspaceSheet(minWidth: 620, minHeight: 500)
        .task(id: conflictLookupKey) {
            guard let origin = resolvedOrigin else {
                conflictSummary = HLSSubstitutionConflictSummary(experimentCount: 0, responseRuleCount: 0)
                return
            }
            conflictSummary = await loadConflictSummary(origin, resolvedScope)
        }
    }

    private var configurationFields: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Test profile", selection: $selectedProfileID) {
                ForEach(profiles) { profile in
                    Text(profile.displayName).tag(profile.id)
                }
            }
            .accessibilityIdentifier("hlsTestStreamProfilePicker")

            if let selectedProfile {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selectedProfile.purpose)
                        .appFont(.subheadline, scale: appTextScale)
                    if let text = selectedProfile.textFixture {
                        Text("VOD default · Live via reviewed configuration · WebVTT · \(text.tracks.count) diagnostic text tracks")
                            .appFont(.caption, scale: appTextScale, weight: .semibold)
                            .accessibilityIdentifier("hlsTextTrackMode")
                        Text(text.tracks.map { "\($0.name) (\($0.role.rawValue))" }.joined(separator: " · "))
                            .appFont(.caption, scale: appTextScale)
                            .accessibilityIdentifier("hlsTextTrackLanguages")
                        Text("Translations are unreviewed diagnostic samples. Verify selection and visible cues in the player; proxy delivery alone cannot confirm rendering.")
                            .appFont(.caption, scale: appTextScale)
                    }
                    if !selectedProfile.renditions.isEmpty {
                        Text(selectedProfile.renditions.map { "\($0.width)×\($0.height)" }.joined(separator: "  •  "))
                            .appFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)
                    }
                    if let topology = selectedProfile.audioTopology {
                        Text("Audio topology: \(HLSAudioTopology(rawValue: topology)?.displayName ?? topology)")
                            .appFont(.caption, scale: appTextScale, weight: .medium)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("hlsTestStreamAudioTopology")
                    }
                    if let jit = selectedProfile.jitPublicationState {
                        Text("JIT publication: \(HLSJITPublicationState(rawValue: jit)?.displayName ?? jit)")
                            .appFont(.caption, scale: appTextScale, weight: .medium)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("hlsTestStreamJITState")
                    }
                    if let id3 = selectedProfile.id3Schedule {
                        Text("ID3 metadata: \(HLSID3Carrier(rawValue: id3.carrier)?.displayName ?? id3.carrier) (\(id3.events.count) events)")
                            .appFont(.caption, scale: appTextScale, weight: .medium)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("hlsTestStreamID3Schedule")
                    }
                    if let audioDescription = selectedProfile.audioDescription {
                        Text(audioDescription)
                            .appFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)
                    }
                    if let audioRenditions = selectedProfile.audioRenditions,
                       !audioRenditions.isEmpty {
                        Text(audioRenditions.map(\.name).joined(separator: "  •  "))
                            .appFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Audio renditions: \(audioRenditions.map(\.name).joined(separator: ", "))")
                            .accessibilityIdentifier("hlsTestStreamAudioRenditions")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            GroupBox("Target") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Scope", selection: $useHostScope) {
                        Text("Selected playlist").tag(false)
                        Text("All .m3u8 on host").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("hlsTestStreamScopePicker")

                    HStack {
                        Picker("Scheme", selection: $scheme) {
                            Text("HTTPS").tag(SessionScheme.https)
                            Text("HTTP").tag(SessionScheme.http)
                        }
                        .frame(width: 150)
                        TextField("Host", text: $host)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("hlsTestStreamHostField")
                        TextField("Port", text: $port)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .accessibilityIdentifier("hlsTestStreamPortField")
                    }
                    if !useHostScope {
                        TextField("/path/master.m3u8", text: $playlistPath)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Playlist path")
                            .accessibilityIdentifier("hlsTestStreamPlaylistPathField")
                    } else {
                        Text("Every GET or HEAD request ending in .m3u8 on this exact scheme, host, and port will receive the test-stream master. Subdomains are not included.")
                            .appFont(.caption, scale: appTextScale)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }

            Toggle("Replace overlapping local overrides", isOn: $replaceConflicts)
                .accessibilityHint("When enabled, JoesProxy disables overlapping response rules and stops overlapping HLS test streams before starting this one.")

            if conflictSummary.totalCount > 0 {
                Label(
                    "\(conflictSummary.totalCount) overlapping local override\(conflictSummary.totalCount == 1 ? "" : "s") detected",
                    systemImage: "exclamationmark.triangle"
                )
                .appFont(.caption, scale: appTextScale, weight: .semibold)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("hlsTestStreamConflictSummary")
            }

        }
    }
}

struct HLSTestStreamExperimentRow: View {
    @Environment(\.appTextScale) private var appTextScale
    let experiment: HLSSubstitutionExperiment
    let profile: HLSFixtureProfileDescriptor?
    let onStop: () -> Void
    let onRestart: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: experiment.isActive ? "play.rectangle.fill" : "stop.rectangle")
                .foregroundStyle(experiment.isActive ? .green : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile?.displayName ?? experiment.profileID)
                    .appFont(.body, scale: appTextScale, weight: .semibold)
                Text("\(experiment.scope.displayName) • \(experiment.origin.displayString)")
                    .appFont(.caption, scale: appTextScale)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: "Entry \(experiment.metrics.entryPlaylistHits)  Playlists \(experiment.metrics.childPlaylistHits)  Segments \(experiment.metrics.segmentHits)")
                    .appFont(.caption2, scale: appTextScale)
                    .foregroundStyle(.secondary)
                if let lastMatchedAt = experiment.metrics.lastMatchedAt {
                    Text("Last hit \(lastMatchedAt.formatted(date: .omitted, time: .standard))")
                        .appFont(.caption2, scale: appTextScale)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(statusLabel)
                .appFont(.caption, scale: appTextScale, weight: .semibold)
                .foregroundStyle(experiment.isActive ? .green : .secondary)
            if experiment.isActive {
                Button("Stop", action: onStop)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Stop HLS test stream")
                    .accessibilityIdentifier("stopHLSTestStreamButton")
            } else {
                Button("Restart", action: onRestart)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Restart HLS test stream")
                    .accessibilityIdentifier("restartHLSTestStreamButton")
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hlsTestStreamExperimentRow")
    }

    private var statusLabel: String {
        switch experiment.state {
        case .active:
            return experiment.metrics.totalHits == 0 ? "Waiting" : "Serving"
        case .stopped:
            return "Stopped"
        case .expired:
            return "Expired"
        }
    }
}
