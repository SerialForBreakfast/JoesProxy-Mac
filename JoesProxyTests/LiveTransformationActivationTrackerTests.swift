import Foundation
import XCTest
@testable import JoesProxy

final class LiveTransformationActivationTrackerTests: XCTestCase {
    private func makeTracker() -> LiveTransformationActivationTracker {
        // Not `.shared` — each test gets its own instance so tests can run in any order without
        // cross-test state leakage (the production singleton is a deliberate app-lifetime tracker,
        // not something tests should share).
        LiveTransformationActivationTracker()
    }

    func testRuleWithNoRecordedActivationFailsOpen() {
        let tracker = makeTracker()
        XCTAssertTrue(tracker.isWithinBudget(ruleID: UUID()))
        XCTAssertFalse(tracker.isExpired(ruleID: UUID()))
    }

    func testWithinLifetimeAndUnderHitCountIsWithinBudget() {
        let tracker = makeTracker()
        let ruleID = UUID()
        tracker.recordActivationStart(ruleID: ruleID, now: Date())
        XCTAssertTrue(tracker.isWithinBudget(ruleID: ruleID, now: Date(), lifetimeSeconds: 900, maxTransformedResponses: 100))
    }

    func testExpiresAfterLifetimeElapses() {
        let tracker = makeTracker()
        let ruleID = UUID()
        let start = Date()
        tracker.recordActivationStart(ruleID: ruleID, now: start)
        let afterLifetime = start.addingTimeInterval(901)
        XCTAssertTrue(tracker.isExpired(ruleID: ruleID, now: afterLifetime, lifetimeSeconds: 900))
        XCTAssertFalse(tracker.isWithinBudget(ruleID: ruleID, now: afterLifetime, lifetimeSeconds: 900, maxTransformedResponses: 100))
    }

    func testHitCountCapExhaustsBudgetBeforeLifetimeElapses() {
        let tracker = makeTracker()
        let ruleID = UUID()
        tracker.recordActivationStart(ruleID: ruleID, now: Date())
        for _ in 0..<3 {
            tracker.recordTransformed(ruleID: ruleID)
        }
        XCTAssertFalse(tracker.isWithinBudget(ruleID: ruleID, now: Date(), lifetimeSeconds: 900, maxTransformedResponses: 3))
        XCTAssertTrue(tracker.isWithinBudget(ruleID: ruleID, now: Date(), lifetimeSeconds: 900, maxTransformedResponses: 4))
    }

    func testClearResetsTrackingBackToFailOpenDefault() {
        let tracker = makeTracker()
        let ruleID = UUID()
        tracker.recordActivationStart(ruleID: ruleID, now: Date())
        tracker.recordTransformed(ruleID: ruleID)
        tracker.clear(ruleID: ruleID)
        XCTAssertTrue(tracker.isWithinBudget(ruleID: ruleID))
        XCTAssertFalse(tracker.isExpired(ruleID: ruleID))
    }

    func testResponseOverrideStoreEnablingLiveRewriteRuleStartsTrackingAndDisablingClearsIt() async throws {
        let store = ResponseOverrideStore()
        let ruleID = UUID()
        let rule = ResponseOverrideRule(
            id: ruleID,
            requestMethod: "GET",
            requestScheme: .https,
            host: "epg.example.test",
            port: 443,
            path: "/v1/guide",
            sourceKind: .liveResponseRewrite,
            sourceDescription: "Live response rewrite",
            statusCode: 200,
            headers: [],
            bodySource: .inline(nil),
            isEnabled: false,
            liveResponseRewrites: [
                BookmarkResponseFieldRewrite(jsonPath: "title", overrideValue: .string("!"), operation: .appendString)
            ]
        )
        try await store.addRule(rule)

        // Not yet enabled — no tracking should exist yet.
        XCTAssertFalse(LiveTransformationActivationTracker.shared.isExpired(ruleID: ruleID))

        try await store.setEnabled(true, for: ruleID)
        XCTAssertTrue(LiveTransformationActivationTracker.shared.isWithinBudget(ruleID: ruleID))

        try await store.setEnabled(false, for: ruleID)
        // After clearing, a lookup with a deliberately-already-elapsed lifetime must still report
        // "not expired" (no activation on record), proving the tracker state was actually cleared.
        XCTAssertFalse(
            LiveTransformationActivationTracker.shared.isExpired(
                ruleID: ruleID,
                now: Date().addingTimeInterval(10_000),
                lifetimeSeconds: 900
            )
        )
    }
}
