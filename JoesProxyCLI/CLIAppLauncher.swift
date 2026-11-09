import AppKit
import Foundation

protocol CLIAppLaunching {
    func applicationURL() throws -> URL
    /// - Parameter launchArguments: Forwarded to `CommandLine.arguments` for a genuinely **cold**
    ///   launch only (e.g. `--compact-mode`). Has no effect if JoesProxy is already running — macOS
    ///   has no mechanism to inject new argv into an already-running process, so these are silently
    ///   ignored in that case rather than failing; the caller only needs a cold-launched instance to
    ///   see them.
    func requestMCPStart(launchArguments: [String]) async throws -> URL
}

extension CLIAppLaunching {
    func requestMCPStart() async throws -> URL {
        try await requestMCPStart(launchArguments: [])
    }
}

struct CLIWorkspaceAppLauncher: CLIAppLaunching {
    /// Production JoesProxy.app bundle ID — used when `Bundle(url:)` cannot read the target.
    static let joesProxyBundleIdentifier = "com.ShowBlender.JoesProxy"

    private let executableURL: URL

    init(executableURL: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])) {
        self.executableURL = executableURL
    }

    /// Starts JoesProxy (if needed) and asks it to start MCP via `joesproxy://automation/start-mcp`.
    ///
    /// Concurrency: must not combine cold launch and URL delivery in one `open(_:withApplicationAt:)`.
    /// SwiftUI creates a new `WindowGroup` window to receive `onOpenURL` when none exist yet, so a
    /// race with a just-started process produced two main windows in one PID (Cause 2).
    func requestMCPStart(launchArguments: [String] = []) async throws -> URL {
        let appURL = try applicationURL()
        guard let automationURL = URL(string: "joesproxy://automation/start-mcp") else {
            throw CLIError.internalFailure("The MCP automation URL is invalid.")
        }
        if !Self.isJoesProxyRunning(appURL: appURL) {
            try await launchApplication(at: appURL, arguments: launchArguments)
        }
        try await openAutomationURL(automationURL, appURL: appURL)
        return appURL
    }

    func applicationURL() throws -> URL {
        try Self.containingAppURL(for: executableURL)
    }

    static func containingAppURL(for executableURL: URL) throws -> URL {
        var candidate = executableURL.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension == "app" {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw CLIError.serverUnavailable(
            "joesproxyctl is not running from inside JoesProxy.app. Use the CLI bundled with the app."
        )
    }

    /// True when a JoesProxy.app process for `appURL`'s bundle ID is already running.
    static func isJoesProxyRunning(appURL: URL) -> Bool {
        let bundleID = Bundle(url: appURL)?.bundleIdentifier ?? joesProxyBundleIdentifier
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Cold-launches the app and waits until AppKit reports it running, without delivering a URL.
    /// `arguments` becomes the launched process's `CommandLine.arguments` (via
    /// `NSWorkspace.OpenConfiguration.arguments`) — only meaningful here because this is only
    /// called when the app isn't already running (see `requestMCPStart`); macOS has no way to
    /// inject new argv into an already-running process.
    private func launchApplication(at appURL: URL, arguments: [String]) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.arguments = arguments
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        } catch {
            throw CLIError.serverUnavailable(
                "Unable to launch JoesProxy: \(error.localizedDescription)"
            )
        }
    }

    /// Delivers the automation URL to an already-running (or just-launched) JoesProxy.app.
    private func openAutomationURL(_ automationURL: URL, appURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(
                [automationURL],
                withApplicationAt: appURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    continuation.resume(throwing: CLIError.serverUnavailable(
                        "Unable to launch JoesProxy: \(error.localizedDescription)"
                    ))
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
