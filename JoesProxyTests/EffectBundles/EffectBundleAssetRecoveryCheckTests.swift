import CryptoKit
import XCTest
@testable import JoesProxy

final class EffectBundleAssetRecoveryCheckTests: XCTestCase {
    private func fixture() throws -> EffectBundleAssetRecoveryTarget {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/AssetRecoveryTests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let bytes = Data(repeating: 42, count: 150_000)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let asset = EffectBundleAsset(id: "synthetic-image", role: .responseBody, logicalPath: "image.bin",
            sha256: hash, byteCount: bytes.count, contentType: "application/octet-stream")
        try bytes.write(to: root.appendingPathComponent(asset.packageRelativePath))
        return .init(packageURL: root, asset: asset)
    }

    func testRepeatedChecksVerifyImmutableBytes() async throws {
        let target = try fixture()
        let first = try await EffectBundleAssetRecoveryCheck.run(target)
        let second = try await EffectBundleAssetRecoveryCheck.run(target)
        XCTAssertEqual(first, .verified)
        XCTAssertEqual(second, .verified)
    }

    func testChangedBytesAndSizeAreNotAccepted() async throws {
        let target = try fixture()
        let url = target.packageURL.appendingPathComponent(target.asset.packageRelativePath)
        try Data(repeating: 43, count: target.asset.byteCount).write(to: url)
        let changed = try await EffectBundleAssetRecoveryCheck.run(target)
        XCTAssertEqual(changed, .digestMismatch)
        try Data([1]).write(to: url)
        let truncated = try await EffectBundleAssetRecoveryCheck.run(target)
        XCTAssertEqual(truncated, .sizeMismatch)
    }

    func testMissingAndUnsafeReferencesFailClosed() async throws {
        let target = try fixture()
        var asset = target.asset
        asset.sha256 = String(repeating: "0", count: 64)
        let missing = try await EffectBundleAssetRecoveryCheck.run(.init(packageURL: target.packageURL, asset: asset))
        XCTAssertEqual(missing, .unavailable)
        asset.sha256 = "../outside"
        let unsafe = try await EffectBundleAssetRecoveryCheck.run(.init(packageURL: target.packageURL, asset: asset))
        XCTAssertEqual(unsafe, .unsafeFile)
    }

    func testCancelledCallerCannotReceiveVerifiedResult() async throws {
        let target = try fixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await EffectBundleAssetRecoveryCheck.run(target)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled inspection must not report verification")
        } catch is CancellationError { }
    }
}
