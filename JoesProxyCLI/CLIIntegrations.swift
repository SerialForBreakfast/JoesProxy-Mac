import Foundation

/// Provides CLI companion integration guides, discovery, and reproducible recipe starters.
enum CLIIntegrations {
    struct CompanionInfo {
        let id: String
        let name: String
        let role: String
        let summary: String
        let synergy: String
        let status: String
        let docsCommand: String

        var dictionary: [String: Any] {
            [
                "id": id,
                "name": name,
                "role": role,
                "summary": summary,
                "synergy": synergy,
                "status": status,
                "docsCommand": docsCommand
            ]
        }
    }

    static let companions: [CompanionInfo] = [
        CompanionInfo(
            id: "tvtestrig",
            name: "TVTestRig",
            role: "Apple TV & Living-Room Automation",
            summary: "Remote device control, profile provisioning, playback navigation.",
            synergy: "Drives physical living-room clients while JoesProxy mutates wire traffic.",
            status: "Ready (Recipe templates available)",
            docsCommand: "joesproxyctl integrations show tvtestrig"
        ),
        CompanionInfo(
            id: "viewlens",
            name: "ViewLens",
            role: "ML-Backed Visual UI & Layout Analysis",
            summary: "Computer-vision element detection, bounding-box tracking, truncation audits.",
            synergy: "Detects visual clipping/truncation as JoesProxy sweeps API payload lengths.",
            status: "Ready (Recipe templates available)",
            docsCommand: "joesproxyctl integrations show viewlens"
        ),
        CompanionInfo(
            id: "instruments",
            name: "Xcode Instruments",
            role: "Native Host Profiling",
            summary: "CPU, memory, leak, and network trace automation via xctrace.",
            synergy: "Correlates host OS resource usage with live wire capture sessions.",
            status: "Built-in (joesproxyctl instruments)",
            docsCommand: "joesproxyctl integrations show instruments"
        )
    ]

    static var listMarkdown: String {
        var lines = [
            "Available JoesProxy Companion Integrations:",
            ""
        ]
        for (index, item) in companions.enumerated() {
            lines.append("\(index + 1). \(item.name) (\(item.role))")
            lines.append("   Role: \(item.summary)")
            lines.append("   Synergy: \(item.synergy)")
            lines.append("   Status: \(item.status)")
            lines.append("   Docs: \(item.docsCommand)")
            lines.append("")
        }
        lines.append("Use `joesproxyctl integrations show <name>` for detailed workflow guidance.")
        lines.append("Use `joesproxyctl integrations recipe truncation-audit` for an automated audit starter script.")
        return lines.joined(separator: "\n")
    }

    static func show(name: String) throws -> (markdown: String, json: [String: Any]) {
        let key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch key {
        case "tvtestrig":
            let md = """
            # TVTestRig Companion Integration Guide

            ## Role
            Automates physical Apple TV and living-room device testing, profile provisioning, and playback navigation.

            ## Synergy with JoesProxy
            - TVTestRig provisions the Apple TV with the JoesProxy root CA certificate and configures HTTP proxy settings.
            - JoesProxy intercepts network traffic from the device's IP, records all network sessions, and injects controlled mutations (throttling, response rewrites, synthetic assets).
            - TVTestRig executes remote navigation commands (play, pause, seek, menu) while JoesProxy verifies or conditions network responses.

            ## Operational Workflow
            1. Start JoesProxy on the host Mac and obtain proxy port and certificate URL (`http://<mac-ip>:9090/joesproxy.crt`).
            2. TVTestRig provisions Apple TV with JoesProxy CA profile and sets HTTP proxy.
            3. Apply conditioning: `joesproxyctl throttle prepare --preset-id mobile-3g`.
            4. TVTestRig sends remote commands to launch the target app and play media.
            5. JoesProxy inspects captured sessions and verifies stream playback or fault behavior.
            """
            return (md, [
                "integration": "tvtestrig",
                "name": "TVTestRig",
                "guide": md,
                "status": "ready"
            ])

        case "viewlens":
            let md = """
            # ViewLens Companion Integration Guide

            ## Role
            Computer-vision UI element detection, bounding box extraction, and text truncation/overflow auditing.

            ## Synergy with JoesProxy
            - JoesProxy systematically modifies API responses (using map-local or edit preview) to inject variable-length text into targeted schema fields.
            - ViewLens captures the rendered screen, locates UI text elements via ML models, and detects truncation ellipsis (...) or bounding-box clipping.

            ## Step-Sweep Algorithm
            1. Identify target API endpoint and string field (e.g. headline, title, channel name).
            2. Sweep test string lengths: [10, 25, 50, 75, 100, 150, 200] characters.
            3. JoesProxy injects synthetic strings of each length via response rewrite or map-local.
            4. Client fetches the updated response and renders the UI.
            5. ViewLens detects element bounding boxes and checks for text truncation or layout collisions.
            6. Calculate the maximum safe string length supported by the design.
            """
            return (md, [
                "integration": "viewlens",
                "name": "ViewLens",
                "guide": md,
                "status": "ready"
            ])

        case "instruments":
            let md = """
            # Xcode Instruments Companion Integration Guide

            ## Role
            Native macOS host profiling via xctrace templates (Time Profiler, Allocations, Leaks).

            ## Synergy with JoesProxy
            - JoesProxy coordinates host trace recording with capture markers.
            - Correlate memory spikes and CPU usage with specific high-throughput network capture sessions.
            """
            return (md, [
                "integration": "instruments",
                "name": "Xcode Instruments",
                "guide": md,
                "status": "built-in"
            ])

        default:
            throw CLIError.invalidArguments("Unknown companion integration '\(name)'. Available: tvtestrig, viewlens, instruments.")
        }
    }

