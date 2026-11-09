import XCTest
@testable import JoesProxy

@MainActor
final class MCPSelfValidationTests: XCTestCase {
    func testFixtureOriginsBindIndependentEphemeralPorts() async throws {
        let first = MCPSelfValidationFixtureOrigin()
        let second = MCPSelfValidationFixtureOrigin()
        do {
            try await first.start()
            try await second.start()
            XCTAssertNotEqual(first.port, 0)
            XCTAssertNotEqual(second.port, 0)
            XCTAssertNotEqual(first.port, second.port)
        } catch {
            await second.stop()
            await first.stop()
            throw error
        }
        await second.stop()
        await first.stop()
    }

    func testProxyLanesBindIndependentEphemeralPorts() async throws {
        let first = MCPSelfValidationProxyLane(lane: MCPSelfValidationLane(validationRunID: .generate()))
        let second = MCPSelfValidationProxyLane(lane: MCPSelfValidationLane(validationRunID: .generate()))
        XCTAssertEqual(first.port, 0, "The OS must allocate the port during binding, not a random preselection")
        XCTAssertEqual(second.port, 0)
        do {
            try await first.start()
            try await second.start()
            XCTAssertNotEqual(first.port, 0)
            XCTAssertNotEqual(second.port, 0)
            XCTAssertNotEqual(first.port, second.port)
        } catch {
            await second.stop()
            await first.stop()
            throw error
        }
        await second.stop()
        await first.stop()
    }

    func testStoreIsolationDoesNotTouchProductionSessionStore() async throws {
        let productionStore = InMemorySessionStore(retentionPolicy: .unlimited)
        let productionOverrides = ResponseOverrideStore()
        let coordinator = MCPSelfValidationCoordinator()

        let summary = try await coordinator.withRun(timeout: 30) { context in
            let definition = MCPScenarioDefinition(
                id: MCPScenarioID(rawValue: UUID().uuidString),
                schemaVersion: MCPScenarioSchemaVersion.current,
                name: "Isolation",
                purpose: "AI-5 isolation",
                originatingClientID: context.scenarioStack.validationClient.id,
                target: MCPScenarioTarget(appIdentifier: nil, environment: nil, hosts: ["127.0.0.1"], paths: nil),
                preconditions: [],
                captureScope: MCPScenarioCaptureScope(hosts: ["127.0.0.1"], includeBodies: false),
                disclosureProfileID: .shareable,
                faults: [],
                duration: 30,
                expiresAt: nil,
                observationWindow: MCPScenarioObservationWindow(startTrigger: "onActivate", duration: 30),
                assertions: [],
                assertionSeverity: .informational,
                evidenceRetentionSpec: MCPScenarioEvidenceRetentionSpec(maxRecords: 10, retention: 300),
                cleanupActions: [],
                createdAt: Date()
            )
            _ = try context.lane.scenarioStore.createScenario(definition, validationRunID: context.runID)
            XCTAssertEqual(context.lane.scenarioStore.scenarios.count, 1)
            XCTAssertEqual(context.lane.scenarioStore.scenarios.first?.validationRunID, context.runID)
            context.lane.auditStore.record(
                MCPAuditEvent(
                    id: UUID(),
                    kind: .toolCall,
                    timestamp: Date(),
                    clientID: context.scenarioStack.validationClient.id,
                    credentialFingerprint: nil,
                    sourceProcess: nil,
                    reasonCode: "self-validation:test",
                    detail: nil,
                    validationRunID: context.runID.rawValue
                )
            )
            XCTAssertEqual(context.lane.auditStore.events.first?.validationRunID, context.runID.rawValue)
        }

        XCTAssertEqual(summary.outcome, .succeeded)
        XCTAssertEqual(productionStore.sessions.count, 0)
        let productionRules = await productionOverrides.rules()
        XCTAssertTrue(productionRules.isEmpty)
        XCTAssertNil(coordinator.activeRun)
    }

