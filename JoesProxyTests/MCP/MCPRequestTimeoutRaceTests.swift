import Foundation
import XCTest
@testable import JoesProxy

/// Regression coverage for a bug found via a 44-minute Instruments capture
/// (memlog/Instruments-Results/JoesProxyNotRendering): `handleWithTimeout` (now
/// `MCPRequestTimeoutRace.run`) used `try? await Task.sleep(...)` for its timeout sibling task.
/// When `operation` won the race, `group.cancelAll()` cancelled the sleep — but `try?` swallowed
/// the resulting `CancellationError` and execution fell straight through to the "exceeded timeout
/// budget" log and a fabricated 408, unconditionally, on *every* request. In the capture this
/// produced 489 false timeout notices — one per MCP request — drowning out any real ones.
@MainActor
final class MCPRequestTimeoutRaceTests: XCTestCase {
    func testFastOperationWinningTheRaceNeverFiresTheTimeoutCallback() async {
        var timeoutFired = false
        // Deliberately long relative to how fast `operation` resolves below — if this were
        // actually waited out, the test itself would be slow, which it isn't: `withTaskGroup`
        // doesn't return until every child task (including the now-cancelled sleeper) has finished
        // unwinding, so a passing/failing assertion here is available immediately either way.
        let response = await MCPRequestTimeoutRace.run(
            timeout: 5,
            onTimeoutExceeded: { timeoutFired = true }
        ) {
            MCPHTTPResponse.response(status: 200, body: Data("ok".utf8))
        }

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, Data("ok".utf8))
        XCTAssertFalse(
            timeoutFired,
            "operation won the race well before the 5s deadline; the timeout callback must not fire"
        )
    }

    func testOperationThatNeverCompletesTriggersTimeoutExactlyOnce() async {
        var timeoutFireCount = 0
        let response = await MCPRequestTimeoutRace.run(
            timeout: 0.02,
            onTimeoutExceeded: { timeoutFireCount += 1 }
        ) {
            // Never resolves within the 20ms timeout.
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return MCPHTTPResponse.response(status: 200, body: Data("too late".utf8))
        }

        XCTAssertEqual(response.status, 408)
        XCTAssertEqual(response.body, Data("Request Timeout".utf8))
        XCTAssertEqual(timeoutFireCount, 1)
    }

    func testSlowButUltimatelyCompletingOperationWinsBeforeItsOwnTimeout() async {
        var timeoutFired = false
        let response = await MCPRequestTimeoutRace.run(
            timeout: 5,
            onTimeoutExceeded: { timeoutFired = true }
        ) {
            try? await Task.sleep(nanoseconds: 10_000_000)
            return MCPHTTPResponse.response(status: 201, body: Data("done".utf8))
        }

        XCTAssertEqual(response.status, 201)
        XCTAssertFalse(timeoutFired)
    }
}
