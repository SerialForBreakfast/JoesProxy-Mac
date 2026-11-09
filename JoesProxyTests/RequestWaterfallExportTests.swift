import AppKit
import XCTest
@testable import JoesProxy

@MainActor
final class RequestWaterfallExportTests: XCTestCase {
    func testWaterfallModelOrdersRowsByStartTime() throws {
        let first = makeSession(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            startedAt: Date(timeIntervalSince1970: 100),
            duration: 0.10,
            path: "/bootstrap"
        )
        let second = makeSession(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            startedAt: Date(timeIntervalSince1970: 103),
            duration: 0.20,
            host: "cdn.example.com",
            path: "/segment.ts"
        )
        let request = VisualizationExportRequest(
            exportType: .requestWaterfall,
            sourceScope: .selectedSessions([first.id, second.id])
        )

        guard case .requestWaterfall(let model) = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: [second, first]
        ) else {
            return XCTFail("Expected request waterfall model")
        }

        XCTAssertEqual(model.rows.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.rows[0].startOffset, 0, accuracy: 0.001)
        XCTAssertEqual(model.rows[1].startOffset, 3, accuracy: 0.001)
        XCTAssertEqual(model.rows[0].duration, 0.10, accuracy: 0.001)
        XCTAssertEqual(model.rows[1].host, "cdn.example.com")
        XCTAssertFalse(model.rows[0].categoryTitle.isEmpty)
    }

    /// AJ-2: the waterfall row must carry the response's immutable capture-time MCP attribution
    /// verbatim, decoupled from any live rule lookup.
    func testWaterfallModelCarriesImmutableMCPAttribution() {
        let attribution = MCPCaptureAttribution(
            provenance: MCPProvenance(
                clientID: "client-1",
                operationID: "op-1",
                capability: .changeThrottle,
                createdAt: Date(timeIntervalSince1970: 50)
            ),
            effectKinds: [.throttle],
            scenarioID: nil,
            measurementContext: nil
        )
        let session = makeSession(
            startedAt: Date(timeIntervalSince1970: 100),
            mcpAttribution: attribution
        )
        let request = VisualizationExportRequest(
            exportType: .requestWaterfall,
            sourceScope: .selectedSessions([session.id])
        )

        guard case .requestWaterfall(let model) = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: [session]
        ) else {
            return XCTFail("Expected request waterfall model")
        }

        XCTAssertEqual(model.rows.first?.mcpEffectAnnotation, attribution)
    }

    func testWaterfallModelSortsByDurationDescending() {
        let fast = makeSession(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            startedAt: Date(timeIntervalSince1970: 100),
            duration: 0.05
        )
        let slow = makeSession(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            startedAt: Date(timeIntervalSince1970: 101),
            duration: 0.50
        )
        var chartConfiguration = VisualizationExportChartConfiguration.defaults
        chartConfiguration.sortMode = .durationDescending
        let request = VisualizationExportRequest(
            exportType: .requestWaterfall,
            sourceScope: .selectedSessions([fast.id, slow.id]),
            chartConfiguration: chartConfiguration
        )

        guard case .requestWaterfall(let model) = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: [fast, slow]
        ) else {
            return XCTFail("Expected request waterfall model")
        }

        XCTAssertEqual(model.rows.map(\.id), [slow.id, fast.id])
    }

    func testWaterfallModelHighlightsSlowestRequests() {
        let first = makeSession(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            startedAt: Date(timeIntervalSince1970: 100),
            duration: 0.05
        )
        let second = makeSession(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            startedAt: Date(timeIntervalSince1970: 101),
            duration: 0.10
        )
        let third = makeSession(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            startedAt: Date(timeIntervalSince1970: 102),
            duration: 0.15
        )
        let fourth = makeSession(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            startedAt: Date(timeIntervalSince1970: 103),
            duration: 0.20
        )
        let fifth = makeSession(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            startedAt: Date(timeIntervalSince1970: 104),
            duration: 0.25
        )
        let sessions = [first, second, third, fourth, fifth]
        var chartConfiguration = VisualizationExportChartConfiguration.defaults
        chartConfiguration.setWaterfallHighlightSlowestRequests(true)
        let request = VisualizationExportRequest(
            exportType: .requestWaterfall,
            sourceScope: .selectedSessions(sessions.map(\.id)),
            chartConfiguration: chartConfiguration
        )

        guard case .requestWaterfall(let model) = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: sessions
        ) else {
            return XCTFail("Expected request waterfall model")
        }

        XCTAssertEqual(model.rows.filter(\.isSlowestHighlight).count, 3)
        XCTAssertTrue(model.rows.contains(where: { $0.id == fifth.id && $0.isSlowestHighlight }))
    }

    func testWaterfallModelSetupPathOnlyFiltersMediaSegments() {
        let api = makeSession(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            startedAt: Date(timeIntervalSince1970: 100),
            path: "/session-token.json"
        )
        let segment = makeSession(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            startedAt: Date(timeIntervalSince1970: 101),
            host: "cdn.example.com",
            path: "/segment-1.ts"
        )
        var chartConfiguration = VisualizationExportChartConfiguration.defaults
        chartConfiguration.setWaterfallSetupPathOnly(true)
        let request = VisualizationExportRequest(
            exportType: .requestWaterfall,
            sourceScope: .selectedSessions([api.id, segment.id]),
            chartConfiguration: chartConfiguration
        )

        guard case .requestWaterfall(let model) = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: [api, segment]
        ) else {
            return XCTFail("Expected request waterfall model")
        }

        XCTAssertEqual(model.rows.map(\.id), [api.id])
        XCTAssertNotEqual(model.rows.first?.categoryLane, .mediaSegments)
    }

    func testWaterfallModelSetupPathOnlyWithOnlyMediaReturnsNil() {
        let segment = makeSession(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            startedAt: Date(timeIntervalSince1970: 101),
            host: "cdn.example.com",
            path: "/segment-1.ts"
        )
        var chartConfiguration = VisualizationExportChartConfiguration.defaults
        chartConfiguration.setWaterfallSetupPathOnly(true)
        let request = VisualizationExportRequest(
            exportType: .requestWaterfall,
            sourceScope: .selectedSession(segment.id),
            chartConfiguration: chartConfiguration
        )

        XCTAssertNil(
            VisualizationExportRenderModelBuilder.makeRenderModel(request: request, sessions: [segment])
        )
    }

    func testWaterfallModelAppliesHostScope() {
        let api = makeSession(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            startedAt: Date(timeIntervalSince1970: 100),
            host: "api.example.com"
        )
        let cdn = makeSession(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            startedAt: Date(timeIntervalSince1970: 101),
            host: "cdn.example.com"
        )
        let request = VisualizationExportRequest(
            exportType: .requestWaterfall,
            sourceScope: .host("api.example.com")
        )

        guard case .requestWaterfall(let model) = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: [cdn, api]
        ) else {
            return XCTFail("Expected request waterfall model")
        }

        XCTAssertEqual(model.rows.map(\.id), [api.id])
    }

    func testWaterfallModelAddsDenseRowWarnings() {
        let sessions = (0..<90).map { index in
            makeSession(
                startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                duration: 0.02
            )
        }
        let request = VisualizationExportRequest(
            exportType: .requestWaterfall,
            sourceScope: .selectedSessions(sessions.map(\.id)),
            dimensions: .hd
        )

        guard case .requestWaterfall(let model) = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: sessions
        ) else {
            return XCTFail("Expected request waterfall model")
        }

        XCTAssertTrue(model.warnings.contains { $0.contains("High row count") })
    }

    func testWaterfallRendererOutputsPNGWithRequestedDimensions() throws {
        let model = try makeRenderModel(
            dimensions: VisualizationExportDimensions(preset: .custom, width: 640, height: 360)
        )

        let data = try VisualizationExportPNGRenderer().renderPNGData(for: model)
        let image = NSBitmapImageRep(data: data)

        XCTAssertGreaterThan(data.count, 0)
        XCTAssertEqual(image?.pixelsWide, 640)
        XCTAssertEqual(image?.pixelsHigh, 360)
    }

    func testWaterfallRendererResultIncludesMetadataAndSummary() throws {
        let model = try makeRenderModel()
        let generatedAt = Date(timeIntervalSince1970: 500)
        let result = VisualizationExportPNGRenderer().makeResult(
            for: model,
            imageFileURL: URL(fileURLWithPath: "/example/waterfall.png"),
            imageByteCount: 2345,
            generatedAt: generatedAt
        )

        XCTAssertEqual(result.requestID, model.request.id)
        XCTAssertEqual(result.exportType, .requestWaterfall)
        XCTAssertEqual(result.imageByteCount, 2345)
        XCTAssertEqual(result.metadata.generatedAt, generatedAt)
        XCTAssertEqual(result.dataSummary.sessionCount, 2)
    }

    private func makeRenderModel(
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
            exportType: .requestWaterfall,
            sourceScope: .selectedSessions([first.id, second.id]),
            dimensions: dimensions
        )

        guard let model = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: [first, second]
        ) else {
            throw XCTSkip("Could not build request waterfall render model")
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
