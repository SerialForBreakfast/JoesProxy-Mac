//
//  JoesProxyPlayerApp.swift
//  JoesProxyPlayer
//
/// Diagnostic HLS companion player used with JoesProxy fixture hosts and capture.
///

import SwiftUI

@main
struct JoesProxyPlayerApp: App {
    var body: some Scene {
        WindowGroup {
            PlaybackControlsView()
        }
    }
}
