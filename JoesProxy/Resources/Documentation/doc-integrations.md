# Companion Integrations

## Overview {#overview}

JoesProxy is designed as an independent, deterministic authority on wire truth—it observes, decrypts, records, throttles, and mutates HTTP/HTTPS traffic at the network boundary.

In end-to-end automated testing and debugging, network observations alone cannot answer every question:
- Wire truth confirms that an API payload was rewritten or delivered, but cannot observe whether the target client rendered it cleanly or clipped text.
- Living-room client testing (such as on an Apple TV) often requires remote-control navigation under varying network conditions.
- API strings frequently expand in production, silently causing UI text truncation or layout collisions.

JoesProxy connects with specialized companion tools without runtime coupling:
- TVTestRig: Physical Apple TV and living-room device control (profile provisioning, proxy configuration, remote navigation).
- ViewLens: ML-backed computer vision detecting visual UI elements, bounding boxes, truncation ellipsis, and layout clipping.
- Instruments: macOS native host profiling correlating system resources with live proxy sessions.

## TVTestRig Living Room Automation {#tvtestrig}

TVTestRig controls physical Apple TVs and living-room clients for automated testing, navigation, and UI validation.

Synergy:
- TVTestRig provisions the Apple TV with the JoesProxy root CA certificate and configures the HTTP proxy setting to point to JoesProxy's LAN IP and port.
- JoesProxy intercepts network traffic from the device's IP, records all network sessions, and injects controlled mutations (e.g. throttling, JSON rewrites, synthetic responses).
- TVTestRig executes remote-control button sequences (play, pause, navigate) while JoesProxy verifies or conditions network responses.

Workflow:
1. Identify JoesProxy LAN listening port and CA certificate URL (`http://<mac-ip>:9090/joesproxy.crt`).
2. Provision Apple TV via TVTestRig profile or configuration tooling.
3. Apply targeted JoesProxy conditioning: `joesproxyctl throttle prepare --preset-id mobile-3g`.
4. Command Apple TV via TVTestRig to launch the target app and start playback.
5. Inspect captured sessions via `joesproxyctl sessions tail` or `joesproxyctl media inspect`.

## ViewLens API Truncation Audits {#viewlens}

ViewLens provides ML-backed visual UI element detection, bounding box extraction, and visual anomaly analysis (detecting clipped text, truncation ellipsis `...`, and visual overflow).

Synergy:
- JoesProxy uses `response map-local` or `response edit` to systematically inject variable-length text into targeted API fields.
- ViewLens inspects screen captures of the rendered UI, extracts bounding boxes for the target text labels, and detects whether truncation or layout overflow occurred.

Step-Sweep Algorithm:
1. Target API field: Select an endpoint (e.g. catalog or metadata endpoint) and target field (e.g. headline, title, description).
2. Length sweep: Step through string lengths (e.g. 10, 25, 50, 75, 100, 150, 200 characters).
3. Apply rewrite: JoesProxy modifies the response payload with synthetic test strings.
4. Render & Capture: Client fetches the response and updates the screen.
5. Visual assertion: ViewLens inspects the bounding box to detect truncation or overflow.
6. Calculate Safe Threshold: Identify maximum character count before truncation occurs.

## Closed-Loop Triangulation Pipeline {#pipeline}

Combining TVTestRig, JoesProxy, and ViewLens creates a closed-loop, unattended automated test pipeline:

1. Device Navigation (TVTestRig): Navigates the Apple TV client to the target view.
2. Network Mutation (JoesProxy): Injects synthetic data, variable-length text, or fault conditions.
3. Visual Verification (ViewLens): Verifies rendering, checks for missing art or text truncation, and outputs visual receipts.
4. Corroborated Evidence: Combines wire truth (JoesProxy capture receipts) with visual truth (ViewLens bounding boxes) and device truth (TVTestRig action logs).

## Recipes and Script Starters {#recipes}

Starter templates can be generated using `joesproxyctl integrations recipe`:

```bash
# Generate truncation audit script
joesproxyctl integrations recipe truncation-audit --target-url "https://api.example.invalid/items" --field "title"

# View integration architectural guidance
joesproxyctl integrations show tvtestrig
joesproxyctl integrations show viewlens
```

All recipes output portable shell/JSON structures that run without modifying JoesProxy core dependencies.

## Invariants and Safety {#safety}

Integrations with companion tools adhere to strict safety boundaries:
1. Zero External Runtime Coupling: JoesProxy never links to TVTestRig or ViewLens binaries, frameworks, or CoreML models.
2. Distinct Truth Domains: Wire truth belongs to JoesProxy; device truth belongs to TVTestRig; visual truth belongs to ViewLens.
3. Redaction and Privacy: Integration guides use synthetic domains (`.example.invalid`) and sanitized example payloads.
4. Tri-State Outcomes: External visual assertions must report tri-state results (`passed`, `failed`, or `unavailable`).
