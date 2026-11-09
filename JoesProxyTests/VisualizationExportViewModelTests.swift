import XCTest
@testable import JoesProxy

@MainActor
final class VisualizationExportViewModelTests: XCTestCase {
    func testDefaultsToSessionTimelineForSelectedSessionScope() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let viewModel = VisualizationExportViewModel(
            context: VisualizationExportPresentationContext(
                sourceScope: .selectedSession(sessionID),
                sourceSummary: "1 selected session",
                sessionCount: 1,
                filteredSessionCount: 3,
                totalSessionCount: 10,
                hasActiveFilters: true,
                sourceSessions: [makeSession(id: sessionID)]
            )
        )

        XCTAssertEqual(viewModel.selectedExportType, .sessionTimeline)
        XCTAssertEqual(viewModel.request.sourceScope, .selectedSession(sessionID))
        XCTAssertEqual(viewModel.request.title, "Session Timeline")
        XCTAssertEqual(viewModel.request.subtitle, "1 selected session")
        XCTAssertEqual(viewModel.validationIssues, [])
        XCTAssertTrue(viewModel.canExportPNG)
        XCTAssertNotNil(viewModel.renderModel)
    }

    func testDefaultsToHostHealthForFilteredResultsScope() {
        let filter = VisualizationExportFilterDescriptor(searchText: "cdn", hosts: ["video.example.com"])
        let sessions = [
            makeSession(host: "video.example.com"),
            makeSession(host: "video.example.com", statusCode: 500)
        ]
        let viewModel = VisualizationExportViewModel(
            context: VisualizationExportPresentationContext(
                sourceScope: .filteredResults(filter),
                sourceSummary: "Current filtered results",
                sessionCount: 4,
                filteredSessionCount: 4,
                totalSessionCount: 12,
                hasActiveFilters: true,
                sourceSessions: sessions
            )
        )

        XCTAssertEqual(viewModel.selectedExportType, .hostHealthSummary)
        XCTAssertEqual(viewModel.request.sourceScope, .filteredResults(filter))
        XCTAssertEqual(viewModel.request.title, "Host Health Summary")
        XCTAssertEqual(viewModel.validationIssues, [])
        XCTAssertTrue(viewModel.canExportPNG)
        XCTAssertEqual(viewModel.exportUnavailableMessage, "Export PNG")
        guard case .hostHealthSummary = viewModel.renderModel else {
            return XCTFail("Expected host health render model")
        }
    }

    func testChangingSharedOptionsUpdatesRequestDraft() {
        let viewModel = VisualizationExportViewModel(
            context: VisualizationExportPresentationContext(
                sourceScope: .selectedSessions([
                    UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
                ]),
                sourceSummary: "2 selected sessions",
                sessionCount: 2,
                filteredSessionCount: 2,
                totalSessionCount: 2,
                hasActiveFilters: false
            )
        )

        viewModel.selectedExportType = .requestWaterfall
        viewModel.title = "Startup Waterfall"
        viewModel.subtitle = ""
        viewModel.selectResolutionPreset(.fourK)
        viewModel.updateCustomDimensions(width: 1_280, height: 720)
        viewModel.theme = .presentation
        viewModel.redactionPolicy.allowsRawValues = true
        viewModel.chartConfiguration.groupingMode = .host
        viewModel.chartConfiguration.sortMode = .durationDescending
        viewModel.chartConfiguration.showFailedOnly = true
        viewModel.chartConfiguration.collapseDuplicates = false
        viewModel.chartConfiguration.normalizeRelativeStartTime = false
        viewModel.annotations.showStatusCodes = false
        viewModel.includedMetadata.includeLegend = false
        viewModel.includedMetadata.includeFooterMetadata = false
        viewModel.includedMetadata.includeDataSummary = false

        let request = viewModel.request

        XCTAssertEqual(request.exportType, .requestWaterfall)
        XCTAssertEqual(request.title, "Startup Waterfall")
        XCTAssertNil(request.subtitle)
        XCTAssertEqual(request.dimensions, VisualizationExportDimensions(preset: .custom, width: 1_280, height: 720))
        XCTAssertEqual(request.theme, .presentation)
        XCTAssertTrue(request.redactionPolicy.allowsRawValues)
        XCTAssertEqual(request.chartConfiguration.groupingMode, .host)
        XCTAssertEqual(request.chartConfiguration.sortMode, .durationDescending)
        XCTAssertTrue(request.chartConfiguration.showFailedOnly)
        XCTAssertFalse(request.chartConfiguration.collapseDuplicates)
        XCTAssertFalse(request.chartConfiguration.normalizeRelativeStartTime)
        XCTAssertFalse(request.annotations.showStatusCodes)
        XCTAssertFalse(request.includedMetadata.includeLegend)
        XCTAssertFalse(request.includedMetadata.includeFooterMetadata)
        XCTAssertFalse(request.includedMetadata.includeDataSummary)
    }

    func testCustomTimeRangeOverridesSourceScope() {
        let first = makeSession(startedAt: Date(timeIntervalSince1970: 100))
        let second = makeSession(startedAt: Date(timeIntervalSince1970: 200))
        let viewModel = VisualizationExportViewModel(
            context: VisualizationExportPresentationContext(
                sourceScope: .selectedSessions([first.id, second.id]),
                sourceSummary: "2 selected sessions",
                sessionCount: 2,
                filteredSessionCount: 2,
                totalSessionCount: 2,
                hasActiveFilters: false,
                sourceSessions: [first, second]
            )
        )

        viewModel.usesCustomTimeRange = true
        viewModel.timeRangeStart = Date(timeIntervalSince1970: 150)
        viewModel.timeRangeEnd = Date(timeIntervalSince1970: 250)

        XCTAssertEqual(
            viewModel.request.sourceScope,
            .timeRange(VisualizationExportTimeRange(
                start: Date(timeIntervalSince1970: 150),
                end: Date(timeIntervalSince1970: 250)
            ))
        )
    }

    func testResetRestoresDefaultsButKeepsScope() {
        let scope = VisualizationExportScope.selectedSession(UUID())
        let viewModel = VisualizationExportViewModel(
            context: VisualizationExportPresentationContext(
                sourceScope: scope,
                sourceSummary: "1 selected session",
                sessionCount: 1,
                filteredSessionCount: 1,
                totalSessionCount: 1,
                hasActiveFilters: false
            )
        )

        viewModel.selectedExportType = .requestWaterfall
        viewModel.title = "Changed"
        viewModel.theme = .light
        viewModel.redactionPolicy.allowsRawValues = true

        viewModel.resetToDefaults()

        XCTAssertEqual(viewModel.request.sourceScope, scope)
        XCTAssertEqual(viewModel.selectedExportType, .sessionTimeline)
        XCTAssertEqual(viewModel.title, "Session Timeline")
        XCTAssertEqual(viewModel.theme, .dark)
        XCTAssertEqual(viewModel.redactionPolicy, .shareableDefault)
    }

    func testValidationIssuesSurfaceUnsupportedTypeScopeCombination() {
        let viewModel = VisualizationExportViewModel(
            context: VisualizationExportPresentationContext(
                sourceScope: .filteredResults(VisualizationExportFilterDescriptor()),
                sourceSummary: "Current filtered results",
                sessionCount: 5,
                filteredSessionCount: 5,
                totalSessionCount: 5,
                hasActiveFilters: false
            )
        )

        viewModel.selectedExportType = .requestWaterfall

        XCTAssertTrue(
            viewModel.validationIssues.contains {
                if case .unsupportedScope(.requestWaterfall, "Filtered results") = $0 {
                    return true
                }
                return false
            }
        )
    }

    func testRequestWaterfallSetupPathFilterCanDisableExport() {
        let segment = makeSession(
            host: "cdn.example.com",
            path: "/segment-1.ts"
        )
        let viewModel = VisualizationExportViewModel(
            context: VisualizationExportPresentationContext(
                sourceScope: .selectedSession(segment.id),
                sourceSummary: "1 selected session",
                sessionCount: 1,
                filteredSessionCount: 1,
                totalSessionCount: 1,
                hasActiveFilters: false,
                sourceSessions: [segment]
            )
        )

        viewModel.selectedExportType = .requestWaterfall
        XCTAssertTrue(viewModel.canExportPNG)

        var configuration = viewModel.chartConfiguration
        configuration.setWaterfallSetupPathOnly(true)
        viewModel.chartConfiguration = configuration

        XCTAssertFalse(viewModel.canExportPNG)
        XCTAssertNil(viewModel.renderModel)
    }

    func testRequestWaterfallExportIsAvailableForSelectedSessionScope() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let viewModel = VisualizationExportViewModel(
            context: VisualizationExportPresentationContext(
                sourceScope: .selectedSession(sessionID),
                sourceSummary: "1 selected session",
                sessionCount: 1,
                filteredSessionCount: 1,
                totalSessionCount: 1,
                hasActiveFilters: false,
                sourceSessions: [makeSession(id: sessionID)]
            )
        )

        viewModel.selectedExportType = .requestWaterfall

        XCTAssertEqual(viewModel.validationIssues, [])
        XCTAssertTrue(viewModel.canExportPNG)
        XCTAssertEqual(viewModel.exportUnavailableMessage, "Export PNG")
        guard case .requestWaterfall = viewModel.renderModel else {
            return XCTFail("Expected request waterfall render model")
        }
    }

    func testPreviewStateTransitionsClampZoomAndFitModes() {
        var previewState = VisualizationExportPreviewState()

        previewState.zoomIn()
        previewState.fitWidth()

        XCTAssertEqual(previewState.zoomPercentText, "110%")
        XCTAssertEqual(previewState.fitMode, .fitWidth)

        for _ in 0..<20 {
            previewState.zoomOut()
        }
        previewState.fitHeight()

        XCTAssertEqual(previewState.zoomFactor, 0.15, accuracy: 0.001)
        XCTAssertEqual(previewState.fitMode, .fitHeight)

        previewState.reset()

        XCTAssertEqual(previewState.zoomFactor, 1, accuracy: 0.001)
        XCTAssertEqual(previewState.fitMode, .fitAll)
        XCTAssertEqual(previewState.panOffset, .zero)
    }

    func testPreviewPanUpdatesOffsetAndResetClearsIt() {
        var previewState = VisualizationExportPreviewState()
        previewState.pan(by: CGSize(width: 24, height: -12))

        XCTAssertEqual(previewState.panOffset.width, 24, accuracy: 0.001)
        XCTAssertEqual(previewState.panOffset.height, -12, accuracy: 0.001)

        previewState.reset()
        XCTAssertEqual(previewState.panOffset, .zero)
    }

    func testRenderModelUpdatesWhenSharedOptionsChange() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let viewModel = VisualizationExportViewModel(
            context: VisualizationExportPresentationContext(
                sourceScope: .selectedSession(sessionID),
                sourceSummary: "1 selected session",
                sessionCount: 1,
                filteredSessionCount: 1,
                totalSessionCount: 1,
                hasActiveFilters: false,
                sourceSessions: [makeSession(id: sessionID)]
            )
        )

        let initialTitle = viewModel.renderModel?.request.title
        viewModel.title = "Updated Timeline"
        let updatedTitle = viewModel.renderModel?.request.title

        XCTAssertEqual(initialTitle, "Session Timeline")
        XCTAssertEqual(updatedTitle, "Updated Timeline")
    }

    func testRenderModelUpdatesWhenHostHealthOptionsChange() {
        let sessions = [
            makeSession(host: "api.example.com"),
            makeSession(host: "cdn.example.com")
        ]
        let viewModel = VisualizationExportViewModel(
            context: VisualizationExportPresentationContext(
                sourceScope: .filteredResults(VisualizationExportFilterDescriptor()),
                sourceSummary: "Current filtered results",
                sessionCount: 2,
                filteredSessionCount: 2,
                totalSessionCount: 2,
                hasActiveFilters: false,
                sourceSessions: sessions
            )
        )

        guard case .hostHealthSummary(let aggregateModel) = viewModel.renderModel else {
            return XCTFail("Expected host health render model")
        }
        XCTAssertEqual(aggregateModel.hosts.count, 1)

        var configuration = viewModel.chartConfiguration
        configuration.setHostHealthComparisonMode(true)
        viewModel.chartConfiguration = configuration

        guard case .hostHealthSummary(let comparisonModel) = viewModel.renderModel else {
            return XCTFail("Expected updated host health render model")
        }
        XCTAssertEqual(comparisonModel.hosts.count, 2)
    }

    private func makeSession(
        id: UUID = UUID(),
        startedAt: Date = Date(timeIntervalSince1970: 100),
        duration: TimeInterval = 0.25,
        host: String = "api.example.com",
        path: String = "/v1/start?token=secret",
        statusCode: Int = 200
    ) -> SessionRecord {
        SessionRecord(
            id: id,
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                inspectionKind: .interceptedTLS,
                host: host,
                port: 443,
                path: path,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: statusCode,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                bodyData: nil,
                bodySize: 256
            ),
            state: .completed,
            timing: SessionTiming(
                startedAt: startedAt,
                completedAt: startedAt.addingTimeInterval(duration)
            )
        )
    }
}
