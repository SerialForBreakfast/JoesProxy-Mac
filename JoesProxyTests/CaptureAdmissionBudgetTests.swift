import XCTest
@testable import JoesProxy

final class CaptureAdmissionBudgetTests: XCTestCase {
    func testFallbackSharesBoundsAndDoesNotClaimMissingRequests() throws {
        let budget = CaptureAdmissionBudget(byteLimit: 100, countLimit: 3)
        let full = try XCTUnwrap(budget.reserveCapture(bytes: 80, metadataBytes: 10))
        XCTAssertFalse(full.metadataOnly)
        let partial = try XCTUnwrap(budget.reserveCapture(bytes: 80, metadataBytes: 10))
        XCTAssertTrue(partial.metadataOnly)
        let last = try XCTUnwrap(budget.reserveCapture(bytes: 80, metadataBytes: 10))
        XCTAssertTrue(last.metadataOnly)
        XCTAssertNil(budget.reserveCapture(bytes: 80, metadataBytes: 10))
        XCTAssertEqual(budget.snapshot.reservedBytes, 100)
        XCTAssertEqual(budget.snapshot.pendingCaptures, 3)
        XCTAssertEqual(budget.snapshot.metadataOnlyCaptures, 2)
        XCTAssertEqual(budget.snapshot.rejectedCaptures, 1)
        XCTAssertEqual(budget.snapshot.gaps.first?.metadataOnlyCaptures, 2)
        XCTAssertEqual(budget.snapshot.gaps.first?.rejectedCaptures, 1)
        budget.release(full.id)
        XCTAssertTrue(budget.snapshot.paused, "Count hysteresis still applies")
        budget.release(partial.id)
        XCTAssertFalse(budget.snapshot.paused)
        budget.release(last.id)
        XCTAssertEqual(budget.snapshot.reservedBytes, 0)
        budget.setAccepting(false)
        XCTAssertNil(budget.reserveCapture(bytes: 80, metadataBytes: 10))
        XCTAssertEqual(budget.snapshot.metadataOnlyCaptures, 2)
    }

    func testMetadataCollectorCountsWithoutKeepingPayload() {
        let collector = BoundedCaptureAccumulator(limit: 0, countWithoutBody: true)
        let chunk = Data(repeating: 7, count: 65_536)
        for _ in 0..<100 { chunk.withUnsafeBytes { collector.append(bytes: $0) } }
        let body = collector.takeFinalizedBody()
        XCTAssertNil(body.data)
        XCTAssertEqual(body.size, 6_553_600)
        XCTAssertTrue(body.truncated)
        XCTAssertNil(collector.finalize().size)
    }

    func testOversizedBodyAllowanceFallsBackWithoutStickyPauseAndNeverExpandsBudget() throws {
        let budget = CaptureAdmissionBudget(byteLimit: 100, countLimit: 4)
        let fallback = try XCTUnwrap(budget.reserveCapture(bytes: Int.max, metadataBytes: 10))
        XCTAssertTrue(fallback.metadataOnly)
        XCTAssertFalse(budget.snapshot.paused)
        XCTAssertEqual(budget.snapshot.reservedBytes, 10)
        XCTAssertEqual(budget.snapshot.rejectedCaptures, 0)
        XCTAssertNotNil(budget.snapshot.gaps.first?.end)
        budget.release(fallback.id)
        XCTAssertNil(budget.reserveCapture(bytes: Int.max, metadataBytes: 101))
        XCTAssertEqual(budget.snapshot.reservedBytes, 0)
        XCTAssertFalse(budget.snapshot.paused)
        XCTAssertEqual(budget.snapshot.rejectedCaptures, 1)
    }

    func testStoppedAdmissionRejectsWithoutReportingAnOverloadGap() throws {
        let budget = CaptureAdmissionBudget(byteLimit: 100, countLimit: 10)
        let reservation = try XCTUnwrap(budget.reserve(bytes: 50))
        budget.setAccepting(false)
        XCTAssertNil(budget.reserve(bytes: 1))
        XCTAssertEqual(budget.snapshot.rejectedCaptures, 0)
        budget.release(reservation)
        XCTAssertEqual(budget.snapshot.reservedBytes, 0)
        budget.setAccepting(true)
        XCTAssertNotNil(budget.reserve(bytes: 1))
    }

