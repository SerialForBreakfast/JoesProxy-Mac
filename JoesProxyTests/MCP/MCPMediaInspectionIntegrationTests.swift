import Foundation
import XCTest
@testable import JoesProxy

@MainActor
final class MCPMediaInspectionIntegrationTests: XCTestCase {
    func testMediaInspectionStartRequiresApproval() async throws {
        let stack = try await makeStack()
        let response = try await callMediaInspectionStart(
            stack: stack,
            sessionID: stack.tsSession.id,
            analyses: ["binary_container"]
        )
        XCTAssertEqual(response.errorData?["mcpCode"] as? String, MCPErrorCode.approvalRequired.rawValue)
        XCTAssertEqual(stack.approvalStore.pendingCount, 1)
        XCTAssertEqual(stack.operationCoordinator.activeAnalysisCount, 0)
        XCTAssertEqual(stack.trackingMediaService.inspectCallCount, 0)
    }

    func testApprovedMediaInspectionStartCompletesViaOperationStatus() async throws {
        let stack = try await makeStack(mediaService: ImmediateMediaOperationService())
        let first = try await callMediaInspectionStart(
            stack: stack,
            sessionID: stack.tsSession.id,
            analyses: ["binary_container"]
        )
        let requestID = try XCTUnwrap(first.requestID)
        let authorization = try stack.approvalStore.approve(requestID: requestID)
        let authObject = try authorizationJSONObject(authorization)

        let start = try await callMediaInspectionStart(
            stack: stack,
            sessionID: stack.tsSession.id,
            analyses: ["binary_container"],
            approval: authObject
        )
        XCTAssertNil(start.errorData)
        let descriptor = try decodeOperationDescriptor(from: start.result)
        XCTAssertEqual(descriptor.status, .running)
        XCTAssertEqual(stack.operationCoordinator.activeAnalysisCount, 1)

        let terminal = try await waitForTerminalOperation(
            stack: stack,
            operationID: descriptor.operationID
        )
        XCTAssertTrue([MCPOperationStatus.completed, .partial].contains(terminal.status))
        XCTAssertNotNil(terminal.result)
        XCTAssertEqual(stack.operationCoordinator.activeAnalysisCount, 0)
    }

    func testReplaySameApprovalIsRejectedForMediaInspection() async throws {
        let stack = try await makeStack(mediaService: ImmediateMediaOperationService())
        _ = try await callMediaInspectionStart(
            stack: stack,
            sessionID: stack.tsSession.id,
            analyses: ["transport_structure"]
        )
        let requestID = try XCTUnwrap(stack.approvalStore.pendingRequests.first?.requestID)
        let authorization = try stack.approvalStore.approve(requestID: requestID)
        let authObject = try authorizationJSONObject(authorization)
        let accepted = try await callMediaInspectionStart(
            stack: stack,
            sessionID: stack.tsSession.id,
            analyses: ["transport_structure"],
            approval: authObject
        )
        let descriptor = try decodeOperationDescriptor(from: accepted.result)
        _ = try await waitForTerminalOperation(
            stack: stack,
            operationID: descriptor.operationID
        )
        let replay = try await callMediaInspectionStart(
            stack: stack,
            sessionID: stack.tsSession.id,
            analyses: ["transport_structure"],
            approval: authObject
        )
        XCTAssertEqual(replay.errorData?["mcpCode"] as? String, MCPErrorCode.approvalReused.rawValue)
    }

