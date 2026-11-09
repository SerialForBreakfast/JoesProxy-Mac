import CryptoKit
import Darwin
import Foundation

/// Immutable retained-package target. Checking it cannot repair runtime files or prove delivery.
struct EffectBundleAssetRecoveryTarget: Sendable {
    let packageURL: URL
    let asset: EffectBundleAsset
}

enum EffectBundleAssetRecoveryResult: String, Sendable {
    case verified, unavailable, unsafeFile, sizeMismatch, digestMismatch, changedDuringRead

    var message: String {
        switch self {
        case .verified: return "Retained package asset matches the reviewed bytes. This does not verify the runtime copy or device delivery."
        case .unavailable: return "Retained asset is unavailable. No upstream request was made."
        case .unsafeFile: return "Asset check refused a non-regular file or unsafe reference."
        case .sizeMismatch: return "Retained asset size differs from the reviewed size or exceeds the read budget."
        case .digestMismatch: return "Retained asset bytes differ from the reviewed digest. They have not been accepted."
        case .changedDuringRead: return "The asset changed during inspection. The result is not verified."
        }
    }
}

enum EffectBundleAssetRecoveryCheck {
    /// Dedicated worker; cancellation propagates from the presentation task between bounded reads.
    static func run(_ target: EffectBundleAssetRecoveryTarget) async throws -> EffectBundleAssetRecoveryResult {
        let worker = Task.detached(priority: .utility) { try read(target) }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }

    static func read(_ target: EffectBundleAssetRecoveryTarget) throws -> EffectBundleAssetRecoveryResult {
        try Task.checkCancellation()
        let asset = target.asset
        guard asset.sha256.count == 64, asset.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return .unsafeFile }
        guard asset.byteCount >= 0, asset.byteCount <= EffectBundleBudget.maxFileBytes else { return .sizeMismatch }
        let package = open(target.packageURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard package >= 0 else { return .unavailable }
        defer { close(package) }
        let directory = openat(package, "assets", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard directory >= 0 else { return .unavailable }
        defer { close(directory) }
        let descriptor = openat(directory, asset.sha256, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return .unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { return .unsafeFile }
        guard before.st_size == asset.byteCount else { return .sizeMismatch }
        var digest = SHA256()
        var count = 0
        while count <= asset.byteCount {
            try Task.checkCancellation()
            let chunk: Data
            do { chunk = try handle.read(upToCount: min(64 * 1024, asset.byteCount - count + 1)) ?? Data() }
            catch { return .unavailable }
            if chunk.isEmpty { break }
            count += chunk.count
            guard count <= asset.byteCount else { return .changedDuringRead }
            digest.update(data: chunk)
        }
        try Task.checkCancellation()
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              count == asset.byteCount else { return .changedDuringRead }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return actual == asset.sha256 ? .verified : .digestMismatch
    }
}
