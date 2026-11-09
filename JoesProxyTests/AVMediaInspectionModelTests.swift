import XCTest
@testable import JoesProxy

@MainActor
final class AVMediaInspectionModelTests: XCTestCase {
    private final class Gate {
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }

    func testReplacementKeepsOneWorkerAndOnlyLatestPendingInput() async {
        let gate = Gate()
        defer { gate.release() }
        var calls: [String] = []
        let model = AVMediaInspectionModel { input in
            calls.append(input.displayName)
            if input.displayName == "first" { await gate.wait() }
            return Self.report(input)
        }
        model.request(input("first"))
        await waitUntil { gate.continuation != nil }
        model.request(input("second"))
        model.request(input("latest"))
        XCTAssertEqual(calls, ["first"])
        XCTAssertTrue(model.isInspecting)
        gate.release()
        await waitUntil { model.report?.sourceDescription == "latest" }
        XCTAssertEqual(calls, ["first", "latest"])
        XCTAssertFalse(model.isInspecting)
    }

    func testCancelResetsLoadingAndRejectsLateCompletion() async {
        let gate = Gate()
        defer { gate.release() }
        let model = AVMediaInspectionModel { input in
            await gate.wait()
            return Self.report(input)
        }
        model.request(input("cancelled"))
        await waitUntil { gate.continuation != nil }
        model.cancel(clearReport: true)
        XCTAssertFalse(model.isInspecting)
        gate.release()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(model.report)
        XCTAssertFalse(model.isInspecting)
    }

    func testCompletedReportCanBePreservedOnCloseButInvalidatedForNewSource() async {
        let model = AVMediaInspectionModel { Self.report($0) }
        model.request(input("completed"))
        await waitUntil { model.report != nil }
        model.cancel()
        XCTAssertEqual(model.report?.sourceDescription, "completed")
        model.cancel(clearReport: true)
        XCTAssertNil(model.report)
        model.request(input("new source"))
        await waitUntil { model.report?.sourceDescription == "new source" }
    }

    func testCancelledWorkerReleasesOwnerAfterServiceReturns() async {
        let gate = Gate()
        defer { gate.release() }
        var model: AVMediaInspectionModel? = AVMediaInspectionModel { input in
            await gate.wait()
            return Self.report(input)
        }
        weak var owner = model
        model?.request(input("retiring"))
        await waitUntil { gate.continuation != nil }
        model?.cancel()
        model = nil
        XCTAssertNotNil(owner, "Service retirement still owns its bounded worker")
        gate.release()
        await waitUntil { owner == nil }
    }

    func testRepeatedBurstCancelAndDrainNeverStartsSupersededInputs() async {
        for cycle in 0..<25 {
            let gate = Gate()
            var calls: [String] = []
            var model: AVMediaInspectionModel? = AVMediaInspectionModel { input in
                calls.append(input.displayName)
                if input.displayName == "active" { await gate.wait() }
                return Self.report(input)
            }
            weak var owner = model
            model?.request(input("active"))
            await waitUntil { gate.continuation != nil }
            for index in 0..<100 { model?.request(input("superseded-\(index)")) }
            model?.cancel(clearReport: true)
            XCTAssertEqual(calls, ["active"], "Cycle \(cycle) queued replacement work")
            model = nil
            gate.release()
            await waitUntil { owner == nil }
            XCTAssertEqual(calls, ["active"])
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(predicate())
    }

    private func input(_ name: String) -> AVMediaInspectionInput {
        AVMediaInspectionInput(source: .capturedItem, url: nil, capturedData: nil,
            capturedFileExtension: nil, displayName: name, sampleTime: 0, initialWarnings: [])
    }

    private static func report(_ input: AVMediaInspectionInput) -> AVMediaInspectionReport {
        AVMediaInspectionReport(source: input.source, sourceDescription: input.displayName,
            isPartial: false, asset: nil, variants: [], videoTracks: [], audioTracks: [],
            subtitleTracks: [], mediaSelectionGroups: [], player: nil, decodedFrame: nil,
            accessEvents: [], errors: [], stages: [], warnings: [])
    }
}
