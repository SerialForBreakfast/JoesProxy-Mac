import XCTest
@testable import JoesProxy

@MainActor
final class EffectBundleActivationTests: XCTestCase {
    private var tempDirectory: URL!
    private var fileManager: FileManager!
    private var repository: EffectBundleRepository!
    private var responseOverrideStore: ResponseOverrideStore!
    private var hlsCoordinator: HLSSubstitutionCoordinator!
    private var activationGate: EffectBundleActivationGate!
    private var coordinator: EffectBundleActivationCoordinator!

    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
        tempDirectory = fileManager.temporaryDirectory.appendingPathComponent("EffectBundleActivationTests-\(UUID().uuidString)")
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let persistenceURL = tempDirectory.appendingPathComponent("effect-bundles.json")
        let packagesRootURL = tempDirectory.appendingPathComponent("Packages", isDirectory: true)

        activationGate = EffectBundleActivationGate()
        responseOverrideStore = ResponseOverrideStore(effectBundleGate: activationGate)
        let runStore = HLSFixtureRunStore()
        let routeStore = HLSSubstitutionRouteStore(effectBundleGate: activationGate)
        hlsCoordinator = HLSSubstitutionCoordinator(
            runStore: runStore,
            routeStore: routeStore,
            responseOverrideStore: responseOverrideStore
        )

        repository = EffectBundleRepository(
            persistenceURL: persistenceURL,
            packagesRootURL: packagesRootURL,
            fileManager: fileManager
        )

        coordinator = EffectBundleActivationCoordinator(
            repository: repository,
            responseOverrideStore: responseOverrideStore,
            hlsCoordinator: hlsCoordinator,
            activationGate: activationGate,
            runtimeRootURL: tempDirectory.appendingPathComponent("Runtime", isDirectory: true),
            fileManager: fileManager
        )
    }

    override func tearDown() {
        if let tempDirectory {
            try? fileManager.removeItem(at: tempDirectory)
        }
        super.tearDown()
    }

    private func createSamplePackage(id: UUID = UUID(), name: String = "Sample") throws -> URL {
        let engine = EffectBundlePackageEngine(fileManager: fileManager)
        let assetData = "{}".data(using: .utf8)!
        let assetURL = tempDirectory.appendingPathComponent("sample-\(id.uuidString).json")
        try assetData.write(to: assetURL)

        let assetID = "asset-1"
        let sha256 = EffectBundleValidator.sha256Hex(assetData)
        let asset = EffectBundleAsset(
            id: assetID,
            role: .responseBody,
            logicalPath: "sample.json",
            sha256: sha256,
            byteCount: assetData.count,
            contentType: "application/json"
        )

        let responseEffect = EffectBundleResponseEffect(
            id: UUID(),
            label: "Test Map Local",
            requestMethod: "GET",
            requestScheme: .https,
            host: "api.example.com",
            port: 443,
            path: "/test",
            matchMode: .exactPath,
            sourceKind: .localFile,
            statusCode: 200,
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
            bodySource: EffectBundleBodySource(kind: .file, assetIDs: [assetID], rootLogicalPath: nil),
            mapRemoteHost: nil,
            mapRemotePort: nil,
            mapRemoteScheme: nil,
            mapRemotePath: nil,
            mapRemoteQueryPolicy: .preserve,
            mapRemoteQuery: nil,
            bookmarkRewriteRequest: nil,
            liveResponseRewrites: [],
            expectedSchemaFingerprint: nil,
            dropConnection: false,
            forceNoCache: true,
            notFoundRelativePath: nil,
            missingFilePolicy: .strictLocal,
            graphQLOperationName: nil,
            matchQueryKey: nil,
            matchQueryValue: nil,
            matchHeaderName: nil,
            matchHeaderValue: nil,
            sourceClientAddress: nil
        )

        let manifest = EffectBundleManifest(
            schemaVersion: EffectBundleSchema.currentVersion,
            id: id,
            name: name,
            notes: "",
            createdAt: Date(),
            appVersion: "1.5.0",
            privacy: .exactContent,
            defaultTTLSeconds: 3600,
            assets: [asset],
            responseEffects: [responseEffect],
            hlsSubstitutions: []
        )

        let packageURL = tempDirectory.appendingPathComponent("\(id.uuidString).jproxy-effects", isDirectory: true)
        try engine.writePackage(
            manifest: manifest,
            assetSourcesByID: [assetID: assetURL],
            to: packageURL
        )
        return packageURL
    }

    func testImportPersistsInactiveRecord() throws {
        let bundleID = UUID()
        let packageURL = try createPackage(id: bundleID, name: "Inactive Test")
        let record = try repository.importPackage(at: packageURL, owner: .localUser)

        XCTAssertEqual(record.id, bundleID)
        XCTAssertEqual(record.state, .inactive)
        XCTAssertFalse(record.isServing)
        XCTAssertEqual(repository.records.count, 1)
    }

    func testAtomicActivationOpensGateAndStopClosesGate() async throws {
        let bundleID = UUID()
        let packageURL = try createPackage(id: bundleID, name: "Activation Test")
        let record = try repository.importPackage(at: packageURL, owner: .localUser)

        XCTAssertFalse(activationGate.allows(bundleID: bundleID))

        let receipt = try await coordinator.activate(id: record.id, requestingOwnerID: EffectBundleOwner.localUser.ownerID)
        XCTAssertEqual(receipt.bundleID, bundleID)
        XCTAssertTrue(activationGate.allows(bundleID: bundleID))
        XCTAssertEqual(repository.record(id: bundleID)?.state, .serving)

        try await coordinator.stop(id: bundleID, requestingOwnerID: EffectBundleOwner.localUser.ownerID)
        XCTAssertFalse(activationGate.allows(bundleID: bundleID))
        XCTAssertEqual(repository.record(id: bundleID)?.state, .stopped)
    }

    private func createPackage(id: UUID, name: String) throws -> URL {
        try createSamplePackage(id: id, name: name)
    }
}
