import AppKit
import XCTest
@testable import JoesProxy

@MainActor
final class HostHealthSummaryExportTests: XCTestCase {
    func testHostHealthAggregateMetricsAndPercentiles() throws {
        let sessions = [
            makeSession(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                startedAt: Date(timeIntervalSince1970: 100),
                completedAt: Date(timeIntervalSince1970: 100.10),
                statusCode: 200
            ),
            makeSession(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                startedAt: Date(timeIntervalSince1970: 101),
                completedAt: Date(timeIntervalSince1970: 101.20),
                statusCode: 200
            ),
            makeSession(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                startedAt: Date(timeIntervalSince1970: 102),
                completedAt: Date(timeIntervalSince1970: 102.30),
                statusCode: 500
            )
        ]
        let request = VisualizationExportRequest(
            exportType: .hostHealthSummary,
            sourceScope: .filteredResults(VisualizationExportFilterDescriptor())
        )

        guard case .hostHealthSummary(let model) = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: sessions
        ) else {
            return XCTFail("Expected host health summary model")
        }

        XCTAssertFalse(model.comparisonMode)
        XCTAssertEqual(model.hosts.count, 1)
        let host = try XCTUnwrap(model.hosts.first)
        XCTAssertEqual(host.host, "All Hosts")
        XCTAssertEqual(host.requestCount, 3)
        XCTAssertEqual(host.successCount, 2)
        XCTAssertEqual(host.errorCount, 1)
        XCTAssertEqual(host.serverErrorCount, 1)
        XCTAssertEqual(try XCTUnwrap(host.p50LatencyMs), 200, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(host.p95LatencyMs), 300, accuracy: 0.001)
        XCTAssertEqual(model.dataSummary.sessionCount, 3)
        XCTAssertEqual(model.dataSummary.errorCount, 1)
    }

    func testHostHealthComparisonModeGroupsHosts() {
        let apiA = makeSession(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            startedAt: Date(timeIntervalSince1970: 100),
            host: "api.example.com"
        )
        let apiB = makeSession(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            startedAt: Date(timeIntervalSince1970: 101),
            host: "api.example.com"
        )
        let cdn = makeSession(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            startedAt: Date(timeIntervalSince1970: 102),
            host: "cdn.example.com"
        )
        var chartConfiguration = VisualizationExportChartConfiguration.defaults
        chartConfiguration.setHostHealthComparisonMode(true)
        let request = VisualizationExportRequest(
            exportType: .hostHealthSummary,
            sourceScope: .filteredResults(VisualizationExportFilterDescriptor()),
            chartConfiguration: chartConfiguration
        )

        guard case .hostHealthSummary(let model) = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: [cdn, apiB, apiA]
        ) else {
            return XCTFail("Expected host health summary model")
        }

        XCTAssertTrue(model.comparisonMode)
        XCTAssertEqual(model.hosts.map(\.host), ["api.example.com", "cdn.example.com"])
        XCTAssertEqual(model.hosts.map(\.requestCount), [2, 1])
        XCTAssertEqual(model.dataSummary.hostCount, 2)
    }

    func testHostHealthBucketsErrorsAndPeakWindow() throws {
        let sessions = (0..<6).map { index in
            let startedAt = Date(timeIntervalSince1970: TimeInterval(index * 30))
            return makeSession(
                startedAt: startedAt,
                completedAt: startedAt.addingTimeInterval(0.05),
                statusCode: index.isMultiple(of: 3) ? 500 : 200
            )
        }
        var chartConfiguration = VisualizationExportChartConfiguration.defaults
        chartConfiguration.setHostHealthBucketSize(.thirtySeconds)
        let request = VisualizationExportRequest(
            exportType: .hostHealthSummary,
            sourceScope: .filteredResults(VisualizationExportFilterDescriptor()),
            chartConfiguration: chartConfiguration
        )

        guard case .hostHealthSummary(let model) = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: sessions
        ) else {
            return XCTFail("Expected host health summary model")
        }

        let host = try XCTUnwrap(model.hosts.first)
        XCTAssertEqual(host.buckets.count, 6)
        XCTAssertEqual(host.buckets.map(\.requestCount), [1, 1, 1, 1, 1, 1])
        XCTAssertEqual(host.buckets.map(\.errorCount), [1, 0, 0, 1, 0, 0])
        XCTAssertEqual(host.peakErrorWindow?.errorCount, 1)
        XCTAssertNotNil(host.peakErrorWindow)
    }

    /// AJ-2: buckets and host summaries must count requests captured under an active MCP effect
    /// (e.g. "N of these M requests were under an active throttle"), sourced from each session's
    /// immutable capture-time attribution snapshot, never a live rule lookup.
    func testHostHealthCountsMCPAttributedRequestsPerBucketAndHost() throws {
        let attribution = MCPCaptureAttribution(
            provenance: MCPProvenance(
                clientID: "client-1",
                operationID: "op-1",
                capability: .changeThrottle,
                createdAt: Date(timeIntervalSince1970: 0)
            ),
            effectKinds: [.throttle],
            scenarioID: nil,
            measurementContext: nil
        )
        let sessions = (0..<6).map { index in
            let startedAt = Date(timeIntervalSince1970: TimeInterval(index * 30))
            return makeSession(
                startedAt: startedAt,
                completedAt: startedAt.addingTimeInterval(0.05),
                mcpAttribution: index.isMultiple(of: 3) ? attribution : nil
            )
        }
        var chartConfiguration = VisualizationExportChartConfiguration.defaults
        chartConfiguration.setHostHealthBucketSize(.thirtySeconds)
        let request = VisualizationExportRequest(
            exportType: .hostHealthSummary,
            sourceScope: .filteredResults(VisualizationExportFilterDescriptor()),
            chartConfiguration: chartConfiguration
        )

        guard case .hostHealthSummary(let model) = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: sessions
        ) else {
            return XCTFail("Expected host health summary model")
        }

        let host = try XCTUnwrap(model.hosts.first)
        XCTAssertEqual(host.mcpAttributedRequestCount, 2)
        XCTAssertEqual(host.buckets.map(\.mcpAttributedRequestCount), [1, 0, 0, 1, 0, 0])
    }

    func testHostHealthHostScopeFilter() {
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
            exportType: .hostHealthSummary,
            sourceScope: .host("api.example.com")
        )

        guard case .hostHealthSummary(let model) = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: [cdn, api]
        ) else {
            return XCTFail("Expected host health summary model")
        }

        XCTAssertEqual(model.hosts.count, 1)
        XCTAssertEqual(model.hosts.first?.requestCount, 1)
        XCTAssertEqual(model.hosts.first?.host, "All Hosts")
    }

    func testHostHealthEmptySessionsReturnsNilModel() {
        let request = VisualizationExportRequest(
            exportType: .hostHealthSummary,
            sourceScope: .filteredResults(VisualizationExportFilterDescriptor())
        )

        XCTAssertNil(
            VisualizationExportRenderModelBuilder.makeRenderModel(request: request, sessions: [])
        )
    }

    func testHostHealthPartialLatencyWarning() {
        let untimedA = makeSession(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            startedAt: Date(timeIntervalSince1970: 100),
            includeCompletionTime: false
        )
        let untimedB = makeSession(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            startedAt: Date(timeIntervalSince1970: 101),
            includeCompletionTime: false
        )
        let request = VisualizationExportRequest(
            exportType: .hostHealthSummary,
            sourceScope: .filteredResults(VisualizationExportFilterDescriptor())
        )

        guard case .hostHealthSummary(let model) = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: [untimedA, untimedB]
        ) else {
            return XCTFail("Expected host health summary model")
        }

        XCTAssertNil(model.hosts.first?.p50LatencyMs)
        XCTAssertTrue(
            model.warnings.contains {
                $0.contains("missing timing data")
            }
        )
    }

    func testHostHealthComparisonLimitsHostsAndWarns() {
        let sessions = (0..<10).flatMap { index in
            [
                makeSession(
                    startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    host: "host-\(index).example.com"
                )
            ]
        }
        var chartConfiguration = VisualizationExportChartConfiguration.defaults
        chartConfiguration.setHostHealthComparisonMode(true)
        let request = VisualizationExportRequest(
            exportType: .hostHealthSummary,
            sourceScope: .filteredResults(VisualizationExportFilterDescriptor()),
            chartConfiguration: chartConfiguration
        )

        guard case .hostHealthSummary(let model) = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: sessions
        ) else {
            return XCTFail("Expected host health summary model")
        }

        XCTAssertEqual(model.hosts.count, 8)
        XCTAssertTrue(
            model.warnings.contains {
                $0.contains("limited to the top 8 hosts")
            }
        )
    }

    func testHostHealthRendererOutputsPNGWithRequestedDimensions() throws {
        let model = try makeRenderModel(
            dimensions: VisualizationExportDimensions(preset: .custom, width: 640, height: 360)
        )

        let data = try VisualizationExportPNGRenderer().renderPNGData(for: model)
        let image = NSBitmapImageRep(data: data)

        XCTAssertGreaterThan(data.count, 0)
        XCTAssertEqual(image?.pixelsWide, 640)
        XCTAssertEqual(image?.pixelsHigh, 360)
    }

    func testHostHealthRendererResultIncludesMetadataAndSummary() throws {
        let model = try makeRenderModel()
        let generatedAt = Date(timeIntervalSince1970: 500)
        let result = VisualizationExportPNGRenderer().makeResult(
            for: model,
            imageFileURL: URL(fileURLWithPath: "/example/host-health.png"),
            imageByteCount: 4321,
            generatedAt: generatedAt
        )

        XCTAssertEqual(result.requestID, model.request.id)
        XCTAssertEqual(result.exportType, .hostHealthSummary)
        XCTAssertEqual(result.imageByteCount, 4321)
        XCTAssertEqual(result.metadata.generatedAt, generatedAt)
        XCTAssertEqual(result.dataSummary.sessionCount, 2)
        XCTAssertEqual(result.dataSummary.hostCount, 1)
    }

    private func makeRenderModel(
        dimensions: VisualizationExportDimensions = .hd
    ) throws -> VisualizationExportRenderModel {
        let first = makeSession(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            startedAt: Date(timeIntervalSince1970: 100),
            host: "api.example.com",
            statusCode: 200
        )
        let second = makeSession(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            startedAt: Date(timeIntervalSince1970: 101),
            host: "cdn.example.com",
            statusCode: 404
        )
        let request = VisualizationExportRequest(
            exportType: .hostHealthSummary,
            sourceScope: .filteredResults(VisualizationExportFilterDescriptor()),
            dimensions: dimensions
        )

        guard let model = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: [first, second]
        ) else {
            throw XCTSkip("Could not build host health render model")
        }
        return model
    }

    private func makeSession(
        id: UUID = UUID(),
        startedAt: Date,
        completedAt: Date? = nil,
        includeCompletionTime: Bool = true,
        host: String = "api.example.com",
        path: String = "/v1/start?token=secret",
        statusCode: Int = 200,
        mcpAttribution: MCPCaptureAttribution? = nil
    ) -> SessionRecord {
        let resolvedCompletedAt: Date?
        if includeCompletionTime {
            resolvedCompletedAt = completedAt ?? startedAt.addingTimeInterval(0.25)
        } else {
            resolvedCompletedAt = nil
        }
        return SessionRecord(
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
                completedAt: resolvedCompletedAt
            )
        )
    }
}
