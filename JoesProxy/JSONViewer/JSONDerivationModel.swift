import Foundation
import Observation

enum JSONDerivedContent: Sendable {
    case folder(JSONTreeNode)
    case prettified(String)
}

/// One worker and one replaceable pending request. Failure is terminal for a source/mode;
/// leaving the surface clears ownership and never recursively starts cancelled work.
@MainActor
@Observable
final class JSONDerivationModel {
    typealias Derive = @Sendable (Data, JSONViewMode) async -> Result<JSONDerivedContent, Error>

    private struct SourceKey: Equatable {
        let id: UUID
        let fingerprint: String
    }
    private struct Request {
        let data: Data
        let mode: JSONViewMode
        let generation: UInt64
    }

    private(set) var root: JSONTreeNode?
    private(set) var prettified: String?
    private(set) var errorMessage: String?
    private(set) var attemptCount = 0
    private(set) var isWorking = false
    @ObservationIgnored private var sourceKey: SourceKey?
    @ObservationIgnored private var desiredMode: JSONViewMode?
    @ObservationIgnored private var errors: [JSONViewMode: String] = [:]
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var pending: Request?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private let derive: Derive

    init(derive: @escaping Derive = JSONDerivationModel.deriveContent) {
        self.derive = derive
    }

    func request(source: JSONContentSource?, mode: JSONViewMode) {
        guard case .loaded(let id, let revision, _, let data) = source else {
            cancelAndClear()
            return
        }
        request(id: id, fingerprint: revision.uuidString, data: data, mode: mode)
    }

    func request(id: UUID, fingerprint: String, data: Data, mode: JSONViewMode) {
        let key = SourceKey(id: id, fingerprint: fingerprint)
        if sourceKey != key {
            sourceKey = key
            root = nil
            prettified = nil
            errors = [:]
            desiredMode = nil
        }
        guard desiredMode != mode else { return }
        desiredMode = mode
        generation &+= 1
        errorMessage = errors[mode]
        pending = nil
        guard mode != .raw, errorMessage == nil,
              (mode == .folder ? root == nil : prettified == nil) else { return }
        pending = Request(data: data, mode: mode, generation: generation)
        startWorkerIfNeeded()
    }

    func cancelAndClear() {
        generation &+= 1
        sourceKey = nil
        desiredMode = nil
        pending = nil
        root = nil
        prettified = nil
        errors = [:]
        errorMessage = nil
        worker?.cancel()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, pending != nil else { return }
        isWorking = true
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let request = self.pending {
                self.pending = nil
                self.attemptCount += 1
                let result = await self.derive(request.data, request.mode)
                guard !Task.isCancelled else { break }
                guard request.generation == self.generation else { continue }
                switch result {
                case .success(.folder(let root)):
                    self.root = root
                case .success(.prettified(let text)):
                    self.prettified = text
                case .failure(let error):
                    self.errors[request.mode] = error.localizedDescription
                    self.errorMessage = error.localizedDescription
                }
            }
            self.worker = nil
            self.isWorking = false
            // A reappearing surface may have submitted fresh work while cancellation drained.
            self.startWorkerIfNeeded()
        }
    }

    nonisolated private static func deriveContent(data: Data, mode: JSONViewMode) async -> Result<JSONDerivedContent, Error> {
        await runDetachedCancellable(priority: .utility) {
            Result {
                try Task.checkCancellation()
                let result: JSONDerivedContent
                switch mode {
                case .folder:
                    result = .folder(try JSONTreeParser.parse(data))
                case .prettified:
                    result = .prettified(try JSONContentSource.prettyPrintedJSONString(from: data))
                case .raw:
                    preconditionFailure("Raw JSON requires no derivation")
                }
                try Task.checkCancellation()
                return result
            }
        }
    }
}
