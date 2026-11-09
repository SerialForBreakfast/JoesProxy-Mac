import Foundation

/// Authenticated MCP prompt teaching ecosystem companion tool force-multipliers.
enum MCPIntegrationsPrompt {
    static let name = "joesproxy_integrations"
    static let description = "Ecosystem companion tool force-multipliers: TVTestRig (Apple TV living-room automation) and ViewLens (ML visual UI truncation audits)."

    static var body: String {
        """
        # JoesProxy Companion Integrations (Ecosystem Force-Multipliers)

        JoesProxy operates as an authoritative, deterministic boundary on **wire truth**—capturing,
        decrypting, throttling, and mutating HTTP/HTTPS traffic. Companion tools act as force-multipliers
        by connecting wire truth to device navigation and visual rendering without runtime coupling.

        ## Companion Tools and Roles

        1. **TVTestRig (Device Truth):** Controls physical Apple TVs and living-room devices.
           - Provisions root CA profiles and Wi-Fi proxy settings pointing to JoesProxy.
           - Automates remote D-pad navigation, media playback triggers, and app launches.
           - Pairs with JoesProxy network conditioning (e.g. 3G throttling, 503 fault injection).

        2. **ViewLens (Visual Truth):** ML-backed computer vision and UI layout analysis.
           - Locates UI text elements, labels, and bounding boxes from screen captures.
           - Detects truncation ellipsis (`...`), text clipping, and visual layout overflow.
           - Pairs with JoesProxy response rewrites to audit API string length limits.

        3. **Xcode Instruments (System Truth):** Native macOS resource profiling.
           - Automates `xctrace` runs (Time Profiler, Allocations, Leaks).
           - Correlates CPU/memory pressure with live proxy capture sessions.

        ## Archetype 1: Living-Room Automation (TVTestRig + JoesProxy)

        Automate playback validation under degraded network conditions on physical Apple TVs:
        1. Obtain JoesProxy LAN host IP and CA certificate: `http://<mac-ip>:9090/joesproxy.crt`.
        2. TVTestRig provisions the Apple TV configuration profile pointing HTTP proxy to JoesProxy.
        3. Prepare network conditioning: `joesproxyctl throttle prepare --preset-id mobile-3g`.
        4. TVTestRig commands the device to launch the target client and trigger video playback.
        5. Verify rendition step-down via `joesproxyctl sessions search --domain example.invalid`
           while TVTestRig verifies playback state.

        ## Archetype 2: Closed-Loop API Truncation Audit (ViewLens + JoesProxy)

        Determine the exact maximum string length supported by a UI container before truncation occurs:
        1. Select target API endpoint and JSON field (e.g. `$.items[0].headline`).
        2. Execute step-sweep across lengths: `[10, 25, 50, 75, 100, 150, 200]`.
        3. For each length, JoesProxy injects synthetic string: `joesproxyctl response rewrite preview`.
        4. Target client fetches mutated response and renders the view.
        5. ViewLens inspects screen capture, extracts bounding box, and checks `is_truncated`.
        6. Compute the safe threshold and report actionable design/API recommendations.

        ## Archetype 3: Full Triangulation Pipeline

        Orchestrate all three layers in an unattended test harness:
        - **Step 1 (TVTestRig):** Navigate device to catalog grid.
        - **Step 2 (JoesProxy):** Inject candidate payload with variable lengths or missing art.
        - **Step 3 (ViewLens):** Capture screen and verify layout integrity and absence of clipping.
        - **Step 4 (Corroborated Report):** Correlate wire receipts with visual assertions.

        ## Safety and Architectural Invariants

        1. **Strict Independence:** Zero binary or framework linkage between JoesProxy, TVTestRig,
           and ViewLens. Communication occurs via standard CLI, JSON manifests, and MCP.
        2. **Truth Domain Separation:** Wire truth belongs to JoesProxy; device truth belongs to
           TVTestRig; visual truth belongs to ViewLens.
        3. **Tri-State Assertions:** External visual assertions must report tri-state outcomes:
           `passed`, `failed`, or `unavailable`. Never treat missing visual data as success.
        4. **Synthetic Scope:** Use `.example.invalid` domains and sanitized payloads in playbooks.
        """
    }
}
