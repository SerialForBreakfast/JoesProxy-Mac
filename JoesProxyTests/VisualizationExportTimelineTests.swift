import AppKit
import XCTest
@testable import JoesProxy

@MainActor
final class VisualizationExportTimelineTests: XCTestCase {
    func testTimelineModelOrdersRowsAndNormalizesStartOffsets() {
        let first = makeSession(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            startedAt: Date(timeIntervalSince1970: 100),
            path: "/first?token=secret"
        )
        let second = makeSession(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            startedAt: Date(timeIntervalSince1970: 103),
            host: "cdn.example.com",
            path: "/second"
        )
        let request = VisualizationExportRequest(
            exportType: .sessionTimeline,
            sourceScope: .selectedSessions([first.id, second.id])
        )

        guard case .sessionTimeline(let model) = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: [second, first]
        ) else {
            return XCTFail("Expected session timeline model")
        }

        XCTAssertEqual(model.rows.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.rows[0].startOffset, 0, accuracy: 0.001)
        XCTAssertEqual(model.rows[1].startOffset, 3, accuracy: 0.001)
        XCTAssertEqual(model.rows[0].pathSummary, "/first?token=%3Credacted%3E")
        XCTAssertEqual(model.rows[0].statusLabel, "200")
        XCTAssertEqual(model.rows[0].contentType, "application/json")
        XCTAssertEqual(model.dataSummary.sessionCount, 2)
        XCTAssertEqual(model.dataSummary.hostCount, 2)
    }

    /// AJ-2: the timeline row must carry the response's immutable capture-time MCP attribution
    /// snapshot verbatim — never re-derive it from a live rule lookup, so it survives the rule
    /// being disabled/edited/deleted/detached after capture.
    func testTimelineModelCarriesImmutableMCPAttribution() {
        let attribution = MCPCaptureAttribution(
            provenance: MCPProvenance(
                clientID: "client-1",
                operationID: "op-1",
                capability: .enableRule,
                createdAt: Date(timeIntervalSince1970: 50)
            ),
            effectKinds: [.block],
            scenarioID: nil,
            measurementContext: nil
        )
        let session = makeSession(startedAt: Date(timeIntervalSince1970: 100), mcpAttribution: attribution)
        let request = VisualizationExportRequest(
            exportType: .sessionTimeline,
            sourceScope: .selectedSessions([session.id])
        )

        guard case .sessionTimeline(let model) = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: [session]
        ) else {
            return XCTFail("Expected session timeline model")
        }

        XCTAssertEqual(model.rows.first?.mcpEffectAnnotation, attribution)
    }

    func testTimelineModelLeavesUnattributedSessionsNil() {
        let session = makeSession(startedAt: Date(timeIntervalSince1970: 100))
        let request = VisualizationExportRequest(
            exportType: .sessionTimeline,
            sourceScope: .selectedSessions([session.id])
        )

        guard case .sessionTimeline(let model) = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: [session]
        ) else {
            return XCTFail("Expected session timeline model")
        }

        XCTAssertNil(model.rows.first?.mcpEffectAnnotation)
    }

    func testTimelineModelFlagsFailuresAndDensityWarnings() {
        let sessions = (0..<90).map { index in
            makeSession(
                startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                duration: 0.02,
                statusCode: index.isMultiple(of: 10) ? 500 : 200
            )
        }
        let request = VisualizationExportRequest(
            exportType: .sessionTimeline,
            sourceScope: .filteredResults(VisualizationExportFilterDescriptor()),
            chartConfiguration: VisualizationExportChartConfiguration(
                groupingMode: .none,
                sortMode: .startTime,
                showFailedOnly: false,
                collapseDuplicates: false,
                normalizeRelativeStartTime: true,
                optionFlags: [:],
                optionValues: [:]
            )
        )

        guard case .sessionTimeline(let model) = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: sessions
        ) else {
            return XCTFail("Expected session timeline model")
        }

        XCTAssertEqual(model.dataSummary.errorCount, 9)
        XCTAssertFalse(model.warnings.isEmpty)
        XCTAssertTrue(model.warnings.contains { $0.contains("High row count") })
    }

    func testTimelineModelAppliesSharedChartOptions() {
        let duplicateA = makeSession(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            startedAt: Date(timeIntervalSince1970: 100),
            duration: 1,
            host: "api.example.com",
            path: "/duplicate",
            statusCode: 200
        )
        let duplicateB = makeSession(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            startedAt: Date(timeIntervalSince1970: 101),
            duration: 5,
            host: "api.example.com",
            path: "/duplicate",
            statusCode: 200
        )
        let failure = makeSession(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            startedAt: Date(timeIntervalSince1970: 102),
            duration: 3,
            host: "cdn.example.com",
            path: "/failed",
            statusCode: 500
        )
        var chartConfiguration = VisualizationExportChartConfiguration.defaults
        chartConfiguration.groupingMode = .host
        chartConfiguration.sortMode = .durationDescending
        chartConfiguration.collapseDuplicates = true
        let request = VisualizationExportRequest(
            exportType: .sessionTimeline,
            sourceScope: .selectedSessions([duplicateA.id, duplicateB.id, failure.id]),
            chartConfiguration: chartConfiguration
        )

        guard case .sessionTimeline(let model) = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: [failure, duplicateB, duplicateA]
        ) else {
            return XCTFail("Expected session timeline model")
        }

        XCTAssertEqual(model.rows.map(\.id), [duplicateB.id, failure.id])
        XCTAssertEqual(model.rows.map(\.host), ["api.example.com", "cdn.example.com"])
    }

    func testTimelineModelFiltersFailedOnlyAndCustomTimeRange() {
        let outsideRange = makeSession(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            startedAt: Date(timeIntervalSince1970: 50),
            statusCode: 500
        )
        let successInsideRange = makeSession(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            startedAt: Date(timeIntervalSince1970: 110),
            statusCode: 200
        )
        let failureInsideRange = makeSession(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            startedAt: Date(timeIntervalSince1970: 120),
            statusCode: 404
        )
        var chartConfiguration = VisualizationExportChartConfiguration.defaults
        chartConfiguration.showFailedOnly = true
        chartConfiguration.normalizeRelativeStartTime = false
        let request = VisualizationExportRequest(
            exportType: .sessionTimeline,
            sourceScope: .timeRange(VisualizationExportTimeRange(
                start: Date(timeIntervalSince1970: 100),
                end: Date(timeIntervalSince1970: 130)
            )),
            chartConfiguration: chartConfiguration
        )

        guard case .sessionTimeline(let model) = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: [outsideRange, successInsideRange, failureInsideRange]
        ) else {
            return XCTFail("Expected session timeline model")
        }

        XCTAssertEqual(model.rows.map(\.id), [failureInsideRange.id])
        XCTAssertEqual(model.rows[0].startOffset, 20, accuracy: 0.001)
    }

    func testTimelineModelGroupsByRequestRole() {
        let api = makeSession(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            startedAt: Date(timeIntervalSince1970: 100),
            host: "api.example.com",
            path: "/session-token.json",
            statusCode: 200
        )
        let media = makeSession(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            startedAt: Date(timeIntervalSince1970: 101),
            host: "cdn.example.com",
            path: "/segment-1.ts",
            statusCode: 200
        )

        var chartConfiguration = VisualizationExportChartConfiguration.defaults
        chartConfiguration.groupingMode = .requestRole
        let request = VisualizationExportRequest(
            exportType: .sessionTimeline,
            sourceScope: .selectedSessions([api.id, media.id]),
            chartConfiguration: chartConfiguration
        )

        guard case .sessionTimeline(let model) = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: [media, api]
        ) else {
            return XCTFail("Expected session timeline model")
        }

        XCTAssertEqual(model.rows.map(\.id), [api.id, media.id])
    }

    func testTimelineModelAddsHostLabelOverflowWarning() {
        let sessions = (0..<30).map { index in
            makeSession(
                startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                host: "host-\(index).example.com"
            )
        }
        var annotations = VisualizationExportAnnotationOptions.defaults
        annotations.showHostLabels = true
        let request = VisualizationExportRequest(
            exportType: .sessionTimeline,
            sourceScope: .filteredResults(VisualizationExportFilterDescriptor()),
            dimensions: .hd,
            annotations: annotations
        )

        guard case .sessionTimeline(let model) = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: sessions
        ) else {
            return XCTFail("Expected session timeline model")
        }

        XCTAssertTrue(model.warnings.contains { $0.contains("Host labels may overflow") })
    }

    func testRendererOutputsPNGWithRequestedDimensions() throws {
        let model = try makeRenderModel(
            dimensions: VisualizationExportDimensions(preset: .custom, width: 640, height: 360)
        )

        let data = try VisualizationExportPNGRenderer().renderPNGData(for: model)
        let image = NSBitmapImageRep(data: data)

        XCTAssertGreaterThan(data.count, 0)
        XCTAssertEqual(image?.pixelsWide, 640)
        XCTAssertEqual(image?.pixelsHigh, 360)
    }

    func testRendererResultIncludesMetadataAndSummary() throws {
        let model = try makeRenderModel()
        let generatedAt = Date(timeIntervalSince1970: 500)
        let result = VisualizationExportPNGRenderer().makeResult(
            for: model,
            imageFileURL: URL(fileURLWithPath: "/example/timeline.png"),
            imageByteCount: 1234,
            generatedAt: generatedAt
        )

        XCTAssertEqual(result.requestID, model.request.id)
        XCTAssertEqual(result.exportType, .sessionTimeline)
        XCTAssertEqual(result.imageByteCount, 1234)
        XCTAssertEqual(result.metadata.generatedAt, generatedAt)
        XCTAssertEqual(result.dimensions, model.request.dimensions)
        XCTAssertEqual(result.dataSummary.sessionCount, 2)
        XCTAssertEqual(result.sourceDescriptor.scopeSummary, "2 selected sessions")
        XCTAssertTrue(result.redactionSummary.redactedCategories.contains("query parameters"))
    }

    func testThemeSelectionChangesRenderedPNGBytes() throws {
        let dark = try VisualizationExportPNGRenderer().renderPNGData(for: makeRenderModel(theme: .dark))
        let light = try VisualizationExportPNGRenderer().renderPNGData(for: makeRenderModel(theme: .light))

        XCTAssertNotEqual(dark, light)
    }

    private func makeRenderModel(
        theme: VisualizationExportTheme = .dark,
        dimensions: VisualizationExportDimensions = .hd
    ) throws -> VisualizationExportRenderModel {
        let first = makeSession(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            startedAt: Date(timeIntervalSince1970: 100),
            host: "api.example.com",
            path: "/bootstrap?token=secret"
        )
        let second = makeSession(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            startedAt: Date(timeIntervalSince1970: 101),
            host: "cdn.example.com",
            path: "/segment.ts",
            statusCode: 404
        )
        let request = VisualizationExportRequest(
            exportType: .sessionTimeline,
            sourceScope: .selectedSessions([first.id, second.id]),
            theme: theme,
            dimensions: dimensions
        )

        guard let model = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: [first, second]
        ) else {
            throw XCTSkip("Could not build render model")
        }
        return model
    }

    private func makeSession(
        id: UUID = UUID(),
        startedAt: Date,
        duration: TimeInterval = 0.25,
        host: String = "api.example.com",
        path: String = "/v1/start?token=secret",
        statusCode: Int = 200,
        mcpAttribution: MCPCaptureAttribution? = nil
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
                bodySize: 256,
                mcpAttribution: mcpAttribution
            ),
            state: .completed,
            timing: SessionTiming(
                startedAt: startedAt,
                completedAt: startedAt.addingTimeInterval(duration)
            )
        )
    }
}