    func testGlobalBusyLimitViaTransport() async throws {
        let stack = try await makeStack(mediaService: SuspendedIntegrationMediaService())
        let secondEnrollment = try stack.clientRegistry.enroll(displayName: "Second client")
        let secondSessionID = try await initializeSession(
            protocolService: stack.protocolService,
            bearer: secondEnrollment.plaintextCredential
        )
        let thirdEnrollment = try stack.clientRegistry.enroll(displayName: "Third client")
        let thirdSessionID = try await initializeSession(
            protocolService: stack.protocolService,
            bearer: thirdEnrollment.plaintextCredential
        )

        _ = try await startApprovedInspection(
            stack: stack,
            sessionID: stack.tsSession.id,
            analyses: ["gop_frames"]
        )
        _ = try await startApprovedInspection(
            stack: stack,
            sessionID: stack.tsSession.id,
            analyses: ["id3_timed_metadata"],
            bearer: secondEnrollment.plaintextCredential,
            transportSessionID: secondSessionID
        )
        XCTAssertEqual(stack.operationCoordinator.activeAnalysisCount, 2)

        let busy = try await callMediaInspectionStart(
            stack: stack,
            bearer: thirdEnrollment.plaintextCredential,
            transportSessionID: thirdSessionID,
            sessionID: stack.tsSession.id,
            analyses: ["binary_container"]
        )
        XCTAssertEqual(busy.errorData?["mcpCode"] as? String, MCPErrorCode.busy.rawValue)
        XCTAssertNil(busy.requestID)
        stack.operationCoordinator.cancelAll()
    }

    func testCrossClientOperationStatusIsDenied() async throws {
        let stack = try await makeStack(mediaService: SuspendedIntegrationMediaService())
        let secondEnrollment = try stack.clientRegistry.enroll(displayName: "Other client")
        let secondSessionID = try await initializeSession(
            protocolService: stack.protocolService,
            bearer: secondEnrollment.plaintextCredential
        )
        let descriptor = try await startApprovedInspection(
            stack: stack,
            sessionID: stack.tsSession.id,
            analyses: ["binary_container"]
        )

        let denied = try await callOperationStatus(
            stack: stack,
            bearer: secondEnrollment.plaintextCredential,
            transportSessionID: secondSessionID,
            operationID: descriptor.operationID
        )
        XCTAssertEqual(denied.errorData?["mcpCode"] as? String, MCPErrorCode.malformedRequest.rawValue)
    }

    func testOperationCancelIsIdempotent() async throws {
        let stack = try await makeStack(mediaService: SuspendedIntegrationMediaService())
        let descriptor = try await startApprovedInspection(
            stack: stack,
            sessionID: stack.tsSession.id,
            analyses: ["gop_frames"]
        )
        let firstCancel = try await callOperationCancel(
            stack: stack,
            operationID: descriptor.operationID
        )
        XCTAssertEqual(try decodeOperationDescriptor(from: firstCancel.result).status, .cancelling)

        let terminal = try await waitForTerminalOperation(
            stack: stack,
            operationID: descriptor.operationID
        )
        XCTAssertEqual(terminal.status, .cancelled)

        let secondCancel = try await callOperationCancel(
            stack: stack,
            operationID: descriptor.operationID
        )
        XCTAssertEqual(try decodeOperationDescriptor(from: secondCancel.result).status, .cancelled)
    }

    func testSessionRemovalCancelsActiveInspection() async throws {
        let stack = try await makeStack(mediaService: SuspendedIntegrationMediaService())
        _ = try await startApprovedInspection(
            stack: stack,
            sessionID: stack.tsSession.id,
            analyses: ["transport_structure"]
        )
        XCTAssertEqual(stack.operationCoordinator.activeAnalysisCount, 1)
        stack.sessionStore.remove(ids: Set([stack.tsSession.id]))
        for _ in 0..<100 where stack.operationCoordinator.activeAnalysisCount > 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(stack.operationCoordinator.activeAnalysisCount, 0)
    }

