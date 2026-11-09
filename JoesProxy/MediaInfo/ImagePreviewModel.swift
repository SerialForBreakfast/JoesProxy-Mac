import AppKit
import ImageIO
import Observation

struct ImagePreviewKey: Equatable {
    let sessionID: UUID
    let revision: UInt64
    let contentType: String?
}

struct ImagePreviewAnalysis: Sendable {
    let image: CGImage?
    let fallbackData: Data?
    let metadata: ImageMetadata
    let visualReport: VisualAssetReport
}

/// Common ImageIO decoding and analysis run off-main with one active and one latest request.
/// AppKit image wrapping remains on MainActor; production decoding has no unbounded fallback.
@MainActor
@Observable
final class ImagePreviewModel {
    typealias Analyze = @Sendable (Data) async -> ImagePreviewAnalysis?
    private struct Request {
        let data: Data
        let generation: UInt64
    }

    private(set) var image: NSImage?
    private(set) var metadata: ImageMetadata?
    private(set) var visualReport: VisualAssetReport?
    private(set) var isLoading = false
    private(set) var isWorking = false
    private(set) var attemptCount = 0
    @ObservationIgnored private var key: ImagePreviewKey?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var pending: Request?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private let analyze: Analyze

    init(analyze: @escaping Analyze = ImagePreviewModel.analyzeImage) {
        self.analyze = analyze
    }

    func request(key: ImagePreviewKey, data: Data) {
        guard self.key != key else { return }
        self.key = key
        generation &+= 1
        image = nil
        metadata = nil
        visualReport = nil
        isLoading = true
        pending = Request(data: data, generation: generation)
        startWorkerIfNeeded()
    }

    func cancelAndClear() {
        generation &+= 1
        key = nil
        pending = nil
        image = nil
        metadata = nil
        visualReport = nil
        isLoading = false
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
                let result = await self.analyze(request.data)
                guard !Task.isCancelled else { break }
                guard request.generation == self.generation else { continue }
                if let result {
                    if let image = result.image {
                        self.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                    } else if let data = result.fallbackData {
                        self.image = NSImage(data: data)
                    }
                    self.metadata = result.metadata
                    self.visualReport = result.visualReport
                }
                self.isLoading = false
            }
            self.worker = nil
            self.isWorking = false
            self.startWorkerIfNeeded()
        }
    }

    nonisolated static func analyzeImage(_ data: Data) async -> ImagePreviewAnalysis? {
        await runDetachedCancellable(priority: .utility) {
            guard !Task.isCancelled else { return nil }
            let preflight = ImageInspectionPreflight.inspect(data)
            let source = preflight.source
            let image = source.flatMap { source in
                CGImageSourceGetCount(source) > 0 ? CGImageSourceCreateImageAtIndex(source, 0, nil) : nil
            }
            guard !Task.isCancelled else { return nil }
            let metadata = ImageMetadataService().loadMetadata(from: data)
            guard !Task.isCancelled else { return nil }
            let report = VisualWireInspectorEngine.analyze(imageData: data)
            guard !Task.isCancelled else { return nil }
            return ImagePreviewAnalysis(image: image, fallbackData: nil,
                metadata: metadata, visualReport: report)
        }
    }
}
