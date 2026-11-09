import XCTest
@testable import JoesProxy

final class EffectBundlePackageEngineTests: XCTestCase {
    private var tempDirectory: URL!
    private var fileManager: FileManager!

    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
        tempDirectory = fileManager.temporaryDirectory.appendingPathComponent("EffectBundleEngineTests-\(UUID().uuidString)")
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory {
            try? fileManager.removeItem(at: tempDirectory)
        }
        super.tearDown()
    }

    func testWriteAndInspectPackageRoundTrip() throws {
        let engine = EffectBundlePackageEngine(fileManager: fileManager)
        let assetData = "Hello Mock Data".data(using: .utf8)!
        let assetURL = tempDirectory.appendingPathComponent("sample.json")
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
            id: UUID(),
            name: "Test Bundle",
            notes: "Test notes",
            createdAt: Date(),
            appVersion: "1.5.0",
            privacy: .exactContent,
            defaultTTLSeconds: 3600,
            assets: [asset],
            responseEffects: [responseEffect],
            hlsSubstitutions: []
        )

        let packageURL = tempDirectory.appendingPathComponent("test.jproxy-effects", isDirectory: true)
        try engine.writePackage(
            manifest: manifest,
            assetSourcesByID: [assetID: assetURL],
            to: packageURL
        )

        let (readManifest, inspection) = try engine.inspectPackage(at: packageURL)
        XCTAssertEqual(readManifest.id, manifest.id)
        XCTAssertEqual(readManifest.name, "Test Bundle")
        XCTAssertEqual(readManifest.responseEffects.count, 1)
        XCTAssertEqual(readManifest.assets.count, 1)
        XCTAssertEqual(inspection.responseEffectCount, 1)
        XCTAssertEqual(inspection.assetCount, 1)
        XCTAssertEqual(inspection.assetByteCount, assetData.count)
    }

    func testRejectsPathTraversalInLogicalPath() {
        let manifest = EffectBundleManifest(
            schemaVersion: EffectBundleSchema.currentVersion,
            id: UUID(),
            name: "Invalid Bundle",
            notes: "",
            createdAt: Date(),
            appVersion: "1.5.0",
            privacy: .exactContent,
            defaultTTLSeconds: 3600,
            assets: [
                EffectBundleAsset(
                    id: "asset-bad",
                    role: .responseBody,
                    logicalPath: "../outside.json",
                    sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                    byteCount: 0,
                    contentType: nil
                )
            ],
            responseEffects: [],
            hlsSubstitutions: []
        )

        XCTAssertThrowsError(try EffectBundleValidator.validateManifest(manifest)) { error in
            guard let bundleError = error as? EffectBundleError else {
                XCTFail("Expected EffectBundleError, got \(error)")
                return
            }
            XCTAssertEqual(bundleError, .unsafePath("../outside.json"))
        }
    }

    func testEnforcesMaxNameLength() {
        let longName = String(repeating: "A", count: 150)
        let manifest = EffectBundleManifest(
            schemaVersion: EffectBundleSchema.currentVersion,
            id: UUID(),
            name: longName,
            notes: "",
            createdAt: Date(),
            appVersion: "1.5.0",
            privacy: .exactContent,
            defaultTTLSeconds: 3600,
            assets: [],
            responseEffects: [],
            hlsSubstitutions: []
        )

        XCTAssertThrowsError(try EffectBundleValidator.validateManifest(manifest)) { error in
            guard let bundleError = error as? EffectBundleError else {
                XCTFail("Expected EffectBundleError, got \(error)")
                return
            }
            XCTAssertEqual(bundleError, .invalidName)
        }
    }
}