    func testClientRevokeCancelsActiveInspection() async throws {
        let stack = try await makeStack(mediaService: SuspendedIntegrationMediaService())
        _ = try await startApprovedInspection(
            stack: stack,
            sessionID: stack.tsSession.id,
            analyses: ["binary_container"]
        )
        try stack.clientRegistry.revoke(clientID: stack.enrollment.client.id)
        stack.protocolService.invalidateSessions(for: stack.enrollment.client.id)
        stack.operationCoordinator.cancelOperations(forClientID: stack.enrollment.client.id)
        for _ in 0..<100 where stack.operationCoordinator.activeAnalysisCount > 0 {
            await Task.yield()
        }
        XCTAssertEqual(stack.operationCoordinator.activeAnalysisCount, 0)
    }

    func testOperationStatusSurvivesSeparateHTTPRequestsWithSameLogicalSession() async throws {
        let stack = try await makeStack(mediaService: SuspendedIntegrationMediaService())
        let descriptor = try await startApprovedInspection(
            stack: stack,
            sessionID: stack.tsSession.id,
            analyses: ["gop_frames"]
        )

        let compactPoll = try await callTool(
            stack: stack,
            name: "operation_status",
            arguments: ["operationID": descriptor.operationID]
        )
        let compactResult = try XCTUnwrap(compactPoll.result)
        let compactStructured = try XCTUnwrap(compactResult["structuredContent"] as? [String: Any])
        let compactPayload = try XCTUnwrap(compactStructured["payload"] as? [String: Any])
        XCTAssertEqual(compactPayload["operationID"] as? String, descriptor.operationID)
        XCTAssertEqual(compactPayload["status"] as? String, MCPOperationStatus.running.rawValue)
        XCTAssertEqual(compactPayload["resultAvailable"] as? Bool, false)
        XCTAssertEqual(compactPayload["retryAfterMs"] as? Int, 500)
        XCTAssertNil(compactPayload["result"])
        XCTAssertNil(compactPayload["stages"])

        let firstPoll = try await callOperationStatus(
            stack: stack,
            operationID: descriptor.operationID
        )
        XCTAssertNil(firstPoll.errorData)
        XCTAssertEqual(
            try decodeOperationDescriptor(from: firstPoll.result).operationID,
            descriptor.operationID
        )

        let secondPoll = try await callOperationStatus(
            stack: stack,
            operationID: descriptor.operationID
        )
        XCTAssertNil(secondPoll.errorData)
        XCTAssertEqual(
            try decodeOperationDescriptor(from: secondPoll.result).status,
            .running
        )
        stack.operationCoordinator.cancelAll()
    }

    func testReadOnlyMediaToolsDoNotInvokeExpensiveInspect() async throws {
        let stack = try await makeStack()
        _ = try await callTool(
            stack: stack,
            name: "resources/list",
            arguments: [:]
        )
        _ = try await callTool(
            stack: stack,
            name: "media_summary",
            arguments: ["sessionID": stack.hlsSession.id.uuidString]
        )
        _ = try await callTool(
            stack: stack,
            name: "media_manifest_structure",
            arguments: ["sessionID": stack.hlsSession.id.uuidString]
        )
        XCTAssertEqual(stack.trackingMediaService.inspectCallCount, 0)
        XCTAssertEqual(stack.trackingMediaService.inspectionSourceCallCount, 0)
        XCTAssertEqual(stack.operationCoordinator.activeAnalysisCount, 0)
    }

    // MARK: - Stack

    private struct TestStack {
        let protocolService: MCPProtocolService
        let approvalStore: MCPApprovalStore
        let policyStore: MCPPolicyStore
        let clientRegistry: MCPClientRegistry
        let sessionStore: InMemorySessionStore
        let operationCoordinator: MCPOperationCoordinator
        let trackingMediaService: TrackingMediaOperationService
        let enrollment: MCPClientRegistry.EnrollmentResult
        let transportSessionID: String
        let hlsSession: SessionRecord
        let tsSession: SessionRecord
    }

    private struct ToolResponse {
        let result: [String: Any]?
        let errorData: [String: Any]?
        let requestID: String?
    }

