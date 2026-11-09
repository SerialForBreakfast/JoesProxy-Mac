//
//  JoesProxyCompanionApp.swift
//  JoesProxyCompanion
//
//  Created by Joseph McCraw on 6/28/26.
//

import SwiftUI

@main
struct JoesProxyCompanionApp: App {
    var body: some Scene {
        WindowGroup {
#if DEBUG
            if DiagnosticCaptureFixture.isEnabled {
                DiagnosticCaptureFixtureView()
            } else {
                ContentView()
            }
#else
            ContentView()
#endif
        }
    }
}
