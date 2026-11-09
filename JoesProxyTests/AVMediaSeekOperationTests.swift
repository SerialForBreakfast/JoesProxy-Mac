import XCTest
@testable import JoesProxy

@MainActor
final class AVMediaSeekOperationTests: XCTestCase {
    func testSuccessfulSeekRetiresPendingWork() async throws {
        var cancellations = 0
        try await AVMediaSeekOperation.run(timeout: .seconds(1)) { complete in
            complete(true)
        } cancel: { cancellations += 1 }
        XCTAssertEqual(cancellations, 1)
    }

    func testInterruptedSeekDoesNotReportSuccess() async {
        var cancellations = 0
        do {
            try await AVMediaSeekOperation.run(timeout: .seconds(1)) { $0(false) }
                cancel: { cancellations += 1 }
            XCTFail("Interrupted seek must fail")
        } catch AVMediaSeekOperation.Failure.interrupted {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(cancellations, 1)
    }

    func testMissingCallbackTimesOutAndLateCallbackCannotCompleteNextSeek() async throws {
        var late: (@Sendable (Bool) -> Void)?
        var cancellations = 0
        do {
            try await AVMediaSeekOperation.run(timeout: .milliseconds(20)) { late = $0 }
                cancel: { cancellations += 1 }
            XCTFail("Missing callback must time out")
        } catch AVMediaSeekOperation.Failure.timedOut {
        } catch { XCTFail("Unexpected error: \(error)") }
        do {
            try await AVMediaSeekOperation.run(timeout: .milliseconds(20)) { _ in late?(true) }
                cancel: { cancellations += 1 }
            XCTFail("A retired callback cannot complete a replacement")
        } catch AVMediaSeekOperation.Failure.timedOut {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(cancellations, 2)
    }

    func testCancellationRetiresSeekWithoutWaitingForCallback() async {
        var started = false
        var cancellations = 0
        let worker = Task {
            try await AVMediaSeekOperation.run(timeout: .seconds(30)) { _ in started = true }
                cancel: { cancellations += 1 }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !started, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(started)
        worker.cancel()
        do { try await worker.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(cancellations, 1)
    }

    func testPreCancellationDoesNotStartSeek() async {
        var started = false
        let worker = Task {
            try await AVMediaSeekOperation.run(timeout: .seconds(1)) { _ in started = true }
                cancel: { XCTFail("No pending seek exists") }
        }
        worker.cancel()
        do { try await worker.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(started)
    }
}