    private func makeStack(
        mediaService: (any MCPMediaOperationServicing)? = nil
    ) async throws -> TestStack {
        let credentialStore = MCPInMemoryCredentialStore()
        let policyStore = MCPPolicyStore(persistenceURL: temporaryURL(named: "policy-media-integration.json"))
        policyStore.load()
        let clientRegistry = MCPClientRegistry(
            persistenceURL: temporaryURL(named: "clients-media-integration.json"),
            credentialStore: credentialStore
        )
        try clientRegistry.load()
        let auditStore = MCPAuditStore(persistenceURL: temporaryURL(named: "audit-media-integration.json"))
        auditStore.load()
        let approvalStore = MCPApprovalStore()
        let sessionStore = InMemorySessionStore()

        let hlsBody = Data("""
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=1280x720,CODECS="avc1.4d401f"
        https://cdn.example.com/video.m3u8?token=secret
        """.utf8)
        let hlsSession = makeMediaSession(
            path: "/master.m3u8",
            mimeType: "application/vnd.apple.mpegurl",
            body: hlsBody
        )
        let tsSession = makeMediaSession(
            path: "/segment.ts",
            mimeType: "video/mp2t",
            body: Data(repeating: 0x47, count: 188 * 4)
        )
        sessionStore.append(hlsSession)
        sessionStore.append(tsSession)

        let snapshotService = MCPSessionSnapshotService(sessionStore: sessionStore)
        let trackingMediaService = TrackingMediaOperationService(
            underlying: mediaService ?? ImmediateMediaOperationService()
        )
        let operationCoordinator = MCPOperationCoordinator(
            sessionStore: sessionStore,
            mediaService: trackingMediaService,
            snapshotService: snapshotService,
            policyStore: policyStore,
            auditStore: auditStore
        )
        let protocolService = MCPProtocolService(
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            auditStore: auditStore,
            snapshotService: snapshotService,
            approvalStore: approvalStore,
            mediaInspectionService: MCPMediaInspectionService(
                sessionStore: sessionStore,
                snapshotService: snapshotService
            ),
            operationCoordinator: operationCoordinator
        )
        let enrollment = try clientRegistry.enroll(
            displayName: "Media integration",
            assignedProfileID: .shareable
        )
        let transportSessionID = try await initializeSession(
            protocolService: protocolService,
            bearer: enrollment.plaintextCredential
        )
        return TestStack(
            protocolService: protocolService,
            approvalStore: approvalStore,
            policyStore: policyStore,
            clientRegistry: clientRegistry,
            sessionStore: sessionStore,
            operationCoordinator: operationCoordinator,
            trackingMediaService: trackingMediaService,
            enrollment: enrollment,
            transportSessionID: transportSessionID,
            hlsSession: hlsSession,
            tsSession: tsSession
        )
    }

    private func startApprovedInspection(
        stack: TestStack,
        sessionID: SessionRecord.ID,
        analyses: [String],
        bearer: String? = nil,
        transportSessionID: String? = nil
    ) async throws -> MCPOperationDescriptorDTO {
        _ = try await callMediaInspectionStart(
            stack: stack,
            bearer: bearer,
            transportSessionID: transportSessionID,
            sessionID: sessionID,
            analyses: analyses
        )
        let requestID = try XCTUnwrap(stack.approvalStore.pendingRequests.last?.requestID)
        let authorization = try stack.approvalStore.approve(requestID: requestID)
        let authObject = try authorizationJSONObject(authorization)
        let start = try await callMediaInspectionStart(
            stack: stack,
            bearer: bearer,
            transportSessionID: transportSessionID,
            sessionID: sessionID,
            analyses: analyses,
            approval: authObject
        )
        return try decodeOperationDescriptor(from: start.result)
    }

