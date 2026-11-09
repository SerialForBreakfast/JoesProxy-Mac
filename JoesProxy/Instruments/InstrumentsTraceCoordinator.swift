import Foundation

actor InstrumentsTraceCoordinator {
    private let commandRunner: any InstrumentsCommandRunning
    private let xcrunURL: URL

    init(
        commandRunner: any InstrumentsCommandRunning = ProcessInstrumentsCommandRunner(),
        xcrunURL: URL = URL(fileURLWithPath: "/usr/bin/xcrun")
    ) {
        self.commandRunner = commandRunner
        self.xcrunURL = xcrunURL
    }

    func listTemplates() async throws -> [InstrumentsTemplate] {
        let result = try await commandRunner.run(
            executableURL: xcrunURL,
            arguments: ["xctrace", "list", "templates"]
        )

        guard result.exitCode == 0 else {
            return fallbackTemplates()
        }

        var templates: [InstrumentsTemplate] = []
        for line in result.standardOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("==") || trimmed.hasPrefix("Standard Templates:") {
                continue
            }
            templates.append(InstrumentsTemplate(name: trimmed, description: "Xcode Instruments template: \(trimmed)"))
        }

        return templates.isEmpty ? fallbackTemplates() : templates
    }

    func listDevices() async throws -> [InstrumentsTargetDevice] {
        let result = try await commandRunner.run(
            executableURL: xcrunURL,
            arguments: ["xctrace", "list", "devices"]
        )

        guard result.exitCode == 0 else {
            return [
                InstrumentsTargetDevice(name: "Booted Simulator", identifier: "booted", osVersion: "Current", isSimulator: true),
                InstrumentsTargetDevice(name: "Mac Host", identifier: "local", osVersion: "Current", isSimulator: false)
            ]
        }

        var devices: [InstrumentsTargetDevice] = []
        var inSimulatorsSection = false

        for line in result.standardOutput.split(separator: "\n") {
            let str = line.trimmingCharacters(in: .whitespaces)
            if str.contains("Simulator Devices:") {
                inSimulatorsSection = true
                continue
            }
            if str.isEmpty || str.hasPrefix("==") {
                continue
            }

            if str.contains("(") && str.contains(")") {
                let name = str.split(separator: "(").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? str
                let identifier = str.split(separator: "(").dropFirst().first?.split(separator: ")").first.map(String.init) ?? "unknown"
                devices.append(InstrumentsTargetDevice(
                    name: name,
                    identifier: identifier,
                    osVersion: "Standard",
                    isSimulator: inSimulatorsSection
                ))
            }
        }

        if devices.isEmpty {
            devices = [
                InstrumentsTargetDevice(name: "Booted Simulator", identifier: "booted", osVersion: "Current", isSimulator: true),
                InstrumentsTargetDevice(name: "Mac Host", identifier: "local", osVersion: "Current", isSimulator: false)
            ]
        }

        return devices
    }

    func recordTrace(config: InstrumentsTraceSessionConfig) async throws -> InstrumentsTraceSessionResult {
        let destinationURL = config.outputTraceURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("jp_trace_\(UUID().uuidString.prefix(8)).trace")

        var args = [
            "xctrace", "record",
            "--template", config.templateName,
            "--time-limit", "\(config.timeLimitSeconds)s",
            "--output", destinationURL.path
        ]

        if let device = config.targetDeviceIdentifier {
            args.append(contentsOf: ["--device", device])
        }

        if let process = config.targetProcess {
            args.append(contentsOf: ["--attach", process])
        } else if let bundle = config.targetBundleID {
            args.append(contentsOf: ["--attach", bundle])
        }

        let start = Date()
        let result = try await commandRunner.run(
            executableURL: xcrunURL,
            arguments: args
        )
        let elapsed = max(0.1, Date().timeIntervalSince(start))

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int) ?? 0

        return InstrumentsTraceSessionResult(
            traceURL: destinationURL,
            durationSeconds: elapsed,
            fileSizeBytes: fileSize,
            exitCode: result.exitCode
        )
    }

    func exportTableXML(traceURL: URL, xpath: String? = nil) async throws -> URL {
        let outputURL = traceURL.deletingPathExtension().appendingPathExtension("xml")
        var args = [
            "xctrace", "export",
            "--input", traceURL.path,
            "--output", outputURL.path
        ]
        if let xpath {
            args.append(contentsOf: ["--xpath", xpath])
        }

        let result = try await commandRunner.run(
            executableURL: xcrunURL,
            arguments: args
        )

        guard result.exitCode == 0 else {
            throw NSError(
                domain: "JoesProxy.Instruments",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: "Failed to export trace XML: \(result.standardError)"]
            )
        }

        return outputURL
    }

    private func fallbackTemplates() -> [InstrumentsTemplate] {
        [
            InstrumentsTemplate(name: "Time Profiler", description: "Low-overhead CPU profiling and call tree sampling"),
            InstrumentsTemplate(name: "Hangs / Hitches", description: "Main-thread UI responsiveness and user-perceivable hangs"),
            InstrumentsTemplate(name: "Allocations", description: "Heap allocations, memory growth, and lifetime tracking"),
            InstrumentsTemplate(name: "SwiftUI", description: "View body executions and view graph invalidation hotspots"),
            InstrumentsTemplate(name: "OSLog", description: "Subsystem log messages and signpost performance intervals"),
            InstrumentsTemplate(name: "System Trace", description: "Thread scheduling, context switches, and core utilization")
        ]
    }
}
