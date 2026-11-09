import XCTest
@testable import JoesProxy

@MainActor
final class EffectBundleRepositoryTests: XCTestCase {
    func testImportCopiesValidatedPackageAndKeepsItInactive() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jproxy-effects", isDirectory: true)
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        let persistence = root.appendingPathComponent("records.json")
        let manifest = makeManifest(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        try EffectBundlePackageEngine().writePackage(manifest: manifest, assetSourcesByID: [:], to: source)

        let repository = EffectBundleRepository(
            persistenceURL: persistence,
            packagesRootURL: managed
        )
        let imported = try repository.importPackage(at: source, owner: .localUser)

        XCTAssertEqual(imported.state, .inactive)
        XCTAssertEqual(imported.manifest, manifest)
        XCTAssertEqual(repository.records.count, 1)
        XCTAssertEqual(try repository.inspect(id: manifest.id).id, manifest.id)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: managed.appendingPathComponent(imported.managedPackagePath).path
        ))
    }

    func testRelaunchRestoresServingRecordAsStopped() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jproxy-effects", isDirectory: true)
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        let persistence = root.appendingPathComponent("records.json")
        let id = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        try EffectBundlePackageEngine().writePackage(
            manifest: makeManifest(id: id),
            assetSourcesByID: [:],
            to: source
        )
        let importTime = Date(timeIntervalSince1970: 1_700_000_000)
        let repository = EffectBundleRepository(
            persistenceURL: persistence,
            packagesRootURL: managed,
            clock: { importTime }
        )
        _ = try repository.importPackage(at: source, owner: .localUser)
        _ = try repository.markServing(
            id: id,
            activatedAt: importTime,
            expiresAt: importTime.addingTimeInterval(60)
        )

        let relaunchTime = importTime.addingTimeInterval(10)
        let relaunched = EffectBundleRepository(
            persistenceURL: persistence,
            packagesRootURL: managed,
            clock: { relaunchTime }
        )

        XCTAssertEqual(relaunched.record(id: id)?.state, .stopped)
        XCTAssertEqual(relaunched.record(id: id)?.stoppedAt, relaunchTime)
        XCTAssertNil(relaunched.record(id: id)?.expiresAt)
    }

    func testOwnershipAndServingStateProtectDiscard() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jproxy-effects", isDirectory: true)
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        let persistence = root.appendingPathComponent("records.json")
        let id = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        try EffectBundlePackageEngine().writePackage(
            manifest: makeManifest(id: id),
            assetSourcesByID: [:],
            to: source
        )
        let repository = EffectBundleRepository(
            persistenceURL: persistence,
            packagesRootURL: managed
        )
        _ = try repository.importPackage(
            at: source,
            owner: .mcpClient(id: "owner-a", displayName: "Agent")
        )

        XCTAssertThrowsError(try repository.discard(id: id, requestingOwnerID: "owner-b")) { error in
            XCTAssertEqual(error as? EffectBundleError, .notOwner)
        }
        _ = try repository.markServing(id: id, activatedAt: Date(), expiresAt: Date().addingTimeInterval(60))
        XCTAssertThrowsError(try repository.discard(id: id, requestingOwnerID: "owner-a")) { error in
            XCTAssertEqual(error as? EffectBundleError, .bundleIsServing)
        }
        _ = try repository.markStopped(id: id, at: Date())
        try repository.discard(id: id, requestingOwnerID: "owner-a")
        XCTAssertNil(repository.record(id: id))
    }

    private func makeManifest(id: UUID) -> EffectBundleManifest {
        EffectBundleManifest(
            schemaVersion: EffectBundleSchema.currentVersion,
            id: id,
            name: "Unavailable response",
            notes: "Imported package test.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "test",
            privacy: .exactContent,
            defaultTTLSeconds: EffectBundleBudget.defaultTTL,
            assets: [],
            responseEffects: [],
            hlsSubstitutions: []
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("effect-bundle-repository-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
