import Observation

/// MainActor owns presentation and admission. Cancellation keeps the worker slot occupied
/// until the service returns; one latest replacement may wait without starting another player.
@MainActor
@Observable
final class AVMediaInspectionModel {
    typealias Inspect = @MainActor (AVMediaInspectionInput) async -> AVMediaInspectionReport

    private(set) var report: AVMediaInspectionReport?
    private(set) var isInspecting = false
    @ObservationIgnored private let inspect: Inspect
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var pending: (UInt64, AVMediaInspectionInput)?
    @ObservationIgnored private var generation: UInt64 = 0

    init(inspect: @escaping Inspect = { await AVAssetMetadataService().inspect($0) }) {
        self.inspect = inspect
    }

    func request(_ input: AVMediaInspectionInput) {
        generation &+= 1
        report = nil
        isInspecting = true
        pending = (generation, input)
        worker?.cancel()
        startWorkerIfNeeded()
    }

    func cancel(clearReport: Bool = false) {
        generation &+= 1
        pending = nil
        worker?.cancel()
        isInspecting = false
        if clearReport { report = nil }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, let (version, input) = pending else { return }
        pending = nil
        worker = Task {
            let result = await inspect(input)
            if !Task.isCancelled, version == generation {
                report = result
                isInspecting = false
            }
            worker = nil
            startWorkerIfNeeded()
        }
    }
}
