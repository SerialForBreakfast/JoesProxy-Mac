import Foundation

/// Activation-local rendering. The reviewed package remains immutable; all phases share one anchor.
enum EffectBundleTimestampRenderer {
    static func render(_ data: Data, bindings: [EffectBundleTimestampBinding], anchor: Date) throws -> Data {
        guard !bindings.isEmpty else { return data }
        try Task.checkCancellation()
        var root = try CollectionMockCompiler.parse(data)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var paths = Set<[String]>()
        for binding in bindings {
            try Task.checkCancellation()
            let path = try CollectionMockCompiler.pointer(binding.jsonPointer)
            guard paths.insert(path).inserted,
                  binding.offsetSeconds.isFinite,
                  abs(binding.offsetSeconds) <= EffectBundleBudget.maxTTL,
                  case .string = try CollectionMockCompiler.value(at: path, in: root) else {
                throw EffectBundleError.invalidBodySource("timestampBinding:\(binding.id.uuidString)")
            }
            let date = anchor.addingTimeInterval(binding.offsetSeconds)
            guard date.timeIntervalSince1970.isFinite,
                  date >= Date(timeIntervalSince1970: -62_135_596_800),
                  date < Date(timeIntervalSince1970: 253_402_300_800) else {
                throw EffectBundleError.invalidBodySource("timestampRange")
            }
            root = try CollectionMockCompiler.replacing(path, in: root, with: .string(formatter.string(from: date)))
        }
        let output = try JSONSerialization.data(withJSONObject: CollectionMockCompiler.foundationValue(root),
                                                options: [.sortedKeys, .fragmentsAllowed])
        guard output.count <= CollectionMockCompiler.maximumBodyBytes else { throw CollectionMockError.sizeLimit }
        return output
    }
}

/// One serial disk/JSON executor, independent of MainActor and network event loops. The coordinator
/// caps admitted activation workers; Stop drains its owned worker before deleting runtime files.
actor EffectBundleMaterializationExecutor {
    static let shared = EffectBundleMaterializationExecutor()

    func materialize(using materializer: EffectBundleRuntimeMaterializer, manifest: EffectBundleManifest,
                     packageURL: URL, anchor: Date) throws -> EffectBundleRuntimeLayout {
        try Task.checkCancellation()
        return try materializer.materialize(manifest: manifest, packageURL: packageURL, anchor: anchor)
    }
}
