//
//  StatefulMockManagerView.swift
//  JoesProxy
//
//  Main management panel for Stateful Virtual Backends, State Machine switching, and Presets.
//

import SwiftUI

struct StatefulMockManagerView: View {
    @ObservedObject var coordinator: StatefulMockCoordinator
    let onClose: () -> Void

    @State private var showingPresetSheet: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack {
                Image(systemName: "cpu.fill")
                    .foregroundColor(.accentColor)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Virtual State-Machine Backends")
                        .font(.headline)
                    Text("Generative in-memory backends with dynamic CRUD and lifecycle transitions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { showingPresetSheet = true }) {
                    Label("Add Preset", systemImage: "plus")
                }
                .buttonStyle(.bordered)

                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Main Split Content
            if coordinator.backends.isEmpty {
                emptyStateView
            } else {
                HSplitView {
                    // Left Sidebar: Installed Backends List
                    backendSidebar
                        .frame(minWidth: 200, maxWidth: 260)

                    // Right Detail: Selected Backend Controls
                    if let selected = coordinator.selectedBackend {
                        backendDetailView(backend: selected)
                    } else {
                        Text("Select a virtual backend.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .sheet(isPresented: $showingPresetSheet) {
            presetSelectionSheet
        }
    }

    // MARK: - Views

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No Virtual Backends Installed")
                .font(.headline)
            Text("Install a state-machine preset to start mocking dynamic flows like Auth, Shopping Carts, and Subscriptions.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button(action: { showingPresetSheet = true }) {
                Label("Install a Preset...", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var backendSidebar: some View {
        List(coordinator.backends, selection: Binding(
            get: { coordinator.selectedBackend?.id },
            set: { id in
                if let found = coordinator.backends.first(where: { $0.id == id }) {
                    coordinator.selectBackend(found)
                }
            }
        )) { backend in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(backend.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                }
                Text(backend.originHost)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Text("State: \(backend.activeState)")
                    .font(.caption2)
                    .foregroundColor(.blue)
            }
            .padding(.vertical, 4)
            .tag(backend.id)
        }
    }

    private func backendDetailView(backend: StatefulVirtualBackend) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header & Origin
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(backend.name)
                            .font(.title3)
                            .fontWeight(.bold)
                        Text("Origin: \(backend.originHost)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive, action: {
                        Task { await coordinator.removeBackend(id: backend.id) }
                    }) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                }

                Divider()

                // State Machine Switcher
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Active State Machine", systemImage: "point.3.filled.connected.trianglepath.dotted")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        Button("Reset State", action: {
                            Task { await coordinator.resetBackend(id: backend.id) }
                        })
                        .buttonStyle(.bordered)
                        .font(.caption)
                    }

                    Text("Click any state pill to force the virtual backend into that state instantly:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        ForEach(backend.possibleStates, id: \.self) { state in
                            Button(action: {
                                Task { await coordinator.setState(backendID: backend.id, state: state) }
                            }) {
                                HStack(spacing: 6) {
                                    if backend.activeState == state {
                                        Image(systemName: "checkmark.circle.fill")
                                    }
                                    Text(state)
                                }
                                .font(.caption)
                                .fontWeight(backend.activeState == state ? .bold : .regular)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(backend.activeState == state ? Color.green : Color.primary.opacity(0.08))
                                .foregroundColor(backend.activeState == state ? .white : .primary)
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(8)

                // In-Memory Collections Browser
                StatefulMockEntityBrowserView(backendID: backend.id, store: coordinator.store)

                // Transition Rules
                if !backend.transitionRules.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Transition Rules (\(backend.transitionRules.count))")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        ForEach(backend.transitionRules) { rule in
                            HStack {
                                Text("\(rule.method) \(rule.pathPattern)")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                Spacer()
                                Text("\(rule.fromState) → \(rule.toState)")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                            }
                            .padding(8)
                            .background(Color.primary.opacity(0.02))
                            .cornerRadius(6)
                        }
                    }
                }
            }
            .padding()
        }
    }

    private var presetSelectionSheet: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Select a State-Machine Preset")
                    .font(.headline)
                Spacer()
                Button("Cancel") { showingPresetSheet = false }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(StatefulMockPresets.allPresets) { preset in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(preset.title)
                                    .font(.subheadline)
                                    .fontWeight(.bold)
                                Spacer()
                                Button("Install Preset") {
                                    Task {
                                        await coordinator.installPreset(preset)
                                        showingPresetSheet = false
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .font(.caption)
                            }

                            Text(preset.summary)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text("Default Host: \(preset.defaultHost)")
                                .font(.caption2)
                                .foregroundColor(.primary.opacity(0.7))
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(8)
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 540, minHeight: 400)
    }
}