    private func callMediaInspectionStart(
        stack: TestStack,
        bearer: String? = nil,
        transportSessionID: String? = nil,
        sessionID: SessionRecord.ID,
        analyses: [String],
        approval: [String: Any]? = nil
    ) async throws -> ToolResponse {
        var arguments: [String: Any] = [
            "sessionID": sessionID.uuidString,
            "analyses": analyses
        ]
        if let approval { arguments["approval"] = approval }
        return try await callTool(
            stack: stack,
            bearer: bearer,
            transportSessionID: transportSessionID,
            name: "media_inspection_start",
            arguments: arguments
        )
    }

    private func callOperationStatus(
        stack: TestStack,
        bearer: String? = nil,
        transportSessionID: String? = nil,
        operationID: String
    ) async throws -> ToolResponse {
        try await callTool(
            stack: stack,
            bearer: bearer,
            transportSessionID: transportSessionID,
            name: "operation_status",
            arguments: ["operationID": operationID, "projection": "full"]
        )
    }

    private func callOperationCancel(
        stack: TestStack,
        operationID: String
    ) async throws -> ToolResponse {
        try await callTool(
            stack: stack,
            name: "operation_cancel",
            arguments: ["operationID": operationID, "projection": "full"]
        )
    }

    private func callTool(
        stack: TestStack,
        bearer: String? = nil,
        transportSessionID: String? = nil,
        name: String,
        arguments: [String: Any]
    ) async throws -> ToolResponse {
        let bodyObject: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Int.random(in: 1...999_999),
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": arguments
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: bodyObject)
        let response = await stack.protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(
                bearer: bearer ?? stack.enrollment.plaintextCredential,
                sessionID: transportSessionID ?? stack.transportSessionID
            ),
            body: body
        )
        let object = try response.jsonBodyObject()
        if let error = object["error"] as? [String: Any],
           let data = error["data"] as? [String: Any] {
            return ToolResponse(
                result: nil,
                errorData: data,
                requestID: data["requestID"] as? String
            )
        }
        return ToolResponse(result: object["result"] as? [String: Any], errorData: nil, requestID: nil)
    }

    private func decodeOperationDescriptor(from result: [String: Any]?) throws -> MCPOperationDescriptorDTO {
        let result = try XCTUnwrap(result)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let payloadObject = try XCTUnwrap(structured["payload"] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: payloadObject)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MCPOperationDescriptorDTO.self, from: data)
    }

    private func waitForTerminalOperation(
        stack: TestStack,
        operationID: String
    ) async throws -> MCPOperationDescriptorDTO {
        for _ in 0..<200 {
            let poll = try await callOperationStatus(stack: stack, operationID: operationID)
            let descriptor = try decodeOperationDescriptor(from: poll.result)
            switch descriptor.status {
            case .completed, .partial, .failed, .cancelled, .expired:
                return descriptor
            case .pendingApproval, .running, .cancelling:
                await Task.yield()
            }
        }
        return try decodeOperationDescriptor(
            from: try await callOperationStatus(stack: stack, operationID: operationID).result
        )
    }

    private func authorizationJSONObject(_ authorization: MCPApprovalAuthorization) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(authorization)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func initializeSession(protocolService: MCPProtocolService, bearer: String) async throws -> String {
        let response = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: [
                "authorization": "Bearer \(bearer)",
                "content-type": "application/json",
                "host": "127.0.0.1:\(NetworkConstants.mcpDefaultPort)",
                "accept": "application/json, text/event-stream"
            ],
            body: Data("""
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}
            """.utf8)
        )
        let sessionID = try XCTUnwrap(response.headerValue(named: MCPNetworkConstants.sessionIDHeader))
        _ = await protocolService.handleHTTPRequest(
            method: "POST",
            path: MCPNetworkConstants.endpointPath,
            headers: authenticatedHeaders(bearer: bearer, sessionID: sessionID),
            body: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        )
        return sessionID
    }

    private func makeMediaSession(path: String, mimeType: String, body: Data) -> SessionRecord {
        SessionRecord(
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                host: "media.example.com",
                port: 443,
                path: path,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: mimeType)],
                bodyData: body,
                bodySize: body.count
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
    }

    private func authenticatedHeaders(bearer: String, sessionID: String) -> [String: String] {
        [
            "authorization": "Bearer \(bearer)",
            "content-type": "application/json",
            "host": "127.0.0.1:\(NetworkConstants.mcpDefaultPort)",
            "accept": "application/json, text/event-stream",
            MCPNetworkConstants.protocolVersionHeader.lowercased(): "2025-11-25",
            MCPNetworkConstants.sessionIDHeader.lowercased(): sessionID
        ]
    }

    private func temporaryURL(named: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + named)
    }
}

