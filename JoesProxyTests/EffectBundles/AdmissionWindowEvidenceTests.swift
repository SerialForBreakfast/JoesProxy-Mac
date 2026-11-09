import Foundation
import XCTest
@testable import JoesProxy

final class AdmissionWindowEvidenceTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval = 10
        private var wall: TimeInterval = 100
        func now() -> CaptureObservationInstant {
            lock.withLock { .init(date: Date(timeIntervalSince1970: wall), uptime: time) }
        }
        func advance(wallDelta: TimeInterval = 1) {
            lock.withLock { time += 1; wall += wallDelta }
        }
    }

    func testMarkerWindowIncludesOpenAndClosedGapsDespiteWallClockRollback() throws {
        let clock = Clock()
        let budget = CaptureAdmissionBudget(byteLimit: 10, countLimit: 2, now: { clock.now() })
        let gate = EffectBundleActivationGate(now: { clock.now() })
        let bundle = UUID()
        let identity = EffectBundleResourceIdentity(bundleID: bundle, revisionID: UUID(), activationID: UUID(),
            resourceID: UUID(), assetID: "image", expectedSHA256: "synthetic")
        clock.advance()
        let receipt = gate.observe(resource: identity, servedSHA256: "synthetic")
        let baseline = gate.observationMarker()
        clock.advance(wallDelta: -50)
        let reservation = try XCTUnwrap(budget.reserve(bytes: 10))
        XCTAssertNil(budget.reserve(bytes: 1))
        XCTAssertNil(budget.reserve(bytes: 1))
        var page = gate.evidence(bundleID: bundle, after: baseline)
        var coverage = EffectBundleJoinedInspection.AdmissionCoverage(snapshot: budget.snapshot, window: page.window)
        XCTAssertEqual(coverage.historyState, "admissionGapsInWindow")
        XCTAssertEqual(coverage.overlappingRejectedCapturesUpperBound, 2)
        XCTAssertNil(coverage.overlappingGaps.first?.end)
        XCTAssertTrue(page.receipts.isEmpty)
        clock.advance()
        budget.release(reservation)
        gate.completeReceipt(id: receipt, succeeded: true)
        page = gate.evidence(bundleID: bundle, after: baseline)
        coverage = .init(snapshot: budget.snapshot, window: page.window)
        XCTAssertEqual(coverage.historyState, "admissionGapsInWindow")
        XCTAssertNotNil(coverage.overlappingGaps.first?.end)
        XCTAssertEqual(page.receipts.first?.delivery, .downstreamWriteSucceeded)
        clock.advance()
        let newer = gate.observe(resource: identity, servedSHA256: "synthetic")
        let afterGap = gate.observationMarker()
        clock.advance()
        gate.completeReceipt(id: newer, succeeded: true)
        coverage = .init(snapshot: budget.snapshot, window: gate.evidence(bundleID: bundle, after: afterGap).window)
        XCTAssertEqual(coverage.rejectedCaptures, 2)
        XCTAssertEqual(coverage.historyState, "noAdmissionGapInWindow")
        XCTAssertEqual(coverage.overlappingRejectedCapturesUpperBound, 0)
    }

    func testIdleEvidenceSamplingDoesNotChangePublishedMetrics() {
        let clock = Clock()
        let budget = CaptureAdmissionBudget(byteLimit: 1, now: { clock.now() })
        let diagnostics = CaptureTransportDiagnostics()
        diagnostics.observeAdmission(budget)
        let baseline = diagnostics.snapshot()
        clock.advance()
        let later = diagnostics.snapshot()
        XCTAssertNotEqual(baseline.captureAdmission?.observed, later.captureAdmission?.observed)
        XCTAssertEqual(baseline, later)
        XCTAssertNil(budget.reserve(bytes: 2))
        XCTAssertNotEqual(baseline, diagnostics.snapshot())
    }

    func testEmptyPagesEstablishFreshWindowsWithoutInventingRequests() throws {
        let clock = Clock()
        let budget = CaptureAdmissionBudget(byteLimit: 1, now: { clock.now() })
        let gate = EffectBundleActivationGate(now: { clock.now() })
        let bundle = UUID()
        clock.advance()
        XCTAssertNil(budget.reserve(bytes: 2))
        budget.setAccepting(false)
        budget.releaseStoppedReservations()
        clock.advance()
        let first = gate.evidence(bundleID: bundle)
        let initial = EffectBundleJoinedInspection.AdmissionCoverage(snapshot: budget.snapshot, window: first.window)
        XCTAssertEqual(initial.historyState, "admissionGapsInWindow")
        clock.advance()
        let second = gate.evidence(bundleID: bundle, after: first.nextMarker)
        let later = EffectBundleJoinedInspection.AdmissionCoverage(snapshot: budget.snapshot, window: second.window)
        XCTAssertEqual(later.historyState, "noAdmissionGapInWindow")
        XCTAssertTrue(first.receipts.isEmpty && second.receipts.isEmpty)
        XCTAssertGreaterThan(second.nextMarker, first.nextMarker)
        XCTAssertEqual(first.window?.end, second.window?.start)
    }

    func testHistoryEvictionShutdownAndRestartDoNotClaimCompleteCoverage() throws {
        let clock = Clock()
        let budget = CaptureAdmissionBudget(byteLimit: 1, countLimit: 1, now: { clock.now() })
        let gate = EffectBundleActivationGate(now: { clock.now() })
        for _ in 0..<70 {
            clock.advance()
            XCTAssertNil(budget.reserve(bytes: 2))
            budget.setAccepting(false)
            budget.releaseStoppedReservations()
            budget.setAccepting(true)
        }
        let snapshot = budget.snapshot
        XCTAssertEqual(snapshot.gaps.count, 64)
        XCTAssertEqual(snapshot.rejectedCaptures, 70)
        XCTAssertTrue(snapshot.gaps.allSatisfy { $0.end != nil })
        XCTAssertFalse(snapshot.paused)
        var coverage = EffectBundleJoinedInspection.AdmissionCoverage(snapshot: snapshot,
            window: gate.evidence(bundleID: UUID()).window)
        XCTAssertEqual(coverage.historyState, "admissionHistoryEvicted")
        let future = gate.evidence(bundleID: UUID(), after: 100)
        XCTAssertEqual(future.window?.startState, "futureOrRestartedMarker")
        coverage = .init(snapshot: snapshot, window: future.window)
        XCTAssertEqual(coverage.historyState, "receiptMarkerTimeUnavailable")
        clock.advance()
        let restarted = CaptureAdmissionBudget(now: { clock.now() })
        coverage = .init(snapshot: restarted.snapshot, window: gate.evidence(bundleID: UUID()).window)
        XCTAssertEqual(coverage.historyState, "windowPredatesAdmissionHistory")
    }

    func testPagingRetainsBoundariesAndExpiredMarkerTimeIsExplicit() throws {
        let clock = Clock()
        let gate = EffectBundleActivationGate(now: { clock.now() })
        let identity = EffectBundleResourceIdentity(bundleID: UUID(), revisionID: UUID(), activationID: UUID(),
            resourceID: UUID(), assetID: "image", expectedSHA256: "synthetic")
        for _ in 0..<40 {
            clock.advance()
            _ = gate.observe(resource: identity, servedSHA256: nil)
        }
        let first = gate.evidence(bundleID: identity.bundleID)
        let second = gate.evidence(bundleID: identity.bundleID, after: first.nextMarker)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.window?.end, second.window?.start)
        XCTAssertEqual(first.window?.throughMarker, first.nextMarker)
        XCTAssertEqual(first.window?.timelineID, second.window?.timelineID)
        XCTAssertEqual(first.receipts.count + second.receipts.count, 40)
        for _ in 0..<520 {
            clock.advance()
            _ = gate.observe(resource: identity, servedSHA256: nil)
        }
        let expired = gate.evidence(bundleID: identity.bundleID, after: first.nextMarker)
        XCTAssertEqual(expired.window?.startState, "markerTimeEvicted")
        XCTAssertNil(expired.window?.start)
        XCTAssertTrue(expired.retentionGap)
        XCTAssertLessThan(try JSONEncoder().encode(expired).count, 65_536)
    }
}
