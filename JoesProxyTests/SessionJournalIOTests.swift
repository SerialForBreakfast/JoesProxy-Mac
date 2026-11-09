import XCTest
import Synchronization
@testable import JoesProxy

@MainActor
final class SessionJournalIOTests: XCTestCase {
    func testBlockedDiskDoesNotBlockProducerAndBarrierPreservesUpdates() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = JournalIOGate()
        defer { gate.release() }
        let io = makeIO(directory, beforeAppend: { gate.blockFirstCall() })
        let first = session("/first")
        io.append(first)
        try await waitUntil { gate.started }
        var updated = first
        updated.state = .failed
        io.append(updated)
        XCTAssertEqual(io.pendingCount, 2)
        XCTAssertFalse(gate.ranOnMainThread)
        gate.release()
        _ = try await checkpoint(io)
        let records = SessionJournalReader.readSessions(from: directory.appendingPathComponent("journal.jsonl"))
        XCTAssertEqual(records.map(\.id), [first.id, first.id])
        XCTAssertEqual(records.last?.state, .failed)
        XCTAssertEqual(io.pendingCount, 0)
    }

    func testCompactionSwapDoesNotBlockArrivalsOrLoseTheirOrder() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = JournalIOGate()
        defer { gate.release() }
        let io = makeIO(directory, beforeCompaction: { if $0 == .replace { gate.blockFirstCall() } })
        let first = session("/snapshot")
        let second = session("/after-snapshot")
        io.append(first)
        let compact = Task { try await checkpoint(io, sessions: [first], compact: true) }
        try await waitUntil { gate.started }
        io.append(second)
        XCTAssertEqual(io.pendingCount, 1)
        XCTAssertFalse(gate.ranOnMainThread)
        gate.release()
        _ = try await compact.value
        _ = try await checkpoint(io)
        XCTAssertEqual(SessionJournalReader.readSessions(from: directory.appendingPathComponent("journal.jsonl")).map(\.id), [first.id, second.id])
    }

    func testResetFencesOldQueuedRecordsAndRemovesReceipt() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("old checkpoint".utf8).write(to: directory.appendingPathComponent("checkpoint.json"))
        let gate = JournalIOGate()
        defer { gate.release() }
        let io = makeIO(directory, beforeAppend: { gate.blockFirstCall() })
        io.append(session("/old"))
        try await waitUntil { gate.started }
        io.append(session("/queued-old"))
        io.reset()
        let current = session("/new")
        io.append(current)
        gate.release()
        _ = try await checkpoint(io)
        XCTAssertEqual(SessionJournalReader.readSessions(from: directory.appendingPathComponent("journal.jsonl")).map(\.id), [current.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("checkpoint.json").path))
    }

    func testBoundedBacklogReportsFailureInsteadOfSuccessfulCheckpoint() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = JournalIOGate()
        defer { gate.release() }
        let errors = Mutex<[String]>([])
        let io = SessionJournalIO(
            journalURL: directory.appendingPathComponent("journal.jsonl"),
            metadataURL: directory.appendingPathComponent("checkpoint.json"),
            maxPendingCount: 1,
            beforeAppend: { gate.blockFirstCall() },
            onFailure: { _, error in errors.withLock { $0.append(error.message) } }
        )
        io.append(session("/first"))
        try await waitUntil { gate.started }
        io.append(session("/over-budget"))
        io.append(session("/also-rejected"))
        XCTAssertEqual(io.pendingCount, 1)
        XCTAssertEqual(errors.withLock { $0.count }, 1)
        gate.release()
        do {
            _ = try await checkpoint(io)
            XCTFail("A known journal gap must not produce a successful checkpoint")
        } catch SessionJournalIOError.backlogExceeded {} catch { XCTFail("Unexpected error: \(error)") }
        io.reset()
        let recovered = session("/recovered")
        io.append(recovered)
        _ = try await checkpoint(io)
        XCTAssertEqual(SessionJournalReader.readSessions(from: directory.appendingPathComponent("journal.jsonl")).map(\.id), [recovered.id])
    }

    func testAppendFailureStaysVisibleAtBarrierAndResetAllowsRetry() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shouldFail = Mutex(true)
        let io = makeIO(directory, beforeAppend: {
            if shouldFail.withLock({ $0 }) { throw CocoaError(.fileWriteUnknown) }
        })
        io.append(session("/failed"))
        do {
            _ = try await checkpoint(io)
            XCTFail("Append failure must reach the checkpoint")
        } catch SessionJournalIOError.writeFailed {} catch { XCTFail("Unexpected error: \(error)") }
        shouldFail.withLock { $0 = false }
        io.reset()
        io.append(session("/retry"))
        _ = try await checkpoint(io)
    }

    func testPayloadBudgetRejectsOversizedAdmissionWithoutCreatingJournal() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let io = SessionJournalIO(journalURL: directory.appendingPathComponent("journal.jsonl"),
                                  metadataURL: directory.appendingPathComponent("checkpoint.json"),
                                  maxPendingBytes: 1)
        io.append(session("/too-large"))
        XCTAssertEqual(io.pendingCount, 0)
        do {
            _ = try await checkpoint(io)
            XCTFail("Byte admission limit must invalidate recovery")
        } catch SessionJournalIOError.backlogExceeded {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("journal.jsonl").path))
    }

    private func checkpoint(_ io: SessionJournalIO, sessions: [SessionRecord] = [], compact: Bool = false) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            io.checkpoint(sessions: sessions, compact: compact, commitMetadata: {}, completion: {
                continuation.resume(with: $0)
            })
        }
    }

    private func makeIO(
        _ directory: URL,
        beforeAppend: @escaping @Sendable () throws -> Void = {},
        beforeCompaction: @escaping @Sendable (SessionJournalWriter.CompactionStage) throws -> Void = { _ in }
    ) -> SessionJournalIO {
        SessionJournalIO(journalURL: directory.appendingPathComponent("journal.jsonl"),
                         metadataURL: directory.appendingPathComponent("checkpoint.json"),
                         beforeAppend: beforeAppend, beforeCompactionStage: beforeCompaction)
    }

    private func directory() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("memlog/.test-scratch/journal-io/\(UUID().uuidString)", isDirectory: true)
    }

    private func session(_ path: String) -> SessionRecord {
        SessionRecord(request: CapturedRequest(method: "GET", scheme: .http, host: "example.com", port: 80,
                                               path: path, headers: [], bodyData: nil, bodySize: 0),
                      response: nil, state: .pending, timing: SessionTiming(startedAt: Date()))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
}

private final class JournalIOGate: Sendable {
    private let values = Mutex((calls: 0, onMain: false))
    private let semaphore = DispatchSemaphore(value: 0)
    var started: Bool { values.withLock { $0.calls > 0 } }
    var ranOnMainThread: Bool { values.withLock { $0.onMain } }
    func release() { semaphore.signal() }
    func blockFirstCall() {
        let first = values.withLock { value in
            value.calls += 1
            value.onMain = value.onMain || Thread.isMainThread
            return value.calls == 1
        }
        if first { _ = semaphore.wait(timeout: .now() + 10) }
    }
}
