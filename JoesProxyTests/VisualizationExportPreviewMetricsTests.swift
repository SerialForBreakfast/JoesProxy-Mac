import XCTest
@testable import JoesProxy

/// Regression coverage for a sibling of the `SessionTimelineView` "bogus layer size" bug found
/// via a 44-minute Instruments capture (memlog/Instruments-Results/JoesProxyNotRendering). A
/// follow-up audit of every `GeometryReader`-driven size in the app found the export preview
/// pane's `scale = fitScale * zoomFactor` had a floor (`max(0.1, ...)`) but no ceiling. Export
/// dimensions are independently steppable 640...8,192 per axis with no aspect-ratio tie
/// (`VisualizationExportDimensions.isValid` only floors each axis), so an extreme custom aspect
/// ratio combined with an ordinary fit mode and zoom level can push the rendered width or height
/// well past CALayer/Metal's real backing-store limit, silently blanking the live preview the
/// same way the timeline went blank at high zoom.
final class VisualizationExportPreviewMetricsTests: XCTestCase {
    // MARK: - fitScale mode switch

    func testFitAllUsesTheSmallerOfWidthAndHeightScale() {
        let scale = VisualizationExportPreviewMetrics.fitScale(
            containerSize: CGSize(width: 800, height: 400),
            dimensions: VisualizationExportDimensions(preset: .custom, width: 1600, height: 400),
            fitMode: .fitAll
        )
        // widthScale = 0.5, heightScale = 1.0 — fitAll takes the smaller so nothing overflows.
        XCTAssertEqual(scale, 0.5, accuracy: 0.0001)
    }

    func testFitWidthIgnoresHeight() {
        let scale = VisualizationExportPreviewMetrics.fitScale(
            containerSize: CGSize(width: 800, height: 400),
            dimensions: VisualizationExportDimensions(preset: .custom, width: 1600, height: 400),
            fitMode: .fitWidth
        )
        XCTAssertEqual(scale, 0.5, accuracy: 0.0001)
    }

    func testFitHeightIgnoresWidth() {
        let scale = VisualizationExportPreviewMetrics.fitScale(
            containerSize: CGSize(width: 800, height: 400),
            dimensions: VisualizationExportDimensions(preset: .custom, width: 1600, height: 400),
            fitMode: .fitHeight
        )
        XCTAssertEqual(scale, 1.0, accuracy: 0.0001)
    }

    // MARK: - clampedScale ceiling

    func testClampedScaleNeverExceedsRenderableMaximumForExtremeWideAspectRatio() {
        // The concrete scenario the audit found: an 8192x360 custom export, Fit Height mode, a
        // modest preview pane and a couple of zoom-in clicks — reaches scale ~2-4, pushing
        // `width * scale` past 16,000pt if unclamped (8192 * 2 = 16,384; already over the limit).
        let dimensions = VisualizationExportDimensions(preset: .custom, width: 8_192, height: 360)
        let scale = VisualizationExportPreviewMetrics.clampedScale(
            containerSize: CGSize(width: 700, height: 600),
            dimensions: dimensions,
            fitMode: .fitHeight,
            zoomFactor: 1.5
        )
        XCTAssertLessThanOrEqual(
            CGFloat(dimensions.width) * scale,
            VisualizationExportPreviewMetrics.maxRenderableDimension
        )
        XCTAssertLessThanOrEqual(
            CGFloat(dimensions.height) * scale,
            VisualizationExportPreviewMetrics.maxRenderableDimension
        )
    }

    func testClampedScaleNeverExceedsRenderableMaximumForExtremeTallAspectRatioAndFitWidth() {
        // The symmetric case: a tall custom export (640x8192) with Fit Width mode pushes the
        // *height* past the limit instead of the width — the clamp must guard both axes, not just
        // whichever one the active fit mode targets.
        let dimensions = VisualizationExportDimensions(preset: .custom, width: 640, height: 8_192)
        let scale = VisualizationExportPreviewMetrics.clampedScale(
            containerSize: CGSize(width: 900, height: 600),
            dimensions: dimensions,
            fitMode: .fitWidth,
            zoomFactor: 1.5
        )
        XCTAssertLessThanOrEqual(
            CGFloat(dimensions.width) * scale,
            VisualizationExportPreviewMetrics.maxRenderableDimension
        )
        XCTAssertLessThanOrEqual(
            CGFloat(dimensions.height) * scale,
            VisualizationExportPreviewMetrics.maxRenderableDimension
        )
    }

    func testUnclampedMathWouldActuallyExceedTheLimitConfirmingTheScenarioIsReal() {
        // Sanity check that the two scenarios above are genuine triggers, not just tests that
        // pass vacuously because the inputs never threatened the limit in the first place.
        let dimensions = VisualizationExportDimensions(preset: .custom, width: 8_192, height: 360)
        let unclampedFit = VisualizationExportPreviewMetrics.fitScale(
            containerSize: CGSize(width: 700, height: 600),
            dimensions: dimensions,
            fitMode: .fitHeight
        )
        let unclampedScale = max(0.1, unclampedFit * 1.5)
        XCTAssertGreaterThan(
            CGFloat(dimensions.width) * unclampedScale,
            VisualizationExportPreviewMetrics.maxRenderableDimension,
            "This scenario must genuinely overflow pre-clamp, or the clamp test above proves nothing"
        )
    }

    // MARK: - clampedScale is inert below the limit

    func testClampedScaleUnaffectedByClampAtOrdinaryDimensionsAndZoom() {
        let dimensions = VisualizationExportDimensions.hd // 1920x1080
        let scale = VisualizationExportPreviewMetrics.clampedScale(
            containerSize: CGSize(width: 960, height: 540),
            dimensions: dimensions,
            fitMode: .fitAll,
            zoomFactor: 1.0
        )
        // fitAll at exactly half-size container with 1x zoom: scale should be the plain 0.5 fit
        // ratio, untouched by the (far larger) 16,000pt-derived limits.
        XCTAssertEqual(scale, 0.5, accuracy: 0.0001)
    }

    func testClampedScaleFloorStillAppliesBelowTheCeiling() {
        let dimensions = VisualizationExportDimensions.hd
        let scale = VisualizationExportPreviewMetrics.clampedScale(
            containerSize: CGSize(width: 10, height: 10),
            dimensions: dimensions,
            fitMode: .fitAll,
            zoomFactor: 0.15
        )
        XCTAssertEqual(scale, 0.1, accuracy: 0.0001, "Pre-existing floor must still win when nothing threatens the ceiling")
    }
}