    func testCaptureBindingRoutesSessionsToLaneStore() async throws {
        let productionStore = InMemorySessionStore(retentionPolicy: .unlimited)
        let coordinator = MCPSelfValidationCoordinator()

        try await coordinator.withRun(timeout: 30) { context in
            let session = context.makeProxiedURLSession()
            let url = context.fixtureBaseURL.appendingPathComponent(MCPSelfValidationFixtureRoute.ok.rawValue)
            let (data, response) = try await session.data(from: url)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 200)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), MCPSelfValidationFixtureRoute.ok.defaultBody)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(context.lane.sessionStore.sessions.count, 1)
            XCTAssertEqual(productionStore.sessions.count, 0)
        }
    }

    func testFixtureOriginReturnsDeterministicRouteBodies() async throws {
        let fixture = MCPSelfValidationFixtureOrigin()
        try await fixture.start()
        defer { Task { await fixture.stop() } }

        let session = URLSession(configuration: .ephemeral)
        for route in MCPSelfValidationFixtureRoute.allCases {
            let url = fixture.baseURL.appendingPathComponent(route.rawValue)
            let (data, response) = try await session.data(from: url)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, route.defaultStatusCode)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), route.defaultBody)
        }
    }

    func testTimeoutCleansUpActiveInfrastructure() async throws {
        let coordinator = MCPSelfValidationCoordinator()

        do {
            _ = try await coordinator.withRun(timeout: 0.2) { _ in
                try await Task.sleep(for: .seconds(2))
            }
            XCTFail("expected timeout")
        } catch let error as MCPSelfValidationError {
            XCTAssertEqual(error, .timedOut)
        }

        XCTAssertNil(coordinator.activeRun)
        XCTAssertEqual(coordinator.lastCompletedRun?.outcome, .timedOut)
    }

    func testCleanupFailureSurfacesWhenScenarioRemainsUnresolved() async throws {
        let coordinator = MCPSelfValidationCoordinator()

        do {
            _ = try await coordinator.withRun(timeout: 30) { context in
                let definition = MCPScenarioDefinition(
                    id: MCPScenarioID(rawValue: UUID().uuidString),
                    schemaVersion: MCPScenarioSchemaVersion.current,
                    name: "Stuck",
                    purpose: "cleanup failure",
                    originatingClientID: context.scenarioStack.validationClient.id,
                    target: MCPScenarioTarget(appIdentifier: nil, environment: nil, hosts: ["127.0.0.1"], paths: nil),
                    preconditions: [],
                    captureScope: MCPScenarioCaptureScope(hosts: ["127.0.0.1"], includeBodies: false),
                    disclosureProfileID: .shareable,
                    faults: [],
                    duration: 30,
                    expiresAt: nil,
                    observationWindow: MCPScenarioObservationWindow(startTrigger: "onActivate", duration: 30),
                    assertions: [],
                    assertionSeverity: .informational,
                    evidenceRetentionSpec: MCPScenarioEvidenceRetentionSpec(maxRecords: 10, retention: 300),
                    cleanupActions: [],
                    createdAt: Date()
                )
                var record = try context.lane.scenarioStore.createScenario(definition, validationRunID: context.runID)
                record.phase = .running
                try context.lane.scenarioStore.updateScenario(record)
            }
            XCTFail("expected cleanup failure")
        } catch let error as MCPSelfValidationError {
            if case .cleanupFailed = error {
                return
            }
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(coordinator.lastCompletedRun?.outcome, .cleanupFailed)
    }

    // T2: a real dropped connection (no HTTP response at all) is observably different, over the
    // real proxy pipeline, from a clean status-code block — proving JoesProxy can reproduce both
    // failure modes a real dependency's recovery logic might branch on.
    func testDropConnectionBlockClosesConnectionInsteadOfServingStatusCode() async throws {
        let coordinator = MCPSelfValidationCoordinator()

        try await coordinator.withRun(timeout: 30) { context in
            let session = context.makeProxiedURLSession()
            let route = MCPSelfValidationFixtureRoute.ok
            let request = CapturedRequest(
                method: "GET",
                scheme: .http,
                host: context.fixtureBaseURL.host ?? "127.0.0.1",
                port: context.fixtureBaseURL.port ?? 0,
                path: route.rawValue,
                headers: [],
                bodyData: nil,
                bodySize: nil
            )
            try await context.lane.responseOverrideStore.addBlockRule(
                from: request,
                statusCode: 503,
                label: "T2 drop connection",
                dropConnection: true
            )

            let url = context.fixtureBaseURL.appendingPathComponent(route.rawValue)
            do {
                _ = try await session.data(from: url)
                XCTFail("Expected the dropped connection to fail the request, got a response instead")
            } catch let error as URLError {
                // A dropped connection surfaces as a transport-level failure (reset/closed/lost),
                // never as a successful response with a status code — that's the entire point of
                // this fault mode versus a clean synthetic block.
                XCTAssertTrue(
                    [.networkConnectionLost, .cannotConnectToHost, .badServerResponse, .timedOut].contains(error.code),
                    "Unexpected URLError code for dropped connection: \(error.code)"
                )
            }
        }
    }
}