    static func recipe(kind: String, targetURL: String?, field: String?) throws -> (markdown: String, json: [String: Any]) {
        let normalizedKind = kind.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedKind == "truncation-audit" else {
            throw CLIError.invalidArguments("Unknown recipe '\(kind)'. Available: truncation-audit.")
        }

        let url = targetURL ?? "https://api.example.invalid/items"
        let targetField = field ?? "title"
        let lengths = [10, 25, 50, 75, 100, 150, 200]

        let scriptStarter = """
        #!/usr/bin/env bash
        set -euo pipefail

        # Truncation Audit Starter: JoesProxy + ViewLens
        # Target URL: \(url)
        # Target Field: \(targetField)

        LENGTHS=(\(lengths.map(String.init).joined(separator: " ")))

        echo "==> Starting API-to-UI Truncation Audit..."
        for len in "${LENGTHS[@]}"; do
            echo "--- Testing string length: $len chars ---"
            # 1. JoesProxy applies synthetic string rewrite
            # joesproxyctl response rewrite preview --target-url "\(url)" ...
            # 2. Trigger client reload or navigation
            # 3. ViewLens captures screen and asserts:
            # viewlens assert --no-truncation --field "\(targetField)"
        done
        echo "==> Truncation audit sweep completed."
        """

        let md = """
        # Truncation Audit Recipe (JoesProxy + ViewLens)

        Target URL: `\(url)`
        Target Field: `\(targetField)`
        Test Lengths: \(lengths.map(String.init).joined(separator: ", "))

        ## Workflow
        1. **Baseline Capture:** Intercept `\(url)` in JoesProxy and verify response schema.
        2. **Length Sweep:** Systematically inject test strings of increasing lengths.
        3. **Visual Verification:** Trigger ViewLens screen analysis to locate the UI element and verify absence of ellipsis (`...`) or bounding-box overflow.
        4. **Threshold Calculation:** Identify the maximum character limit before visual truncation.

        ## Starter Script
        ```bash
        \(scriptStarter)
        ```
        """

        let jsonPayload: [String: Any] = [
            "recipe": "truncation-audit",
            "version": 1,
            "targetURL": url,
            "targetField": targetField,
            "testLengths": lengths,
            "scriptStarter": scriptStarter,
            "guide": md
        ]

        return (md, jsonPayload)
    }

    static func execute(invocation: CLIInvocation) throws -> CLIResultEnvelope {
        let commandName = invocation.command.joined(separator: " ")
        if invocation.command == ["integrations"] || invocation.command == ["integrations", "list"] {
            let payload: [String: Any] = [
                "integrations": companions.map(\.dictionary),
                "markdown": listMarkdown
            ]
            return CLIResultEnvelope(command: commandName, success: true, result: payload, warnings: [])
        }
        if invocation.command.count >= 2 && invocation.command[1] == "show" {
            guard invocation.command.count == 3 else {
                throw CLIError.invalidArguments("Specify an integration to show. Available: tvtestrig, viewlens, instruments.")
            }
            let name = invocation.command[2]
            let res = try show(name: name)
            var dict: [String: Any] = res.json
            dict["markdown"] = res.markdown
            return CLIResultEnvelope(command: commandName, success: true, result: dict, warnings: [])
        }
        if invocation.command.count >= 2 && invocation.command[1] == "recipe" {
            guard invocation.command.count == 3 else {
                throw CLIError.invalidArguments("Specify a recipe to generate. Available: truncation-audit.")
            }
            let kind = invocation.command[2]
            let res = try recipe(kind: kind, targetURL: invocation.options["target-url"], field: invocation.options["field"])
            var dict: [String: Any] = res.json
            dict["markdown"] = res.markdown
            return CLIResultEnvelope(command: commandName, success: true, result: dict, warnings: [])
        }
        let sub = invocation.command.count > 1 ? invocation.command[1] : ""
        throw CLIError.invalidArguments("Unknown integrations subcommand '\(sub)'. Available: list, show, recipe.")
    }
}
