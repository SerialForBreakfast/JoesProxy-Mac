import XCTest
@testable import JoesProxy

@MainActor
final class AVMediaMetadataOperationTests: XCTestCase {
    private final class Gate {
        var continuation: CheckedContinuation<Int, Never>?
        func wait() async -> Int { await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(returning: 42); continuation = nil }
    }

    func testSuccessDoesNotCancelFrameworkLoading() async throws {
        var stops = 0
        let result = try await AVMediaMetadataOperation.run(timeout: .seconds(1)) { 42 }
            stop: { stops += 1 }
        XCTAssertEqual(result, 42)
        XCTAssertEqual(stops, 0)
    }

    func testDeadlineStopsFrameworkBeforeStructuredDrainAndRejectsRacingSuccess() async {
        let gate = Gate()
        defer { gate.release() }
        var stops = 0
        do {
            _ = try await AVMediaMetadataOperation.run(timeout: .milliseconds(30)) {
                await gate.wait()
            } stop: { stops += 1; gate.release() }
            XCTFail("Deadline must win over the value released by cancellation")
        } catch AVMediaMetadataOperation.Failure.timedOut {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(stops, 1)
        XCTAssertNil(gate.continuation)
    }

    func testCancellationStopsFrameworkAndDrainsOperation() async {
        let gate = Gate()
        defer { gate.release() }
        var stops = 0
        let worker = Task {
            try await AVMediaMetadataOperation.run(timeout: .seconds(30)) {
                await gate.wait()
            } stop: { stops += 1; gate.release() }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while gate.continuation == nil, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertNotNil(gate.continuation)
        worker.cancel()
        do { _ = try await worker.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(stops, 1)
        XCTAssertNil(gate.continuation)
    }

    func testPreCancellationDoesNotStartOrStopFramework() async {
        var started = false
        var stopped = false
        let worker = Task {
            try await AVMediaMetadataOperation.run(timeout: .seconds(1)) {
                started = true; return 42
            } stop: { stopped = true }
        }
        worker.cancel()
        do { _ = try await worker.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(started)
        XCTAssertFalse(stopped)
    }

    func testOperationFailurePreservesErrorAndStopsRemainingLoading() async {
        enum Expected: Error { case failure }
        var stops = 0
        do {
            let _: Int = try await AVMediaMetadataOperation.run(timeout: .seconds(30)) {
                throw Expected.failure
            } stop: { stops += 1 }
            XCTFail("Expected operation failure")
        } catch Expected.failure {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(stops, 1)
    }
}
