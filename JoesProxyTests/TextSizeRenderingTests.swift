import AppKit
import SwiftUI
import XCTest
@testable import JoesProxy

@MainActor
final class TextSizeRenderingTests: XCTestCase {
    func testHealthMetricGlyphsFollowAppTextSize() {
        func measuredSize(_ size: AppTextSize) -> CGSize {
            let host = NSHostingView(rootView: HealthMetricIndicator(
                systemImage: "memorychip", value: "128 MB", level: .safe
            ).environment(\.appTextScale, size.fontScale))
            return host.fittingSize
        }
        let small = measuredSize(.small)
        let standard = measuredSize(.standard)
        let accessibility = measuredSize(.accessibility)
        XCTAssertGreaterThan(standard.width, small.width)
        XCTAssertGreaterThan(accessibility.width, standard.width + 5)
        XCTAssertGreaterThan(accessibility.height, standard.height + 2)
    }
}
