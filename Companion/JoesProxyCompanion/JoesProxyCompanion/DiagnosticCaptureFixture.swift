#if DEBUG
import Foundation
import OSLog
import SwiftUI

enum DiagnosticCaptureFixture {
    static let launchArgument = "--diagnostic-capture-fixture"
    static let runID = "phase0-capture-v1"
    static let subsystem = "com.ShowBlender.JoesProxyCompanion.DiagnosticCaptureFixture"
    static let privateProbe = "JP_DIAG_PRIVATE_PROBE_7F3A9C"
    static let sensitiveProbe = "JP_DIAG_SENSITIVE_PROBE_91C2E4"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    @MainActor
    static func run(stageDidChange: (Int) -> Void) async {
        for stage in 1...3 {
            if stage > 1 {
                try? await Task.sleep(for: .seconds(2))
            }
            emit(stage: stage)
            stageDidChange(stage)
        }
    }

    private static func emit(stage: Int) {
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wallTime = timestampFormatter.string(from: Date())
        let publicProbe = "JP_DIAG_PUBLIC_STAGE_\(stage)"
        let prefix = "JP_DIAG_FIXTURE run=\(runID) stage=\(stage) wall=\(wallTime)"

        print("\(prefix) channel=print public=\(publicProbe)")
        write("\(prefix) channel=stdout public=\(publicProbe)\n", to: .standardOutput)
        write("\(prefix) channel=stderr public=\(publicProbe)\n", to: .standardError)

        logger.notice(
            "JP_DIAG_FIXTURE run=\(runID, privacy: .public) stage=\(stage, privacy: .public) wall=\(wallTime, privacy: .public) channel=logger public=\(publicProbe, privacy: .public) private=\(privateProbe, privacy: .private) sensitive=\(sensitiveProbe, privacy: .sensitive)"
        )

        let interval = signposter.beginInterval("DiagnosticCaptureFixture.stage")
        signposter.emitEvent("DiagnosticCaptureFixture.event")
        signposter.endInterval("DiagnosticCaptureFixture.stage", interval)

        if stage == 2 {
            let longPayload = String(repeating: "L", count: 2_048)
            print("\(prefix) channel=print-long declaredLength=2048 begin=BEGIN_\(longPayload)_END end=END")
            logger.notice(
                "JP_DIAG_FIXTURE run=\(runID, privacy: .public) stage=2 channel=logger-long declaredLength=2048 begin=BEGIN_\(longPayload, privacy: .public)_END end=END"
            )
        }
    }

    private static func write(_ value: String, to handle: FileHandle) {
        guard let data = value.data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }

    private static let logger = Logger(subsystem: subsystem, category: "Capture")
    private static let signposter = OSSignposter(subsystem: subsystem, category: "Signpost")
}

struct DiagnosticCaptureFixtureView: View {
    @State private var stage = 0

    var body: some View {
        VStack(spacing: 12) {
            Text("Diagnostic Capture Fixture")
                .font(.headline)
            Text(statusText)
                .accessibilityIdentifier("diagnosticCaptureFixtureStatus")
        }
        .task {
            await DiagnosticCaptureFixture.run { emittedStage in
                stage = emittedStage
            }
        }
    }

    private var statusText: String {
        stage == 3 ? "Diagnostic capture fixture complete" : "Diagnostic capture fixture stage \(stage)"
    }
}
#endif
