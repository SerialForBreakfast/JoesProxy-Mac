//
//  MCPVisualInspectionTests.swift
//  JoesProxyTests
//
//  Unit tests for MCP Visual Asset Inspection tool endpoints.
//

import XCTest
import AppKit
@testable import JoesProxy

@MainActor
final class MCPVisualInspectionTests: XCTestCase {

    func testMCPVisualAssetInspectionService() async throws {
        let store = InMemorySessionStore()
        let snapshot = MCPSessionSnapshotService(sessionStore: store)
        let service = MCPMediaInspectionService(sessionStore: store, snapshotService: snapshot)

        // 1. Create a 32x32 solid green bitmap image session
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 32,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 32 * 4,
            bitsPerPixel: 32
        )!

        for x in 0..<32 {
            for y in 0..<32 {
                rep.setColor(NSColor(calibratedRed: 0.0, green: 1.0, blue: 0.0, alpha: 1.0), atX: x, y: y)
            }
        }

        let pngData = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])!
        let imageSession = makeSession(
            path: "/assets/banner.png",
            body: pngData,
            contentType: "image/png"
        )

        store.append(imageSession)

        // 2. Call MCP visualAssetInspection
        let dto = try await service.visualAssetInspection(
            sessionID: imageSession.id,
            policyRevision: .initial
        )

        XCTAssertEqual(dto.pixelWidth, 32)
        XCTAssertEqual(dto.pixelHeight, 32)
        XCTAssertEqual(dto.aspectRatioString, "1:1")
        XCTAssertFalse(dto.dominantPalette.isEmpty)
        XCTAssertEqual(dto.dominantPalette.first?.hex, "#00FF00")
        XCTAssertFalse(dto.isFullyTransparent)
        XCTAssertEqual(dto.inspectedFrameCount, 1)
        XCTAssertEqual(dto.totalFrameCount, 1)
    }

    // MARK: - Helper

    private func makeSession(
        path: String,
        body: Data,
        contentType: String
    ) -> SessionRecord {
        let request = CapturedRequest(
            method: "GET",
            scheme: .https,
            host: "cdn.example.com",
            port: 443,
            path: path,
            headers: [],
            bodyData: nil,
            bodySize: nil
        )

        let response = CapturedResponse(
            statusCode: 200,
            headers: [
                HTTPHeaderField(name: "Content-Type", value: contentType),
                HTTPHeaderField(name: "Content-Length", value: "\(body.count)")
            ],
            bodyData: body,
            bodySize: body.count
        )

        return SessionRecord(
            request: request,
            response: response,
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )
    }
}
