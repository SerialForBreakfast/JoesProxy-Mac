import Foundation

enum ReproPackageError: LocalizedError {
    case fileNotFound(URL)
    case malformedPackage(Error)
    case schemaTooNew(Int)
    case sessionLimitExceeded(Int)
    case fileTooLarge(Int)
    case noReplayableSessions
    case proxyNotRunning

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "Reproduction package not found: \(url.lastPathComponent)"
        case .malformedPackage(let error):
            return "The reproduction package could not be read: \(error.localizedDescription)"
        case .schemaTooNew(let version):
            return "This reproduction package uses schema version \(version), which requires a newer JoesProxy build."
        case .sessionLimitExceeded(let count):
            return "The reproduction package contains \(count) sessions, exceeding the supported limit."
        case .fileTooLarge(let count):
            return "The reproduction package is too large to open safely (\(count) bytes)."
        case .noReplayableSessions:
            return "The reproduction package does not contain a request that is safe to replay."
        case .proxyNotRunning:
            return "Start the proxy before replaying a reproduction request."
        }
    }
}

struct ReproPackageEngine: Sendable {
    static let maximumSessionCount = 1_000
    static let maximumFileByteCount = 64 * 1_024 * 1_024

    func makePackage(
        title: String,
        notes: String,
        source: ReproPackageSource = .nativeCapture,
        sessions: [SessionRecord],
        hypothesisGraphs: [HypothesisGraph] = [],
        appVersion: String,
        createdAt: Date = Date()
    ) throws -> ReproPackage {
        guard sessions.count <= Self.maximumSessionCount else {
            throw ReproPackageError.sessionLimitExceeded(sessions.count)
        }
        var accumulator = ReproRedactionAccumulator()
        let sanitizedSessions = sessions.enumerated().map { index, session in
            ReproPackageRedactor.sanitizeSession(
                session,
                id: source == .harImport ? "har-\(index + 1)" : nil,
                accumulator: &accumulator
            )
        }
        let sanitizedGraphs = hypothesisGraphs.map {
            ReproPackageRedactor.sanitizeGraph($0, accumulator: &accumulator)
        }
        let sanitizedTitle = ReproPackageRedactor.sanitizeFreeform(title, accumulator: &accumulator)
        let sanitizedNotes = ReproPackageRedactor.sanitizeFreeform(notes, accumulator: &accumulator)
        let scripts = sanitizedSessions.map(makeScript)
        return ReproPackage(
            schemaVersion: ReproPackage.currentSchemaVersion,
            createdAt: createdAt,
            appVersion: appVersion,
            title: sanitizedTitle,
            notes: sanitizedNotes,
            source: source,
            sessions: sanitizedSessions,
            hypothesisGraphs: sanitizedGraphs,
            scripts: scripts,
            redactionReport: accumulator.report
        )
    }

    func data(for package: ReproPackage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(package)
    }

    func write(_ package: ReproPackage, to url: URL) throws {
        try data(for: package).write(to: url, options: .atomic)
    }

    func read(from url: URL) throws -> ReproPackage {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReproPackageError.fileNotFound(url)
        }
        let data = try Data(contentsOf: url)
        return try read(data: data)
    }

    func read(data: Data) throws -> ReproPackage {
        guard data.count <= Self.maximumFileByteCount else {
            throw ReproPackageError.fileTooLarge(data.count)
        }
        let package: ReproPackage
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            package = try decoder.decode(ReproPackage.self, from: data)
        } catch {
            throw ReproPackageError.malformedPackage(error)
        }
        guard package.schemaVersion <= ReproPackage.currentSchemaVersion else {
            throw ReproPackageError.schemaTooNew(package.schemaVersion)
        }
        guard package.sessions.count <= Self.maximumSessionCount else {
            throw ReproPackageError.sessionLimitExceeded(package.sessions.count)
        }
        return package
    }

    func inspection(of package: ReproPackage) -> ReproPackageInspection {
        ReproPackageInspection(
            schemaVersion: package.schemaVersion,
            title: package.title,
            source: package.source,
            sessionCount: package.sessions.count,
            hypothesisGraphCount: package.hypothesisGraphs.count,
            scriptCount: package.scripts.count,
            redactionReport: package.redactionReport,
            replayableSessionCount: package.sessions.filter(isReplayable).count
        )
    }

    func capturedRequest(for session: ReproSession) -> CapturedRequest? {
        guard isReplayable(session) else { return nil }
        return CapturedRequest(
            method: session.request.method,
            scheme: session.request.scheme,
            host: session.request.host,
            port: session.request.port,
            path: session.request.path,
            headers: session.request.headers.filter {
                $0.value != ReproPackageRedactor.placeholder
            },
            bodyData: nil,
            bodySize: nil
        )
    }

    private func isReplayable(_ session: ReproSession) -> Bool {
        session.request.host != "private-host.invalid"
            && !session.request.host.isEmpty
            && !session.request.path.contains(ReproPackageRedactor.placeholder)
            && ["GET", "HEAD", "OPTIONS"].contains(session.request.method.uppercased())
    }

    private func makeScript(for session: ReproSession) -> ReproScript {
        var parts = ["curl", "--request", shellQuote(session.request.method)]
        for header in session.request.headers where header.value != ReproPackageRedactor.placeholder {
            parts.append("--header")
            parts.append(shellQuote("\(header.name): \(header.value)"))
        }
        let port = session.request.port.map { ":\($0)" } ?? ""
        let url = "\(session.request.scheme.rawValue)://\(session.request.host)\(port)\(session.request.path)"
        parts.append(shellQuote(url))
        return ReproScript(
            id: "script-\(session.id)",
            sessionID: session.id,
            title: "Replay \(session.request.method) \(session.request.host)",
            command: parts.joined(separator: " ")
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