@MainActor
private final class TrackingMediaOperationService: MCPMediaOperationServicing {
    private let underlying: any MCPMediaOperationServicing
    private(set) var inspectCallCount = 0
    private(set) var inspectionSourceCallCount = 0

    init(underlying: any MCPMediaOperationServicing) {
        self.underlying = underlying
    }

    func inspectionSource(
        sessionID: SessionRecord.ID,
        analyses: [MCPMediaAnalysisKind]
    ) throws -> MCPMediaInspectionSource {
        inspectionSourceCallCount += 1
        return try underlying.inspectionSource(sessionID: sessionID, analyses: analyses)
    }

    func inspect(
        source: MCPMediaInspectionSource,
        analyses: [MCPMediaAnalysisKind],
        sampleTime: TimeInterval,
        policyRevision: MCPPolicyRevision,
        progress: @MainActor (Double, String) -> Void
    ) async throws -> MCPMediaInspectionResultDTO {
        inspectCallCount += 1
        return try await underlying.inspect(
            source: source,
            analyses: analyses,
            sampleTime: sampleTime,
            policyRevision: policyRevision,
            progress: progress
        )
    }
}

@MainActor
private final class ImmediateMediaOperationService: MCPMediaOperationServicing {
    func inspectionSource(
        sessionID: SessionRecord.ID,
        analyses: [MCPMediaAnalysisKind]
    ) throws -> MCPMediaInspectionSource {
        MCPMediaInspectionSource(
            sessionID: sessionID,
            data: Data(repeating: 0x47, count: 188 * 2),
            fileExtension: "ts",
            displayName: "Fixture"
        )
    }

    func inspect(
        source: MCPMediaInspectionSource,
        analyses: [MCPMediaAnalysisKind],
        sampleTime: TimeInterval,
        policyRevision: MCPPolicyRevision,
        progress: @MainActor (Double, String) -> Void
    ) async throws -> MCPMediaInspectionResultDTO {
        progress(1, "complete")
        return MCPMediaInspectionResultDTO(
            sessionID: source.sessionID.uuidString,
            analyses: analyses,
            binaryStructure: nil,
            gop: nil,
            id3: nil,
            mediaEngine: nil,
            diagnostics: [],
            warnings: [],
            disclosure: MCPMediaDisclosureContextDTO(
                captureEpoch: .initial,
                policyRevision: policyRevision,
                generatedAt: Date(),
                removedFields: ["rawBody"],
                partialResultReason: nil,
                truncated: false
            )
        )
    }
}

@MainActor
private final class SuspendedIntegrationMediaService: MCPMediaOperationServicing {
    func inspectionSource(
        sessionID: SessionRecord.ID,
        analyses: [MCPMediaAnalysisKind]
    ) throws -> MCPMediaInspectionSource {
        MCPMediaInspectionSource(
            sessionID: sessionID,
            data: Data(repeating: 0x47, count: 188 * 2),
            fileExtension: "ts",
            displayName: "Fixture"
        )
    }

    func inspect(
        source: MCPMediaInspectionSource,
        analyses: [MCPMediaAnalysisKind],
        sampleTime: TimeInterval,
        policyRevision: MCPPolicyRevision,
        progress: @MainActor (Double, String) -> Void
    ) async throws -> MCPMediaInspectionResultDTO {
        progress(0.25, analyses[0].rawValue)
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}