    func testDisabledCollectorDoesNotRetainResponseBytes() {
        let collector = BoundedCaptureAccumulator(limit: 0)
        collector.append(data: Data(repeating: 7, count: 65_536))
        XCTAssertNil(collector.finalize().data)
        XCTAssertNil(collector.finalize().size)
    }
    func testReservationsBoundWorkBeforeTasksAndResumeOnlyBelowLowWater() throws {
        let budget = CaptureAdmissionBudget(byteLimit: 100, countLimit: 10)
        let first = try XCTUnwrap(budget.reserve(bytes: 60))
        let second = try XCTUnwrap(budget.reserve(bytes: 30))
        XCTAssertNil(budget.reserve(bytes: 20))
        XCTAssertTrue(budget.snapshot.paused)
        budget.release(second)
        XCTAssertNil(budget.reserve(bytes: 1))
        budget.release(first)
        XCTAssertFalse(budget.snapshot.paused)
        XCTAssertNotNil(budget.snapshot.lastGapEndedAt)
        XCTAssertEqual(budget.snapshot.reservedBytes, 0)
        XCTAssertEqual(budget.snapshot.peakReservedBytes, 90)
        XCTAssertNotNil(budget.reserve(bytes: 10))
        budget.release(first)
        XCTAssertEqual(budget.snapshot.reservedBytes, 10)
    }

    func testOversizedAdmissionDoesNotPermanentlyBlockSmallerCaptures() {
        let budget = CaptureAdmissionBudget(byteLimit: 10, countLimit: 2)
        XCTAssertNil(budget.reserve(bytes: 11))
        XCTAssertFalse(budget.snapshot.paused)
        XCTAssertNotNil(budget.snapshot.gaps.last?.end)
        XCTAssertNotNil(budget.reserve(bytes: 5))
        XCTAssertEqual(budget.snapshot.rejectedCaptures, 1)
    }

    func testOverflowIsRejectedWithoutTrappingOrPausingEmptyBudget() {
        XCTAssertNil(CaptureAdmissionBudget.reservationCost(requestBytes: 0, responseLimit: Int.max, headerBytes: 0))
        XCTAssertNil(CaptureAdmissionBudget.reservationCost(requestBytes: Int.max, responseLimit: 0, headerBytes: 0))
        let budget = CaptureAdmissionBudget()
        XCTAssertNil(budget.reserve(bytes: Int.max))
        XCTAssertFalse(budget.snapshot.paused)
        XCTAssertEqual(budget.snapshot.lastRejectionReason, .requestTooLarge)
    }

    func testRepeatedOversizedRejectionHasBoundedClosedHistory() {
        let budget = CaptureAdmissionBudget(byteLimit: 100, countLimit: 4)
        for _ in 0..<100 { XCTAssertNil(budget.reserve(bytes: 101)) }
        let snapshot = budget.snapshot
        XCTAssertEqual(snapshot.gaps.count, 64)
        XCTAssertTrue(snapshot.gaps.allSatisfy { $0.end != nil })
        XCTAssertNotNil(snapshot.evictedThrough)
        XCTAssertEqual(snapshot.rejectedCaptures, 100)
        XCTAssertFalse(snapshot.paused)
        XCTAssertEqual(snapshot.reservedBytes, 0)
    }

    func testDeliveryShrinkResumesWithoutNewTrafficAndReleaseIsIdempotent() throws {
        let budget = CaptureAdmissionBudget(byteLimit: 100, countLimit: 4)
        let id = try XCTUnwrap(budget.reserve(bytes: 90))
        budget.transition(id, to: .collecting)
        XCTAssertNil(budget.reserve(bytes: 20))
        XCTAssertTrue(budget.snapshot.statusText.contains("capture completion"))
        budget.transition(id, to: .storeDelivery)
        XCTAssertTrue(budget.snapshot.statusText.contains("store delivery"))
        budget.transition(id, to: .storeDelivery, retainedBytes: 40)
        XCTAssertFalse(budget.snapshot.paused)
        XCTAssertEqual(budget.snapshot.reservedBytes, 40)
        budget.transition(id, to: .storeDelivery, retainedBytes: 80)
        XCTAssertEqual(budget.snapshot.reservedBytes, 40)
        budget.release(id)
        budget.release(id)
        XCTAssertEqual(budget.snapshot.pendingCaptures, 0)
        XCTAssertEqual(budget.snapshot.reservedBytes, 0)
        XCTAssertNotNil(budget.snapshot.lastStoreDeliveryAt)
    }

    func testOversizedRejectionDoesNotCloseAnExistingCapacityGap() throws {
        let budget = CaptureAdmissionBudget(byteLimit: 100, countLimit: 4)
        let id = try XCTUnwrap(budget.reserve(bytes: 90))
        XCTAssertNil(budget.reserve(bytes: 20))
        XCTAssertNil(budget.reserve(bytes: 101))
        XCTAssertTrue(budget.snapshot.paused)
        XCTAssertNil(budget.snapshot.gaps.last?.end)
        budget.release(id)
        XCTAssertFalse(budget.snapshot.paused)
        XCTAssertEqual(budget.snapshot.gaps.count, 1)
        XCTAssertEqual(budget.snapshot.gaps.first?.rejectedCaptures, 2)
    }
}
