import Foundation
import XCTest
@testable import JoesProxy

final class ArtifactWorkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

final class ArtifactTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var didEnter = false
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return didEnter }
    func wait() {
        lock.lock(); didEnter = true; lock.unlock()
        _ = release.wait(timeout: .now() + 5)
    }
    func open() { release.signal() }
}

@MainActor
final class ArtifactAnalysisWorkerTests: XCTestCase {
    func testCancelledUnderlyingWorkRetainsBusySlotUntilExit() async throws {
        let gate = ArtifactTestGate()
        defer { gate.open() }
        let worker = ArtifactAnalysisWorker(beforeWork: { gate.wait() })
        let first = Task { try await worker.perform { 1 } }
        for _ in 0..<100 where !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(gate.entered)
        first.cancel()
        XCTAssertTrue(worker.busy)
        do {
            _ = try await worker.perform { 2 }
            XCTFail("A second operation must not overlap cancelled work")
        } catch { XCTAssertEqual(error as? ArtifactAnalysisFailure, .busy) }
        gate.open()
        do { _ = try await first.value; XCTFail("Cancelled work must not publish") }
        catch { XCTAssertEqual(error as? ArtifactAnalysisFailure, .cancelled) }
        XCTAssertFalse(worker.busy)
    }
}
