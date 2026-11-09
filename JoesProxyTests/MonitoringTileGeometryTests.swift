import AppKit
import SwiftUI
import XCTest
@testable import JoesProxy

@MainActor
final class MonitoringTileGeometryTests: XCTestCase {
    func testRefreshingValuesDoesNotChangeGridFittingSize() {
        func tiles(_ value: String) -> [MonitoringTileDescriptor] {
            (0..<8).map {
                MonitoringTileDescriptor(id: String($0), label: "Connections",
                    systemImage: "cable.connector", value: value, level: .safe)
            }
        }
        // Detached hosting view: exercise SwiftUI measurement without opening a host window.
        let host = NSHostingView(rootView: MonitoringTileGrid(tiles: tiles("—")))
        let baseline = host.fittingSize
        XCTAssertGreaterThan(baseline.height, 200)
        for value in ["0", "1", "888", "9,999", "1.2/min", "—", "100h59m", "Capturing"] {
            host.rootView = MonitoringTileGrid(tiles: tiles(value))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize, baseline, "Value \(value) changed the HUD grid size")
        }
    }
}
