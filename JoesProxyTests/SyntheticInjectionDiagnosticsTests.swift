import XCTest
@testable import JoesProxy

final class SyntheticInjectionDiagnosticsTests: XCTestCase {
    func testReceiptsCorrelateCaptureAndKeepWriteOutcomeSeparateFromRendering() throws {
        let engine = SyntheticCollectionInjectionEngine()
        let plan = plan()
        engine.registerPlan(plan)
        for success in [true, false] {
            let requestID = UUID(), sessionID = UUID()
            XCTAssertNotNil(engine.processResponse(responseData: Data(#"{"items":[{"id":"original"}]}"#.utf8),
                requestURL: "/items", requestHeaders: [], requestID: requestID))
            engine.updateReceipt(requestID: requestID, writeSucceeded: success)
            engine.updateReceipt(requestID: requestID, sessionID: sessionID)
            engine.updateReceipt(requestID: requestID, writeSucceeded: !success)
            let receipt = try XCTUnwrap(engine.diagnostics(planID: plan.id)?.receipts.last)
            XCTAssertEqual(receipt.requestID, requestID)
            XCTAssertEqual(receipt.sessionID, sessionID)
            XCTAssertEqual(receipt.deliveryState, success ? .downstreamWriteSucceeded : .downstreamWriteFailed)
            XCTAssertNotNil(receipt.deliveryObservedAt)
            XCTAssertEqual(receipt.targetOutcome, "unknown")
        }
    }

    func testReceiptEvictionAndRegistrationReplacementIgnoreLateCallbacks() throws {
        let engine = SyntheticCollectionInjectionEngine()
        let plan = plan()
        engine.registerPlan(plan)
        let oldRequest = UUID()
        let body = Data(#"{"items":[{"id":"original"}]}"#.utf8)
        _ = engine.processResponse(responseData: body, requestURL: "/items", requestHeaders: [], requestID: oldRequest)
        let oldReceipt = try XCTUnwrap(engine.diagnostics(planID: plan.id)?.receipts.last)
        for _ in 0..<40 { _ = engine.processResponse(responseData: body, requestURL: "/items", requestHeaders: []) }
        engine.updateReceipt(requestID: oldRequest, writeSucceeded: true)
        XCTAssertEqual(engine.diagnostics(planID: plan.id)?.receipts.count, 32)
        XCTAssertFalse(engine.hasReceipt(requestID: oldRequest))
        engine.registerPlan(plan)
        _ = engine.executeInjection(plan: plan, responseData: body, requestURL: "/items",
            attribution: .init(requestID: oldRequest, registrationID: oldReceipt.registrationID))
        engine.updateReceipt(requestID: oldRequest, writeSucceeded: true)
        XCTAssertEqual(engine.diagnostics(planID: plan.id)?.receipts, [])
        XCTAssertEqual(engine.diagnostics(planID: plan.id)?.counts, [:])
    }

    func testSkippedRequestCannotAcquireSuccessfulMutationDelivery() throws {
        let engine = SyntheticCollectionInjectionEngine()
        let plan = plan(), requestID = UUID(), sessionID = UUID()
        engine.registerPlan(plan)
        XCTAssertTrue(engine.observeEligibility(requestURL: "/items", headers: [],
            bypassReason: .unsupportedMedia, requestID: requestID))
        engine.updateReceipt(requestID: requestID, sessionID: sessionID, writeSucceeded: true)
        let receipt = try XCTUnwrap(engine.diagnostics(planID: plan.id)?.receipts.first)
        XCTAssertEqual(receipt.sessionID, sessionID)
        XCTAssertEqual(receipt.reason, .unsupportedMedia)
        XCTAssertEqual(receipt.deliveryState, .notApplied)
        XCTAssertNil(receipt.deliveryObservedAt)
    }

    private func plan() -> SyntheticCollectionInjectionPlan {
        .init(name: "Synthetic", urlPattern: "/items", collectionKeypath: "$.items",
            boundAssetKind: nil, clientScope: .allClients)
    }

    func testSeparateBodyFailuresRetainOnlyBoundedReasons() throws {
        for (body, reason) in [("not json", SyntheticInjectionReason.invalidJSON),
                               (#"{"other":[]}"#, .collectionMissing),
                               (#"{"items":{}}"#, .collectionNotArray),
                               (#"{"items":[]}"#, .emptyCollection),
                               (#"{"items":[1]}"#, .templateNotObject)] {
            let engine = SyntheticCollectionInjectionEngine()
            let plan = plan()
            engine.registerPlan(plan)
            XCTAssertNil(engine.processResponse(responseData: Data(body.utf8), requestURL: "https://api.example.test/items", requestHeaders: []))
            let diagnostic = try XCTUnwrap(engine.diagnostics(planID: plan.id))
            XCTAssertEqual(diagnostic.lastReason, reason)
            XCTAssertEqual(diagnostic.counts[reason.rawValue], 1)
            XCTAssertEqual(diagnostic.deliveryState, "unknown")
            let json = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
            XCTAssertFalse(json.contains("api.example.test"))
            XCTAssertFalse(json.contains(body))
        }
    }

    func testEligibilityMissesAndBypassesAreNotTransformations() {
        let engine = SyntheticCollectionInjectionEngine()
        var plan = plan()
        plan.clientScope = .customHeader(name: "X-Synthetic", valueContains: "yes")
        engine.registerPlan(plan)
        XCTAssertFalse(engine.observeEligibility(requestURL: "/other", headers: []))
        XCTAssertFalse(engine.observeEligibility(requestURL: "/items", headers: []))
        let headers = [HTTPHeaderField(name: "X-Synthetic", value: "yes")]
        XCTAssertTrue(engine.observeEligibility(requestURL: "/items", headers: headers, bypassReason: .unsupportedMedia))
        engine.recordBufferLimit(requestURL: "/items", headers: headers)
        let counts = engine.diagnostics(planID: plan.id)?.counts
        XCTAssertEqual(counts?["urlMismatch"], 1)
        XCTAssertEqual(counts?["clientScopeMismatch"], 1)
        XCTAssertEqual(counts?["unsupportedMedia"], 1)
        XCTAssertEqual(counts?["inputTooLarge"], 1)
        XCTAssertNil(counts?["transformed"])
    }

    func testTransformationAndRemovalDoNotClaimDelivery() throws {
        let engine = SyntheticCollectionInjectionEngine()
        let plan = plan()
        engine.registerPlan(plan)
        for _ in 0..<100 {
            XCTAssertNotNil(engine.processResponse(responseData: Data(#"{"items":[{"id":"original"}]}"#.utf8),
                requestURL: "/items", requestHeaders: []))
        }
        let diagnostic = try XCTUnwrap(engine.diagnostics(planID: plan.id))
        XCTAssertEqual(diagnostic.counts, ["transformed": 100])
        XCTAssertEqual(diagnostic.targetOutcome, "unknown")
        engine.removePlan(id: plan.id)
        XCTAssertNil(engine.diagnostics(planID: plan.id))
        engine.registerPlan(plan)
        XCTAssertEqual(engine.diagnostics(planID: plan.id)?.counts, [:])
        engine.clearAllPlans()
        XCTAssertNil(engine.diagnostics(planID: plan.id))
    }
}
