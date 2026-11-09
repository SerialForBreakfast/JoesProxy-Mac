//
//  RecordingSheets.swift
//  JoesProxy
//
//  Modal sheets related to opening .jproxy recording files:
//  - RecordingOpenModeSheet: prompts whether to replace or merge existing sessions.
//  - SchemaVersionWarningSheet: warns when a recording uses a newer schema version.
//

import SwiftUI

/// A confirmation sheet presented when opening a `.jproxy` recording while sessions are present,
/// letting the user choose whether to replace or merge the existing sessions.
struct RecordingOpenModeSheet: View {
    let fileName: String
    let onReplace: () -> Void
    let onMerge: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.badge.arrow.up")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)

            Text("Open \"\(fileName)\"")
                .font(.headline)

            Text("You already have sessions loaded. Do you want to replace them with the sessions from this recording, or add them to the current list?")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add to Current") {
                    onMerge()
                }
                .keyboardShortcut("m", modifiers: [])

                Button("Replace") {
                    onReplace()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

/// Sheet presented when a recording's schema version is newer than the app supports.
/// Offers the user a choice between best-effort load and cancellation.
struct SchemaVersionWarningSheet: View {
    let fileVersion: Int
    let onLoadAnyway: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text("Newer Recording Format")
                .font(.headline)

            Text("This recording uses schema version \(fileVersion), which is newer than this version of JoesProxy supports. Loading may succeed with missing or incorrect data.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Load Anyway") {
                    onLoadAnyway()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
