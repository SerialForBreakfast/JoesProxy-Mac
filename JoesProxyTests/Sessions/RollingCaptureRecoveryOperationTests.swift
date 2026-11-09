import XCTest
@testable import JoesProxy

@MainActor
final class RollingCaptureRecoveryOperationTests: XCTestCase {
    func testExportHasDistinctProgressAndRecoverableError() async {
        let operation = RollingCaptureRecoveryOperation()
        await operation.run(exporting: true) {
            XCTAssertEqual(operation.progressMessage, "Saving a copy…")
            throw RollingCaptureRestoreError.noSnapshot
        }
        XCTAssertFalse(operation.isRunning)
        XCTAssertTrue(operation.errorMessage?.contains("save a copy") == true)
        await operation.run(exporting: true) { }
        XCTAssertNil(operation.errorMessage)
    }
    func testFailureKeepsRecoveryActionableAndRetryClearsError() async {
        let operation = RollingCaptureRecoveryOperation()
        await operation.run { throw RollingCaptureRestoreError.noSnapshot }
        XCTAssertFalse(operation.isRunning)
        XCTAssertTrue(operation.errorMessage?.contains("Start Fresh") == true)
        await operation.run {
            XCTAssertTrue(operation.isRunning)
            XCTAssertNil(operation.errorMessage)
        }
        XCTAssertFalse(operation.isRunning)
        XCTAssertNil(operation.errorMessage)
    }

    func testBusyOperationRejectsDuplicateRestore() async {
        let operation = RollingCaptureRecoveryOperation()
        var duplicateRan = false
        await operation.run {
            XCTAssertTrue(operation.isRunning)
            await operation.run { duplicateRan = true }
            XCTAssertTrue(operation.isRunning)
        }
        XCTAssertFalse(duplicateRan)
        XCTAssertFalse(operation.isRunning)
    }

    func testCancellationDoesNotClaimSuccess() async {
        let operation = RollingCaptureRecoveryOperation()
        await operation.run { throw CancellationError() }
        XCTAssertFalse(operation.isRunning)
        XCTAssertTrue(operation.errorMessage?.contains("cancelled") == true)
    }

    func testAlreadyCancelledTaskDoesNotBeginExport() async {
        let operation = RollingCaptureRecoveryOperation()
        var exportStarted = false
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await operation.run(exporting: true) { exportStarted = true }
        }
        await task.value
        XCTAssertFalse(exportStarted, "A cancelled task must not open a save panel or write a file.")
        XCTAssertFalse(operation.isRunning)
        XCTAssertTrue(operation.errorMessage?.hasPrefix("Saving a copy was cancelled.") == true)
        await operation.run(exporting: true) { exportStarted = true }
        XCTAssertTrue(exportStarted, "Cancellation must not prevent a subsequent retry.")
        XCTAssertNil(operation.errorMessage)
    }

    func testExportCannotReplaceInFlightRestoreProgress() async {
        let operation = RollingCaptureRecoveryOperation()
        var exportStarted = false
        await operation.run {
            await operation.run(exporting: true) { exportStarted = true }
            XCTAssertEqual(operation.progressMessage, "Restoring saved capture…")
            XCTAssertTrue(operation.isRunning)
        }
        XCTAssertFalse(exportStarted)
        XCTAssertFalse(operation.isRunning)
    }

    func testRestoreCannotReplaceInFlightExportProgress() async {
        let operation = RollingCaptureRecoveryOperation()
        var restoreStarted = false
        await operation.run(exporting: true) {
            await operation.run { restoreStarted = true }
            XCTAssertEqual(operation.progressMessage, "Saving a copy…")
            XCTAssertTrue(operation.isRunning)
        }
        XCTAssertFalse(restoreStarted)
        XCTAssertFalse(operation.isRunning)
    }
}
