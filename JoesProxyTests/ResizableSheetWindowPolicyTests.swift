import AppKit
import XCTest
@testable import JoesProxy

/// Verifies workspace-sheet resizability policy without constructing live `NSWindow` instances.
///
/// Creating real windows in the unit-test host can crash; these tests cover the pure configuration
/// that ``ResizableSheetWindowPolicy/configure(_:minSize:)`` applies to sheet hosts.
final class ResizableSheetWindowPolicyTests: XCTestCase {
    func testConfigurationInsertsResizableWhilePreservingExistingStyleBits() {
        let existing: NSWindow.StyleMask = [.titled, .closable]
        let resolved = ResizableSheetWindowPolicy.configuration(
            from: existing,
            minSize: NSSize(width: 760, height: 520)
        )

        XCTAssertTrue(resolved.styleMask.contains(.resizable))
        XCTAssertTrue(resolved.styleMask.contains(.titled))
        XCTAssertTrue(resolved.styleMask.contains(.closable))
        XCTAssertFalse(existing.contains(.resizable))
    }

    func testConfigurationPreservesCallerMinimumSize() {
        let minSize = NSSize(width: 700, height: 620)
        let resolved = ResizableSheetWindowPolicy.configuration(
            from: [.titled],
            minSize: minSize
        )

        XCTAssertEqual(resolved.minSize.width, minSize.width, accuracy: 0.001)
        XCTAssertEqual(resolved.minSize.height, minSize.height, accuracy: 0.001)
    }

    func testConfigurationIsIdempotentWhenResizableAlreadyPresent() {
        let existing: NSWindow.StyleMask = [.titled, .resizable, .closable]
        let first = ResizableSheetWindowPolicy.configuration(
            from: existing,
            minSize: NSSize(width: 560, height: 420)
        )
        let second = ResizableSheetWindowPolicy.configuration(
            from: first.styleMask,
            minSize: NSSize(width: 680, height: 620)
        )

        XCTAssertTrue(first.styleMask.contains(.resizable))
        XCTAssertTrue(second.styleMask.contains(.resizable))
        XCTAssertEqual(second.minSize.width, 680, accuracy: 0.001)
        XCTAssertEqual(second.minSize.height, 620, accuracy: 0.001)
    }
}
