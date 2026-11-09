import Foundation
import SQLite3
import os

enum SimulatorCertInstallStatus: Equatable, Sendable {
    case installed
    case notInstalled
    case unknown(String)
}

protocol SimulatorTrustStoreReading: Sendable {
    /// Checks whether a certificate (identified by its DER SHA-256) is present in a simulator's
    /// trust store. Best-effort: returns `.unknown` rather than throwing if the store can't be read.
    func certInstallStatus(udid: String, certificateSHA256: Data) -> SimulatorCertInstallStatus
}

/// Reads a booted simulator's trustd TrustStore (SQLite) to detect an installed root certificate.
/// The `tsettings.sha256` column holds the DER SHA-256 of each trusted root.
struct FileSimulatorTrustStoreReader: SimulatorTrustStoreReading {
    private let trustStoreURL: @Sendable (String) -> URL
    private let logger = Logger(subsystem: "com.JoesProxyApp.SimulatorSetup", category: "TrustStore")

    init(trustStoreURL: @escaping @Sendable (String) -> URL = FileSimulatorTrustStoreReader.defaultTrustStoreURL) {
        self.trustStoreURL = trustStoreURL
    }

    static let defaultTrustStoreURL: @Sendable (String) -> URL = { udid in
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)/data/private/var/protected/trustd/private/TrustStore.sqlite3")
    }

    func certInstallStatus(udid: String, certificateSHA256: Data) -> SimulatorCertInstallStatus {
        let url = trustStoreURL(udid)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .notInstalled
        }
        return Self.queryCount(databaseURL: url, sha256: certificateSHA256, logger: logger)
    }

    // MARK: - SQLite

    private static func queryCount(databaseURL: URL, sha256: Data, logger: Logger) -> SimulatorCertInstallStatus {
        // Open read-only + immutable so a running simulator's locks don't block us.
        let uri = "file:\(databaseURL.path)?immutable=1"
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, db != nil else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            logger.error("Simulator setup: trust store open failed: \(message, privacy: .public)")
            return .unknown(message)
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let sql = "SELECT count(*) FROM tsettings WHERE sha256 = ?1;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            logger.error("Simulator setup: trust store query prepare failed: \(message, privacy: .public)")
            return .unknown(message)
        }
        defer { sqlite3_finalize(statement) }

        let bindResult = sha256.withUnsafeBytes { buffer -> Int32 in
            sqlite3_bind_blob(statement, 1, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
        }
        guard bindResult == SQLITE_OK else {
            return .unknown("bind failed")
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return .unknown("no result row")
        }
        let count = sqlite3_column_int(statement, 0)
        return count > 0 ? .installed : .notInstalled
    }
}

// SQLITE_TRANSIENT tells SQLite to copy the bound bytes (the buffer is freed after this call).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
