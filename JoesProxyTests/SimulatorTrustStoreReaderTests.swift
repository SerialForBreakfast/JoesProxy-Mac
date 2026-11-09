import XCTest
import SQLite3
import CryptoKit
@testable import JoesProxy

final class SimulatorTrustStoreReaderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testReturnsInstalledWhenHashPresent() throws {
        let hash = Data(SHA256.hash(data: Data("cert-bytes".utf8)))
        let store = tempDir.appendingPathComponent("TrustStore.sqlite3")
        try makeTrustStore(at: store, sha256Rows: [hash])

        let reader = FileSimulatorTrustStoreReader { _ in store }
        XCTAssertEqual(reader.certInstallStatus(udid: "ANY", certificateSHA256: hash), .installed)
    }

    func testReturnsNotInstalledWhenHashAbsent() throws {
        let present = Data(SHA256.hash(data: Data("other".utf8)))
        let queried = Data(SHA256.hash(data: Data("cert-bytes".utf8)))
        let store = tempDir.appendingPathComponent("TrustStore.sqlite3")
        try makeTrustStore(at: store, sha256Rows: [present])

        let reader = FileSimulatorTrustStoreReader { _ in store }
        XCTAssertEqual(reader.certInstallStatus(udid: "ANY", certificateSHA256: queried), .notInstalled)
    }

    func testReturnsNotInstalledWhenStoreMissing() {
        let missing = tempDir.appendingPathComponent("Nope.sqlite3")
        let reader = FileSimulatorTrustStoreReader { _ in missing }
        XCTAssertEqual(reader.certInstallStatus(udid: "ANY", certificateSHA256: Data([0x01])), .notInstalled)
    }

    func testReturnsUnknownForMalformedDatabase() throws {
        let store = tempDir.appendingPathComponent("Bad.sqlite3")
        try Data("this is not sqlite".utf8).write(to: store)

        let reader = FileSimulatorTrustStoreReader { _ in store }
        if case .unknown = reader.certInstallStatus(udid: "ANY", certificateSHA256: Data([0x01])) {
            // expected
        } else {
            XCTFail("Expected .unknown for malformed database")
        }
    }

    // MARK: - Fixture

    private func makeTrustStore(at url: URL, sha256Rows: [Data]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(db) }

        let schema = "CREATE TABLE tsettings(sha256 BLOB NOT NULL DEFAULT '',subj BLOB NOT NULL DEFAULT '',tset BLOB,data BLOB,uuid BLOB NOT NULL DEFAULT '');"
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "test", code: 2)
        }

        for row in sha256Rows {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO tsettings(sha256) VALUES(?1);", -1, &statement, nil) == SQLITE_OK else {
                throw NSError(domain: "test", code: 3)
            }
            _ = row.withUnsafeBytes { buffer in
                sqlite3_bind_blob(statement, 1, buffer.baseAddress, Int32(buffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                sqlite3_finalize(statement)
                throw NSError(domain: "test", code: 4)
            }
            sqlite3_finalize(statement)
        }
    }
}
