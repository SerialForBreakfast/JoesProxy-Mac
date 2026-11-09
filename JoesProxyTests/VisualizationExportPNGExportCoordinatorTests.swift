import Foundation
import XCTest
@testable import JoesProxy

@MainActor
final class VisualizationExportPNGExportCoordinatorTests: XCTestCase {
    func testDefaultPNGFileNameUsesExportTypeAndTimestampShape() throws {
        let request = VisualizationExportRequest(
            exportType: .sessionTimeline,
            sourceScope: .selectedSession(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        )

        let fileName = VisualizationExportPNGExportCoordinator.defaultPNGFileName(
            for: request,
            now: Date(timeIntervalSince1970: 1_717_200_000)
        )

        XCTAssertEqual(fileName.count, "joesproxy-session-timeline-yyyyMMdd-HHmmss.png".count)
        XCTAssertTrue(fileName.hasPrefix("joesproxy-session-timeline-"))
        XCTAssertTrue(fileName.hasSuffix(".png"))
    }

    func testCancelSkipsRenderAndWrite() throws {
        let model = try makeRenderModel()
        var didRender = false
        var didWrite = false
        let coordinator = VisualizationExportPNGExportCoordinator(
            destinationSelector: { _, _ in .cancelled },
            pngRenderer: { _ in
                didRender = true
                return Data([0x01])
            },
            pngWriter: { _, _ in didWrite = true }
        )

        let outcome = try coordinator.export(model: model)

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(didRender)
        XCTAssertFalse(didWrite)
    }

    func testExportWritesRenderedPNGAndReturnsResult() throws {
        let model = try makeRenderModel()
        let destinationURL = URL(fileURLWithPath: "/Users/tester/Projects/JoesProxy/build/test-session-timeline.png")
        let pngData = Data([0x89, 0x50, 0x4E, 0x47])
        var selectedDefaultFileName: String?
        var writtenData: Data?
        var writtenURL: URL?
        let coordinator = VisualizationExportPNGExportCoordinator(
            destinationSelector: { _, defaultFileName in
                selectedDefaultFileName = defaultFileName
                return .file(destinationURL)
            },
            pngRenderer: { receivedModel in
                XCTAssertEqual(receivedModel, model)
                return pngData
            },
            pngWriter: { data, url in
                writtenData = data
                writtenURL = url
            }
        )

        let outcome = try coordinator.export(model: model)

        guard case .exported(let result) = outcome else {
            return XCTFail("Expected successful export")
        }
        XCTAssertEqual(selectedDefaultFileName?.hasPrefix("joesproxy-session-timeline-"), true)
        XCTAssertEqual(selectedDefaultFileName?.hasSuffix(".png"), true)
        XCTAssertEqual(writtenData, pngData)
        XCTAssertEqual(writtenURL, destinationURL)
        XCTAssertEqual(result.imageFileURL, destinationURL)
        XCTAssertEqual(result.imageByteCount, pngData.count)
        XCTAssertEqual(result.requestID, model.request.id)
    }

    func testWriterFailurePropagates() throws {
        let model = try makeRenderModel()
        let coordinator = VisualizationExportPNGExportCoordinator(
            destinationSelector: { _, _ in
                .file(URL(fileURLWithPath: "/Users/tester/Projects/JoesProxy/build/failing-session-timeline.png"))
            },
            pngRenderer: { _ in Data([0x01]) },
            pngWriter: { _, _ in throw TestExportError.writeFailed }
        )

        XCTAssertThrowsError(try coordinator.export(model: model)) { error in
            XCTAssertEqual(error as? TestExportError, .writeFailed)
        }
    }

    private func makeRenderModel() throws -> VisualizationExportRenderModel {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let request = VisualizationExportRequest(
            exportType: .sessionTimeline,
            sourceScope: .selectedSession(sessionID),
            dimensions: VisualizationExportDimensions(preset: .custom, width: 640, height: 360)
        )
        guard let model = VisualizationExportRenderModelBuilder.makeRenderModel(
            request: request,
            sessions: [makeSession(id: sessionID)]
        ) else {
            throw TestExportError.missingRenderModel
        }
        return model
    }

    private func makeSession(id: UUID) -> SessionRecord {
        let startedAt = Date(timeIntervalSince1970: 100)
        return SessionRecord(
            id: id,
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                inspectionKind: .interceptedTLS,
                host: "api.example.com",
                port: 443,
                path: "/v1/start?token=secret",
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                bodyData: nil,
                bodySize: 256
            ),
            state: .completed,
            timing: SessionTiming(
                startedAt: startedAt,
                completedAt: startedAt.addingTimeInterval(0.25)
            )
        )
    }
}

private enum TestExportError: Error, Equatable {
    case missingRenderModel
    case writeFailed
}
