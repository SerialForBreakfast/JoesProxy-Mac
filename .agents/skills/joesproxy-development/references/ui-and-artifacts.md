# UI iteration and artifact verification

Revision: 2026-09-23. For screenshot work, first read the portable
ScreenshotsBestPractices.md (private development reference omitted).
This reference adds current repo-specific routing and export lessons; it grants no host control.

## Use the current harness, not the legacy shortcut

Run selected screenshot/UI cases through `host_ui_test.sh` after permission. The old
`grab_screenshot.sh` still invokes xcodebuild directly, selects the first PNG and deletes scratch
evidence. Do not use it unchanged. No new screenshot helper is implied by this skill.

Start with one visible question and a small state matrix: normal plus the affected boundary
(large text, error, loading or Compact round trip). Use synthetic fixtures and isolated storage.
Suppress unrelated restoration/first-run prompts, not the recovery behavior under test. Suppressed
prompts or disabled saves do not prove storage isolation: inspect reads, repair and spool setup too.

## Diagnose the first mismatch

- Scope accessibility queries to the owning window/container. Inspect identifier, type, label,
  value, frame and hittability before changing copy or broadening a selector. Displayed static text
  may be in AXValue rather than AXLabel; selection flags may not reflect app selection semantics.
- Wait for published state, not just the click or a fixed sleep. Window sizing may require actual
  AppKit attachment; settings links may require mounted content plus scrolling. Fix that lifecycle
  boundary rather than adding longer blind delays.
- Capture the window containing the intended stable element, not the first window or desktop.
  Verify source/product freshness before diagnosing identical variants as a layout bug.
- Assert user meaning, including progress/error preservation, disabled-action reasons and unchanged
  unrelated data. “Exists” alone is not acceptance. Check keyboard/VoiceOver separately from PNGs.

## Large-table interaction measurements

September 23 profiling exposed measurement interference: whole-app accessibility queries can
materialize large table cell hierarchies and stall the measured app. Scope keyboard-command
queries to the menu bar and selection queries to the visible viewport. Use the existing public
window-server geometry helper where available; do not replace it with private AppKit hooks.
For native macOS resizing, use the maintained mouse click-and-drag path, not a touch gesture.
Prove both expansion and shrink repeatedly in a short case before scheduling a long interaction
run. The repaired pilot passed but the hour's second shrink failed, so the resize harness is not
fully validated. Pointer travel alone is not evidence that window geometry changed.

Keep performance measurements separate from screenshot/AX inspection when possible. If automation
causes the failure, retain the failure and qualify affected phases; do not label it a product leak
or count unexecuted idle/drain phases as passed.

## Host-owned export evidence

For `VisualizationExportUITests/testVisualizationExportPNGHappyPathWritesFileWithoutSavePanel`,
the app writes the image, XCTest attaches a completion receipt, and the host wrapper exports the
matching receipts and runs `verify_visualization_export.sh`. It checks successful repetition count,
safe unique output names, file presence, PNG signature and actual decoding. A runner access denial
does not establish that the app failed to export; identify the failing process and operation first.
Do not respond by moving files to arbitrary directories or requesting broad disk permissions.

For other screenshots, select exported attachments by test identity, run/configuration and semantic
name using the result manifest. Never use directory order or “first PNG.” Preserve original bytes,
earlier rounds and failure evidence. Decoder success proves a readable image, not correct content:
open each delivered PNG and inspect the intended window/state, clipping, scale and legibility.

Record exact result/test/attachment identity, fixture, build, window dimensions, appearance/text
scale, reviewed PNG paths, process exit and cleanup. Keep artifacts in repo-owned locations and
sanitize shared metadata. Screenshots and generated mockups are distinct evidence categories.
Avoid expensive screenshot/AX probes in throughput comparisons; use a separate profiling lane.
