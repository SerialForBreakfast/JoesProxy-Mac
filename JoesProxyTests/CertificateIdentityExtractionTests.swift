import XCTest
@testable import JoesProxy

final class CertificateIdentityExtractionTests: XCTestCase {
    func testFingerprintMatchesProfileSnapshotFactory() throws {
        let factory = SwiftCertificateFactory()
        let identity = try factory.generateRootIdentity(
            label: "JoesProxy Root CA",
            commonName: "JoesProxy Root CA"
        )
        let extracted = CertificateIdentityExtraction.sha256Fingerprint(from: identity.certificateData)
        let legacy = ProfileSnapshotFactory.certificateFingerprint(from: identity.certificateData)
        XCTAssertEqual(extracted, legacy)
        XCTAssertEqual(extracted.count, 64)
    }

    func testShortCodeIsStableFourDashFour() {
        let id = UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890")!
        XCTAssertEqual(CertificateIdentityExtraction.shortCode(from: id), "ABCD-EF12")
    }

    func testSerialAndValidityExtractFromGeneratedRoot() throws {
        let identity = try SwiftCertificateFactory().generateRootIdentity(
            label: "JoesProxy Root CA",
            commonName: "JoesProxy Root CA"
        )
        XCTAssertNotNil(CertificateIdentityExtraction.serialNumber(from: identity.certificateData))
        XCTAssertNotNil(CertificateIdentityExtraction.notBefore(from: identity.certificateData))
        XCTAssertNotNil(CertificateIdentityExtraction.notAfter(from: identity.certificateData))
    }

    func testIdentityStatusTransitions() throws {
        let identity = try SwiftCertificateFactory().generateRootIdentity(
            label: "JoesProxy Root CA",
            commonName: "JoesProxy Root CA"
        )
        XCTAssertEqual(
            CertificateIdentityExtraction.evaluateIdentityStatus(
                rootCertificateData: identity.certificateData,
                metadata: nil
            ),
            .legacyIdentityUnknown
        )

        let metadata = CAInstanceMetadata.makeCurrent(from: identity)
        XCTAssertEqual(
            CertificateIdentityExtraction.evaluateIdentityStatus(
                rootCertificateData: identity.certificateData,
                metadata: metadata
            ),
            .valid
        )

        XCTAssertEqual(
            CertificateIdentityExtraction.evaluateIdentityStatus(
                rootCertificateData: nil,
                metadata: nil
            ),
            .missing
        )
    }
}

@MainActor
final class CAInstanceMetadataStoreTests: XCTestCase {
    func testUpsertAdoptLegacyAndRetire() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ca-meta-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = CAInstanceMetadataStore(persistenceURL: url)
        store.load()
        XCTAssertTrue(store.isLoaded)

        let identity = try SwiftCertificateFactory().generateRootIdentity(
            label: "JoesProxy Root CA",
            commonName: "JoesProxy Root CA"
        )
        let fingerprint = CertificateIdentityExtraction.sha256Fingerprint(from: identity.certificateData)

        XCTAssertNil(store.metadata(forFingerprint: fingerprint))
        let adopted = try store.adoptLegacy(identity: identity)
        XCTAssertEqual(adopted.storageState, .current)
        XCTAssertEqual(store.metadata(forFingerprint: fingerprint)?.shortCode, adopted.shortCode)

        let retired = try store.markRetired(fingerprint: fingerprint)
        XCTAssertEqual(retired.storageState, .retired)

        let reloaded = CAInstanceMetadataStore(persistenceURL: url)
        reloaded.load()
        XCTAssertEqual(reloaded.metadata(forFingerprint: fingerprint)?.storageState, .retired)
    }

    func testNewCurrentDemotesPreviousCurrent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ca-meta-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CAInstanceMetadataStore(persistenceURL: url)
        store.load()

        let first = try SwiftCertificateFactory().generateRootIdentity(
            label: "JoesProxy Root CA",
            commonName: "JoesProxy Root CA"
        )
        let second = try SwiftCertificateFactory().generateRootIdentity(
            label: "JoesProxy Root CA",
            commonName: "JoesProxy Root CA"
        )
        let firstMeta = try store.upsert(CAInstanceMetadata.makeCurrent(from: first))
        _ = try store.upsert(CAInstanceMetadata.makeCurrent(from: second))

        XCTAssertEqual(
            store.metadata(forFingerprint: firstMeta.certificateSHA256Fingerprint)?.storageState,
            .retired
        )
        XCTAssertEqual(store.currentInstance()?.storageState, .current)
    }
}
