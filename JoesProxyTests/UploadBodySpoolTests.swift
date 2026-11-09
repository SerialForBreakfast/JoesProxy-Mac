import XCTest
@testable import JoesProxy

final class UploadBodySpoolTests: XCTestCase {
    func testStalledWriteRejectsOverlappingWorkAndRetainsCancelledLeaseUntilClose() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stall = UploadWriteStall()
        defer { stall.release() }
        let budget = UploadSpoolBudget(limit: 1)
        let spool = try await UploadBodySpool.create(in: directory, budget: budget, write: { try stall.write($0, $1) })
        let writing = Task { try await spool.append(Data(repeating: 9, count: 64 * 1024)) }
        try await stall.waitUntilBlocked()
        do { try await spool.append(Data([1])); XCTFail("Overlapping buffers must not queue behind stalled I/O") }
        catch { XCTAssertEqual(error as? UploadBodySpoolError, .operationInProgress) }
        writing.cancel()
        let closing = Task { try await spool.close() }
        await MainActor.run { XCTAssertTrue(stall.isBlocked, "MainActor must run while file I/O remains blocked") }
        XCTAssertEqual(budget.activeCount, 1)
        XCTAssertNil(budget.reserve(), "Cancellation cannot release admission before physical I/O completes")
        stall.release()
        do { try await writing.value; XCTFail("Cancelled append must report cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await closing.value
        XCTAssertFalse(stall.timedOut)
        XCTAssertEqual(budget.activeCount, 0)
        XCTAssertLessThanOrEqual(stall.maximumChunkBytes, UploadBodySpool.maximumChunkBytes)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testDegradedHealthStillDrainsOutstandingCreationReservation() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = UploadSpoolService(directory: directory, budget: UploadSpoolBudget(limit: 1))
        let lease = try XCTUnwrap(service.budget.reserve())
        service.recordStorageFailure()
        service.stopAdmission()
        let arrival = Task {
            try await Task.sleep(for: .milliseconds(40))
            do {
                _ = try await service.create(lease: lease)
                XCTFail("Shutdown must reject the reserved but not-yet-created upload")
            } catch { XCTAssertEqual(error as? UploadBodySpoolError, .invalidState) }
        }
        let healthy = await service.drain()
        XCTAssertFalse(healthy, "Draining does not erase the original storage failure")
        XCTAssertEqual(service.budget.activeCount, 0, "Degraded health must not skip outstanding admission cleanup")
        try await arrival.value
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testPartialDiskWriteFailureCannotSealOrReplayAndReturnsLease() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let budget = UploadSpoolBudget(limit: 1)
        let spool = try await UploadBodySpool.create(in: directory, budget: budget) { fd, bytes in
            if lseek(fd, 0, SEEK_CUR) >= 17 { throw UploadBodySpoolError.diskIO(ENOSPC) }
            return try UploadBodySpool.diskWrite(fd, UnsafeRawBufferPointer(rebasing: bytes.prefix(17)))
        }
        do {
            try await spool.append(Data(repeating: 42, count: 1024))
            XCTFail("A short write followed by disk exhaustion must fail the whole append")
        } catch { XCTAssertEqual(error as? UploadBodySpoolError, .diskIO(ENOSPC)) }
        let count = await spool.byteCount
        XCTAssertEqual(count, 0)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try Data(contentsOf: file), Data(repeating: 42, count: 17))
        do { try await spool.seal(); XCTFail("Partial data must not become replayable") }
        catch { XCTAssertEqual(error as? UploadBodySpoolError, .invalidState) }
        do { _ = try await spool.read(at: 0); XCTFail("Failed bodies cannot be read") }
        catch { XCTAssertEqual(error as? UploadBodySpoolError, .invalidState) }
        try await spool.close()
        XCTAssertEqual(budget.activeCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testCleanupFailureRetainsLeaseUntilRecovery() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = UploadSpoolService(directory: directory, budget: UploadSpoolBudget(limit: 1))
        let spool = try await service.create(lease: XCTUnwrap(service.budget.reserve()))
        try await spool.append(Data([1, 2, 3]))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        await service.release(spool)
        XCTAssertTrue(service.needsCleanup)
        XCTAssertEqual(service.budget.activeCount, 1)
        XCTAssertNil(service.budget.reserve())
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        service.stopAdmission()
        try await service.prepare()
        XCTAssertFalse(service.needsCleanup)
        XCTAssertEqual(service.budget.activeCount, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    private func scratchDirectory() throws -> URL {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent(".build/UploadBodySpoolTests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return directory
    }

    func testChunkedBinaryRoundTripAndExplicitCleanupReleaseAdmission() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let budget = UploadSpoolBudget(limit: 1)
        let spool = try await UploadBodySpool.create(in: directory, budget: budget)
        let chunk = Data((0..<UploadBodySpool.maximumChunkBytes).map { UInt8(truncatingIfNeeded: $0) })
        for _ in 0..<16 { try await spool.append(chunk) }
        try await spool.append(Data([0, 255, 3]))
        try await spool.seal()
        let size = await spool.byteCount
        XCTAssertEqual(size, 16 * chunk.count + 3)
        for index in 0..<16 {
            let actual = try await spool.read(at: index * chunk.count)
            XCTAssertEqual(actual, chunk)
        }
        let tail = try await spool.read(at: 16 * chunk.count)
        XCTAssertEqual(tail, Data([0, 255, 3]))
        let end = try await spool.read(at: size)
        XCTAssertTrue(end.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        try await spool.close()
        try await spool.close()
        XCTAssertEqual(budget.activeCount, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testAdmissionAndInvalidChunksDoNotCreateAnUnboundedQueue() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let budget = UploadSpoolBudget(limit: 1)
        let spool = try await UploadBodySpool.create(in: directory, budget: budget)
        do {
            _ = try await UploadBodySpool.create(in: directory, budget: budget)
            XCTFail("A held file lease must prevent additional creation")
        } catch { XCTAssertEqual(error as? UploadBodySpoolError, .capacityUnavailable) }
        do {
            try await spool.append(Data(count: UploadBodySpool.maximumChunkBytes + 1))
            XCTFail("Storage accepts bounded chunks, not complete upload bodies")
        } catch { XCTAssertEqual(error as? UploadBodySpoolError, .invalidChunk) }
        let count = await spool.byteCount
        XCTAssertEqual(count, 0)
        try await spool.close()
        let replacement = try await UploadBodySpool.create(in: directory, budget: budget)
        try await replacement.close()
        XCTAssertEqual(budget.activeCount, 0)
    }

    func testUnsealedAndClosedBodiesCannotBeRead() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = try await UploadBodySpool.create(in: directory, budget: UploadSpoolBudget())
        do {
            _ = try await spool.read(at: 0)
            XCTFail("An incomplete upload is not a replayable body")
        } catch { XCTAssertEqual(error as? UploadBodySpoolError, .invalidState) }
        try await spool.seal()
        do {
            try await spool.append(Data([1]))
            XCTFail("A sealed body is immutable")
        } catch { XCTAssertEqual(error as? UploadBodySpoolError, .invalidState) }
        try await spool.close()
        do {
            _ = try await spool.read(at: 0)
            XCTFail("Closed storage must not use a recycled descriptor")
        } catch { XCTAssertEqual(error as? UploadBodySpoolError, .invalidState) }
    }

    func testUnsafeDirectoryFailureReturnsItsLease() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let budget = UploadSpoolBudget(limit: 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        do {
            _ = try await UploadBodySpool.create(in: directory, budget: budget)
            XCTFail("Raw upload storage must not use a shared directory")
        } catch { XCTAssertEqual(error as? UploadBodySpoolError, .unsafeDirectory) }
        XCTAssertEqual(budget.activeCount, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testCancelledCallerCanStillCleanUpItsSpool() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let budget = UploadSpoolBudget(limit: 1)
        let spool = try await UploadBodySpool.create(in: directory, budget: budget)
        try await spool.append(Data([1, 2, 3]))
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await spool.append(Data([4]))
                XCTFail("Cancelled input must not be admitted")
            } catch { XCTAssertTrue(error is CancellationError) }
            try await spool.close()
        }
        try await operation.value
        XCTAssertEqual(budget.activeCount, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testShortDiskReadFailsWithoutReturningPartialBody() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let budget = UploadSpoolBudget(limit: 1)
        let spool = try await UploadBodySpool.create(in: directory, budget: budget)
        try await spool.append(Data([1, 2, 3]))
        try await spool.seal()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let file = try XCTUnwrap(files.first)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 1)
        try handle.close()
        do {
            _ = try await spool.read(at: 0)
            XCTFail("A damaged spool must not masquerade as a complete upload")
        } catch { XCTAssertEqual(error as? UploadBodySpoolError, .diskIO(EIO)) }
        try await spool.close()
        XCTAssertEqual(budget.activeCount, 0)
    }

    func testStartupRecoveryRemovesOnlyUnlockedOwnedFiles() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let budget = UploadSpoolBudget()
        let active = try await UploadBodySpool.create(in: directory, budget: budget)
        try await active.append(Data([1, 2, 3]))
        try await active.seal()
        let stale = directory.appendingPathComponent(UUID().uuidString + ".upload")
        let unrelated = directory.appendingPathComponent("notes.txt")
        let link = directory.appendingPathComponent(UUID().uuidString + ".upload")
        let fifo = directory.appendingPathComponent(UUID().uuidString + ".upload")
        try Data([4, 5, 6]).write(to: stale)
        try Data([7]).write(to: unrelated)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unrelated)
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        try await UploadBodySpool.prepareDirectory(directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([7]))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), unrelated.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fifo.path))
        let bytes = try await active.read(at: 0)
        XCTAssertEqual(bytes, Data([1, 2, 3]))
        try await active.close()
    }

    func testSpoolMetadataPreservesTrueSizeAndTruncation() {
        var request = HTTPProxyRequest(kind: .standard, method: "POST", version: "HTTP/1.1",
            host: "upload.example", port: 80, path: "/", headers: [], body: Data([1, 2, 3]))
        request.originalBodySize = 1000
        let captured = request.capturedBody(using: CaptureBodyLimiter(limit: 10))
        XCTAssertEqual(captured.size, 1000)
        XCTAssertEqual(captured.data, Data([1, 2, 3]))
        XCTAssertTrue(captured.truncated)
    }

    func testRequestHeadCanBeParsedBeforeLargeBodyArrives() throws {
        let bytes = Data("POST http://upload.example/items HTTP/1.1\r\nHost: upload.example\r\nContent-Length: 1048576\r\n\r\n".utf8)
        let parsed = try HTTPRequestParser().parseRequestHead(bytes)
        XCTAssertEqual(parsed.consumedLength, bytes.count)
        XCTAssertTrue(parsed.request.body.isEmpty)
        XCTAssertThrowsError(try HTTPRequestParser().parseRequestFrame(bytes))
    }

    func testUnreadableStaleFileKeepsRecoveryWarning() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(UUID().uuidString + ".upload")
        try Data([1]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        let service = UploadSpoolService(directory: directory)
        do {
            try await service.prepare()
            XCTFail("Inaccessible owned data must not be reported as cleaned")
        } catch { XCTAssertTrue(service.needsCleanup) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try await service.prepare()
        XCTAssertFalse(service.needsCleanup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testCancelledCreationReturnsAdmissionWithoutAFile() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let budget = UploadSpoolBudget(limit: 1)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await UploadBodySpool.create(in: directory, budget: budget)
                XCTFail("A cancelled creator must not retain a file lease")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(budget.activeCount, 0)
        }
        await operation.value
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
