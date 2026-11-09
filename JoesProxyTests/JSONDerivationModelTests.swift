import XCTest
@testable import JoesProxy

@MainActor
final class JSONDerivationModelTests: XCTestCase {
    func testImmutableSourceRevisionRefreshesSameLengthUnsampledEdits() async throws {
        let id = UUID()
        let original = Data(("{\"value\":\"" + String(repeating: "a", count: 240) + "\"}").utf8)
        var corrected = original
        let editedOffset = 11
        XCTAssertNotEqual(editedOffset % max(1, original.count / 64), 0)
        corrected[editedOffset] = 0x62
        XCTAssertEqual(original.count, corrected.count)
        XCTAssertNotEqual(JSONContentSource.contentDigest(for: original), JSONContentSource.contentDigest(for: corrected))
        XCTAssertNotEqual(JSONContentSource.stableID(for: original), JSONContentSource.stableID(for: corrected))
        let first = try JSONContentSource.makeLoaded(from: original, stableID: id)
        let second = try JSONContentSource.makeLoaded(from: corrected, stableID: id)
        XCTAssertEqual(first.loadedID, second.loadedID)
        guard case .loaded(_, let firstRevision, let originalText, let originalBytes) = first,
              case .loaded(_, let secondRevision, let correctedText, let correctedBytes) = second else {
            return XCTFail("Expected immutable loaded sources")
        }
        XCTAssertNotEqual(firstRevision, secondRevision)
        XCTAssertEqual(originalBytes, original)
        XCTAssertEqual(correctedBytes, corrected)
        XCTAssertEqual(originalText, String(decoding: original, as: UTF8.self))
        XCTAssertEqual(correctedText, String(decoding: corrected, as: UTF8.self))

        for mode in [JSONViewMode.folder, .prettified] {
            let model = JSONDerivationModel()
            model.request(source: first, mode: mode)
            try await settle(model)
            let oldLabel = model.root?.children.first?.label
            let oldText = model.prettified
            for _ in 0..<20 { model.request(source: first, mode: mode) }
            XCTAssertEqual(model.attemptCount, 1)
            model.request(source: second, mode: mode)
            try await settle(model)
            XCTAssertEqual(model.attemptCount, 2)
            XCTAssertNil(model.errorMessage)
            if mode == .folder { XCTAssertNotEqual(model.root?.children.first?.label, oldLabel) }
            else { XCTAssertNotEqual(model.prettified, oldText) }
        }
    }

    func testMalformedJSONFailsOncePerModeWithoutAutomaticRetry() async throws {
        let model = JSONDerivationModel()
        let id = UUID()
        let data = Data("{broken".utf8)
        for mode in [JSONViewMode.folder, .prettified] {
            model.request(id: id, fingerprint: "invalid", data: data, mode: mode)
            try await settle(model)
            XCTAssertNotNil(model.errorMessage)
        }
        XCTAssertEqual(model.attemptCount, 2)
        for _ in 0..<20 {
            model.request(id: id, fingerprint: "invalid", data: data, mode: .folder)
            model.request(id: id, fingerprint: "invalid", data: data, mode: .prettified)
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.attemptCount, 2)
        XCTAssertFalse(model.isWorking)
    }

    func testFailureDoesNotBlockCorrectedSameIDRevision() async throws {
        let model = JSONDerivationModel()
        let id = UUID()
        model.request(id: id, fingerprint: "invalid", data: Data("{broken".utf8), mode: .folder)
        try await settle(model)
        model.request(id: id, fingerprint: "corrected", data: Data("{\"id\":1}".utf8), mode: .folder)
        try await settle(model)
        XCTAssertNotNil(model.root)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.attemptCount, 2)
    }

    func testRapidUpdatesCoalesceToLatestWithOneActiveWorker() async throws {
        let gate = DerivationGate()
        defer { Task { await gate.releaseAll() } }
        let model = JSONDerivationModel(derive: { data, _ in await gate.run(data) })
        let id = UUID()
        model.request(id: id, fingerprint: "first", data: Data("first".utf8), mode: .prettified)
        try await waitUntil { model.attemptCount == 1 }
        for value in 1...50 {
            model.request(id: id, fingerprint: "revision-\(value)", data: Data("value-\(value)".utf8), mode: .prettified)
        }
        XCTAssertEqual(model.attemptCount, 1)
        await gate.releaseNext()
        try await waitUntil { model.attemptCount == 2 }
        XCTAssertNil(model.prettified, "The superseded first result cannot publish")
        await gate.releaseNext()
        try await settle(model)
        XCTAssertEqual(model.prettified, "value-50")
        XCTAssertEqual(model.attemptCount, 2)
        let peak = await gate.peak
        XCTAssertEqual(peak, 1)
    }

    func testDisappearCancelsWithoutRestartAndReappearWaitsForDrain() async throws {
        let gate = DerivationGate()
        defer { Task { await gate.releaseAll() } }
        let model = JSONDerivationModel(derive: { data, _ in await gate.run(data) })
        let id = UUID()
        model.request(id: id, fingerprint: "old", data: Data("old".utf8), mode: .prettified)
        try await waitUntil { model.attemptCount == 1 }
        model.cancelAndClear()
        model.request(id: id, fingerprint: "new", data: Data("new".utf8), mode: .prettified)
        XCTAssertEqual(model.attemptCount, 1)
        await gate.releaseNext()
        try await waitUntil { model.attemptCount == 2 }
        XCTAssertNil(model.prettified)
        await gate.releaseNext()
        try await settle(model)
        XCTAssertEqual(model.prettified, "new")
        model.cancelAndClear()
        XCTAssertNil(model.prettified)
        XCTAssertNil(model.root)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.attemptCount, 2)
    }

    func testRawModeDiscardsPendingWorkAndLateResults() async throws {
        let gate = DerivationGate()
        defer { Task { await gate.releaseAll() } }
        let model = JSONDerivationModel(derive: { data, _ in await gate.run(data) })
        let id = UUID()
        let data = Data("{}".utf8)
        model.request(id: id, fingerprint: "source", data: data, mode: .prettified)
        try await waitUntil { model.attemptCount == 1 }
        model.request(id: id, fingerprint: "source", data: data, mode: .raw)
        await gate.releaseNext()
        try await settle(model)
        XCTAssertNil(model.prettified)
        XCTAssertEqual(model.attemptCount, 1)
    }

    func testFinishedWorkerDoesNotRetainModel() async throws {
        var model: JSONDerivationModel? = JSONDerivationModel()
        weak var releasedModel = model
        model?.request(id: UUID(), fingerprint: "source", data: Data("{}".utf8), mode: .folder)
        try await waitUntil { model?.isWorking == false }
        model = nil
        try await waitUntil { releasedModel == nil }
    }

    private func settle(_ model: JSONDerivationModel) async throws {
        try await waitUntil { !model.isWorking }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Derivation state did not settle")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private actor DerivationGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var permits = 0
    private var active = 0
    private(set) var peak = 0
    private var released = false

    func run(_ data: Data) async -> Result<JSONDerivedContent, Error> {
        active += 1
        peak = max(peak, active)
        if permits > 0 {
            permits -= 1
        } else if !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        active -= 1
        return .success(.prettified(String(decoding: data, as: UTF8.self)))
    }

    func releaseNext() {
        if waiters.isEmpty { permits += 1 } else { waiters.removeFirst().resume() }
    }

    func releaseAll() {
        released = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}
