import Compression
import CryptoKit
import Darwin
import Foundation

enum ArtifactSourceKind: String, Codable, Sendable, CaseIterable {
    case recording, har, json, text, image, effectBundle
}

struct ArtifactSnapshot: Sendable {
    let kind: ArtifactSourceKind
    let originalBytes: Data
    let packageMembers: [String: Data]
    let sourceSHA256: String
    let records: [ArtifactSessionProjection?]
    let schemaVersion: Int?
    let warnings: [String]
    let retainedBytes: Int
    let frameCount: Int?
    var imageWidth: Int? = nil
    var imageHeight: Int? = nil
    var imageOrientation: Int? = nil

    var byteCount: Int { originalBytes.count + packageMembers.values.reduce(0) { $0 + $1.count } }
    var invalidRecordCount: Int { records.filter { $0 == nil }.count }

    func calculate(dataset: ArtifactCalculationDataset, query: ArtifactCalculation.Query,
                   deadline: ContinuousClock.Instant) throws -> ArtifactCalculation.Report {
        switch dataset {
        case .json:
            guard kind == .json else { throw ArtifactAnalysisFailure.unsupportedKind }
            return try ArtifactCalculation.analyze(data: originalBytes, query: query, deadline: deadline)
        case .responseJSON(let index):
            guard records.indices.contains(index), let record = records[index],
                  let bytes = record.responseJSON else { throw ArtifactAnalysisFailure.incompleteSelection }
            return try ArtifactCalculation.analyze(data: bytes, query: query, deadline: deadline)
        case .sessionMetadata(let indices):
            guard kind == .recording || kind == .har else { throw ArtifactAnalysisFailure.unsupportedKind }
            try ArtifactSessionProjection.validateMetadata(query)
            let selection = indices ?? Array(records.indices)
            let rows = try selection.map { index -> ArtifactJSONValue in
                guard records.indices.contains(index), let record = records[index] else { throw ArtifactAnalysisFailure.incompleteSelection }
                return record.metadata
            }
            return try ArtifactCalculation.analyze(rows: rows, query: query, deadline: deadline)
        }
    }
}

enum ArtifactCalculationDataset: Sendable {
    case json, responseJSON(Int), sessionMetadata([Int]?)

    init(_ object: [String: Any]) throws {
        func integer(_ value: Any) throws -> Int {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == Double(number.intValue), (0..<1000).contains(number.intValue) else {
                throw ArtifactAnalysisFailure.malformedRequest
            }
            return number.intValue
        }
        switch object["kind"] as? String {
        case "json":
            guard Set(object.keys) == ["kind"] else { throw ArtifactAnalysisFailure.malformedRequest }
            self = .json
        case "responseJSON":
            guard Set(object.keys) == ["kind", "recordIndex"], let value = object["recordIndex"] else { throw ArtifactAnalysisFailure.malformedRequest }
            self = .responseJSON(try integer(value))
        case "sessionMetadata":
            guard Set(object.keys).isSubset(of: ["kind", "recordIndices"]) else { throw ArtifactAnalysisFailure.malformedRequest }
            if let value = object["recordIndices"] {
                guard let array = value as? [Any], !array.isEmpty, array.count <= 256 else { throw ArtifactAnalysisFailure.malformedRequest }
                let indices = try array.map(integer)
                guard indices == indices.sorted(), Set(indices).count == indices.count else { throw ArtifactAnalysisFailure.malformedRequest }
                self = .sessionMetadata(indices)
            } else { self = .sessionMetadata(nil) }
        default: throw ArtifactAnalysisFailure.malformedRequest
        }
    }
}

/// Isolated read-only preparation. This type has no capture store, bundle runtime or network owner.
enum ArtifactSnapshotReader {
    static let maximumFileBytes = 32 * 1024 * 1024
    static let maximumRetainedBytes = 64 * 1024 * 1024

    static func read(url: URL, kind: ArtifactSourceKind, deadline: ContinuousClock.Instant, budget: Int = maximumRetainedBytes) throws -> ArtifactSnapshot {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try check(deadline)
        let values = try url.resourceValues(forKeys: [.volumeIsLocalKey, .isAliasFileKey,
            .isSymbolicLinkKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values.volumeIsLocal == true, values.isAliasFile != true, values.isSymbolicLink != true else {
            throw ArtifactAnalysisFailure.sourceUnavailable
        }
        if values.isUbiquitousItem == true {
            guard values.ubiquitousItemDownloadingStatus == .current || values.ubiquitousItemDownloadingStatus == .downloaded else {
                throw ArtifactAnalysisFailure.sourceUnavailable
            }
        }
        if kind == .effectBundle { return try readPackage(url: url, deadline: deadline) }
        let maximum = kind == .json || kind == .text ? 4 * 1024 * 1024 : maximumFileBytes
        let data = try stableRead(url: url, maximum: min(maximum, budget), deadline: deadline)
        return try decode(data: data, kind: kind, deadline: deadline, budget: budget)
    }

    static func decode(data: Data, kind: ArtifactSourceKind, deadline: ContinuousClock.Instant, budget: Int = maximumRetainedBytes) throws -> ArtifactSnapshot {
        let budget = min(budget, maximumRetainedBytes)
        guard data.count <= min(maximumFileBytes, budget) else { throw ArtifactAnalysisFailure.inputLimit }
        var records: [ArtifactSessionProjection?] = []
        var schema: Int?
        var warnings: [String] = []
        var frames: Int?
        var imageWidth: Int?
        var imageHeight: Int?
        var imageOrientation: Int?
        switch kind {
        case .json:
            var reader = try ArtifactJSONReader(data: data,
                limits: .init(bytes: 4_194_304, scratchBytes: 32 * 1024 * 1024), deadline: deadline)
            _ = try reader.read()
        case .text:
            guard data.count <= 4_194_304 else { throw ArtifactAnalysisFailure.inputLimit }
            guard String(data: data, encoding: .utf8) != nil else { throw ArtifactAnalysisFailure.malformedSource }
        case .image:
            let preflight = ImageInspectionPreflight.inspect(data)
            guard preflight.reason == nil else {
                throw preflight.reason == "malformed_metadata" ? ArtifactAnalysisFailure.malformedSource : .inputLimit
            }
            frames = preflight.frameCount
            imageWidth = preflight.width
            imageHeight = preflight.height
            imageOrientation = preflight.orientation
            warnings = ["metadata_only_no_pixel_decode"]
        case .recording, .har:
            let compressed = kind == .recording && data.starts(with: RecordingContainer.magic)
            let workspace = budget - data.count - 24 * 1024 * 1024
            guard workspace > 0 else { throw ArtifactAnalysisFailure.inputLimit }
            let expanded = compressed ? try unwrap(data, deadline: deadline, maximum: min(maximumFileBytes, workspace)) : data
            let scratch = workspace - (compressed ? expanded.count : 0)
            guard scratch > 0 else { throw ArtifactAnalysisFailure.inputLimit }
            var reader = try ArtifactJSONReader(data: expanded,
                limits: .init(bytes: maximumFileBytes, tokens: 1_000_000, stringBytes: 4_194_304,
                    scratchBytes: scratch, arrayElementBytes: 4_194_304), deadline: deadline)
            let root = try reader.read()
            let entries: [ArtifactJSONValue]
            if kind == .recording {
                guard case .array(let array)? = root.member("sessions") else { throw ArtifactAnalysisFailure.malformedSource }
                entries = array
                if let value = root.member("schemaVersion") {
                    guard case .number(let token) = value, let version = Int(token), version >= 0 else { throw ArtifactAnalysisFailure.malformedSource }
                    schema = version
                } else { schema = 0 }
                guard (schema ?? 0) <= RecordingConstants.currentSchemaVersion else { throw ArtifactAnalysisFailure.unsupportedSchema }
                guard case .object(let fields) = root else { throw ArtifactAnalysisFailure.malformedSource }
                let headerData = try ArtifactJSONValue.object(fields.filter { $0.0 != "sessions" }).encoded(maximum: 1_048_576, deadline: deadline)
                guard let headerRoot = try JSONSerialization.jsonObject(with: headerData) as? [String: Any] else { throw ArtifactAnalysisFailure.malformedSource }
                let header = try JSONSessionRecordingImportService.header(fromRoot: headerRoot)
                if header.sessionCount != entries.count { warnings.append("declared_count_mismatch") }
                if schema == 0 { warnings.append("legacy_schema") }
            } else {
                guard case .array(let array)? = root.member("log")?.member("entries") else { throw ArtifactAnalysisFailure.malformedSource }
                entries = array
            }
            guard entries.count <= 1000 else { throw ArtifactAnalysisFailure.inputLimit }
            var bodyBytes = 0
            for entry in entries {
                try check(deadline)
                for side in ["request", "response"] {
                    if let headers = entry.member(side)?.member("headers") { _ = try headers.encoded(maximum: 1_048_576, deadline: deadline) }
                }
                let entryData = try entry.encoded(maximum: 4_194_304, deadline: deadline)
                if kind == .recording {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    guard let record = try? decoder.decode(SessionRecord.self, from: entryData) else { records.append(nil); continue }
                    guard record.request.method.utf8.count <= 256 else { throw ArtifactAnalysisFailure.inputLimit }
                    let projection = ArtifactSessionProjection(record: record, prepareSearch: true)
                    bodyBytes += projection.responseJSON?.count ?? 0
                    guard bodyBytes <= 8_388_608 else { throw ArtifactAnalysisFailure.inputLimit }
                    records.append(projection)
                } else {
                    var envelope = Data("{\"log\":{\"entries\":[".utf8)
                    envelope.append(entryData)
                    envelope.append(Data("]}}".utf8))
                    guard let imported = try? ReproHARImportService().decode(data: envelope),
                          let record = imported.sessions.first else { records.append(nil); continue }
                    guard record.request.method.utf8.count <= 256 else { throw ArtifactAnalysisFailure.inputLimit }
                    let content = entry.member("response")?.member("content")
                    let supportedEncoding: Bool
                    switch content?.member("encoding") {
                    case nil: supportedEncoding = true
                    case .string("base64")?: supportedEncoding = true
                    default: supportedEncoding = false
                    }
                    let declared = content?.member("size")
                    let decodedCount = record.response?.bodyData?.count
                    let complete: Bool
                    if case .number(let token)? = declared, let size = Int(token), size >= 0 {
                        complete = supportedEncoding && decodedCount == size
                    } else { complete = false }
                    // HAR content.text is already decoded representation; do not gunzip it again.
                    var adjusted = record
                    if let response = record.response {
                        let mime: String?
                        if case .string(let value)? = content?.member("mimeType") { mime = value } else { mime = nil }
                        var headers = response.headers.filter { !["content-encoding", "transfer-encoding", "content-type"].contains($0.name.lowercased()) }
                        if let mime { headers.append(HTTPHeaderField(name: "Content-Type", value: mime)) }
                        adjusted.response = CapturedResponse(statusCode: response.statusCode, headers: headers,
                            bodyData: response.bodyData, bodySize: response.bodySize)
                    }
                    let projection = ArtifactSessionProjection(record: adjusted, completenessOverride: complete, prepareSearch: true)
                    bodyBytes += projection.responseJSON?.count ?? 0
                    guard bodyBytes <= 8_388_608 else { throw ArtifactAnalysisFailure.inputLimit }
                    records.append(projection)
                }
            }
            if records.contains(where: { $0 == nil }) { warnings.append("invalid_records_preserved_as_gaps") }
            if records.contains(where: { $0?.responseComplete == false }) { warnings.append("incomplete_bodies") }
        case .effectBundle: throw ArtifactAnalysisFailure.unsupportedKind
        }
        try check(deadline)
        let retained = data.count + records.reduce(0) { $0 + ($1?.responseJSON?.count ?? 0) + 2048 }
        guard retained <= budget else { throw ArtifactAnalysisFailure.inputLimit }
        return ArtifactSnapshot(kind: kind, originalBytes: data, packageMembers: [:], sourceSHA256: hash(data),
            records: records, schemaVersion: schema, warnings: warnings, retainedBytes: retained, frameCount: frames,
            imageWidth: imageWidth, imageHeight: imageHeight, imageOrientation: imageOrientation)
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func check(_ deadline: ContinuousClock.Instant) throws {
        guard !Task.isCancelled else { throw ArtifactAnalysisFailure.cancelled }
        guard ContinuousClock.now < deadline else { throw ArtifactAnalysisFailure.deadlineExceeded }
    }

    private static func stableRead(url: URL, maximum: Int, deadline: ContinuousClock.Instant,
                                   rootDescriptor: Int32? = nil, relativePath: String? = nil) throws -> Data {
        let descriptor: Int32
        if let rootDescriptor, let relativePath { descriptor = try openAnchored(rootDescriptor, path: relativePath) }
        else { descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw ArtifactAnalysisFailure.sourceUnavailable }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= maximum else { throw ArtifactAnalysisFailure.inputLimit }
        var result = Data(capacity: Int(before.st_size))
        _ = try scanDescriptor(descriptor, maximum: maximum, deadline: deadline) { bytes in
            result.append(contentsOf: bytes)
        }
        guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw ArtifactAnalysisFailure.sourceUnavailable }
        var hasher = SHA256()
        let total = try scanDescriptor(descriptor, maximum: maximum, deadline: deadline) {
            hasher.update(bufferPointer: $0)
        }
        var after = stat()
        var path = stat()
        let pathStatus: Int32
        if let rootDescriptor, let relativePath {
            let checkDescriptor = try openAnchored(rootDescriptor, path: relativePath)
            defer { close(checkDescriptor) }
            pathStatus = fstat(checkDescriptor, &path)
        } else { pathStatus = lstat(url.path, &path) }
        guard fstat(descriptor, &after) == 0, pathStatus == 0,
              sameFile(before, after), sameFile(after, path), total == result.count,
              Data(hasher.finalize()) == Data(SHA256.hash(data: result)) else { throw ArtifactAnalysisFailure.sourceChanged }
        return result
    }

    private static func openAnchored(_ root: Int32, path: String) throws -> Int32 {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 8, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ArtifactAnalysisFailure.malformedSource
        }
        var parent = dup(root)
        guard parent >= 0 else { throw ArtifactAnalysisFailure.sourceUnavailable }
        for (index, part) in parts.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (index == parts.count - 1 ? 0 : O_DIRECTORY)
            let next = openat(parent, part, flags)
            close(parent)
            guard next >= 0 else { throw ArtifactAnalysisFailure.sourceChanged }
            parent = next
        }
        return parent
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size &&
        lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
        lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func scanDescriptor(_ descriptor: Int32, maximum: Int, deadline: ContinuousClock.Instant,
                                       consume: (UnsafeRawBufferPointer) -> Void) throws -> Int {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var total = 0
        while true {
            try check(deadline)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress!, min(bytes.count, maximum - total + 1))
            }
            if count == 0 { return total }
            if count < 0 {
                if errno == EINTR { continue }
                throw ArtifactAnalysisFailure.sourceUnavailable
            }
            guard count <= maximum - total else { throw ArtifactAnalysisFailure.inputLimit }
            buffer.withUnsafeBytes { consume(UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            total += count
        }
    }

    private static func unwrap(_ data: Data, deadline: ContinuousClock.Instant, maximum: Int) throws -> Data {
        guard data.starts(with: RecordingContainer.magic) else { return data }
        guard data.count > RecordingContainer.headerLength else { throw ArtifactAnalysisFailure.malformedSource }
        let payload = data.dropFirst(RecordingContainer.headerLength)
        if data[4] == RecordingContainer.gzipFormat {
            let result = try RecordingGzipReader.data(fromCompressedData: payload, maxExpandedBytes: maximum,
                checkProgress: { try check(deadline) })
            try check(deadline)
            return result
        }
        guard data[4] == RecordingContainer.lzfseFormat else { throw ArtifactAnalysisFailure.unsupportedCodec }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 65_536)
        defer { buffer.deallocate() }
        var stream = compression_stream(dst_ptr: buffer, dst_size: 0, src_ptr: UnsafePointer(buffer), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK else {
            throw ArtifactAnalysisFailure.unsupportedCodec
        }
        defer { compression_stream_destroy(&stream) }
        return try payload.withUnsafeBytes { raw in
            stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = payload.count
            var result = Data()
            while true {
                try check(deadline)
                stream.dst_ptr = buffer
                stream.dst_size = 65_536
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = 65_536 - stream.dst_size
                guard produced <= maximum - result.count else { throw ArtifactAnalysisFailure.inputLimit }
                result.append(buffer, count: produced)
                if status == COMPRESSION_STATUS_END {
                    guard stream.src_size == 0 else { throw ArtifactAnalysisFailure.malformedSource }
                    return result
                }
                guard status == COMPRESSION_STATUS_OK, produced > 0 else { throw ArtifactAnalysisFailure.malformedSource }
            }
        }
    }

    private static func readPackage(url: URL, deadline: ContinuousClock.Instant) throws -> ArtifactSnapshot {
        let rootDescriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else { throw ArtifactAnalysisFailure.sourceUnavailable }
        defer { close(rootDescriptor) }
        var rootBefore = stat()
        guard fstat(rootDescriptor, &rootBefore) == 0 else { throw ArtifactAnalysisFailure.sourceUnavailable }
        func inventory() throws -> [String: URL] {
            var failure = false
            guard let enumerator = FileManager.default.enumerator(at: url,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey],
                options: [], errorHandler: { _, _ in failure = true; return false }) else { throw ArtifactAnalysisFailure.sourceUnavailable }
            var files: [String: URL] = [:]
            var visits = 0
            while let item = enumerator.nextObject() as? URL {
                try check(deadline)
                visits += 1
                guard visits <= 512, enumerator.level <= 8 else { throw ArtifactAnalysisFailure.inputLimit }
                let value = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
                guard value.isSymbolicLink != true else { throw ArtifactAnalysisFailure.sourceUnavailable }
                let relative = item.pathComponents.dropFirst(url.pathComponents.count).joined(separator: "/")
                if value.isDirectory == true {
                    guard relative == EffectBundlePackageEngine.assetsDirectoryName else { throw ArtifactAnalysisFailure.malformedSource }
                } else {
                    guard value.isRegularFile == true, files.count < 256 else { throw ArtifactAnalysisFailure.inputLimit }
                    files[relative] = item
                }
            }
            guard !failure else { throw ArtifactAnalysisFailure.sourceUnavailable }
            return files
        }
        let paths = try inventory()
        var members: [String: Data] = [:]
        var total = 0
        for name in paths.keys.sorted() {
            let cap = name == EffectBundlePackageEngine.manifestFileName ? 1_048_576 : maximumFileBytes - total
            let data = try stableRead(url: paths[name]!, maximum: min(cap, maximumFileBytes - total), deadline: deadline,
                rootDescriptor: rootDescriptor, relativePath: name)
            members[name] = data
            total += data.count
        }
        guard let manifestData = members[EffectBundlePackageEngine.manifestFileName] else { throw ArtifactAnalysisFailure.malformedSource }
        var reader = try ArtifactJSONReader(data: manifestData, deadline: deadline)
        _ = try reader.read()
        let manifest = try JSONDecoder().decode(EffectBundleManifest.self, from: manifestData)
        try EffectBundleValidator.validateManifest(manifest)
        let expected = Set(manifest.assets.map(\.packageRelativePath)).union([EffectBundlePackageEngine.manifestFileName])
        guard Set(members.keys) == expected, Set(try inventory().keys) == expected else { throw ArtifactAnalysisFailure.sourceChanged }
        for asset in manifest.assets {
            guard let data = members[asset.packageRelativePath], data.count == asset.byteCount,
                  hash(data) == asset.sha256 else { throw ArtifactAnalysisFailure.malformedSource }
        }
        for name in members.keys.sorted() {
            let reread = try stableRead(url: paths[name]!, maximum: members[name]!.count, deadline: deadline,
                rootDescriptor: rootDescriptor, relativePath: name)
            guard reread == members[name] else { throw ArtifactAnalysisFailure.sourceChanged }
        }
        var rootAfter = stat()
        var rootPath = stat()
        guard fstat(rootDescriptor, &rootAfter) == 0, lstat(url.path, &rootPath) == 0,
              sameFile(rootBefore, rootAfter), sameFile(rootAfter, rootPath),
              Set(try inventory().keys) == expected else { throw ArtifactAnalysisFailure.sourceChanged }
        var hasher = SHA256()
        hasher.update(data: Data("JoesProxy-artifact-package-v1\0".utf8))
        for name in members.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            let bytes = members[name]!
            hasher.update(data: Data("\(name.utf8.count):\(name)\(bytes.count):".utf8))
            hasher.update(data: bytes)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ArtifactSnapshot(kind: .effectBundle, originalBytes: Data(), packageMembers: members,
            sourceSHA256: digest, records: [], schemaVersion: manifest.schemaVersion, warnings: [],
            retainedBytes: total + members.count * 1024, frameCount: nil)
    }
}

extension ArtifactJSONValue {
    func encoded(maximum: Int, deadline: ContinuousClock.Instant) throws -> Data {
        var result = Data()
        func append(_ data: Data) throws {
            try ArtifactSnapshotReader.check(deadline)
            guard data.count <= maximum - result.count else { throw ArtifactAnalysisFailure.inputLimit }
            result.append(data)
        }
        func emit(_ value: ArtifactJSONValue) throws {
            switch value {
            case .null: try append(Data("null".utf8))
            case .boolean(let flag): try append(Data((flag ? "true" : "false").utf8))
            case .number(let text): try append(Data(text.utf8))
            case .string(let text): try append(JSONEncoder().encode(text))
            case .array(let entries):
                try append(Data("[".utf8))
                for (index, entry) in entries.enumerated() {
                    if index > 0 { try append(Data(",".utf8)) }
                    try emit(entry)
                }
                try append(Data("]".utf8))
            case .object(let entries):
                try append(Data("{".utf8))
                for (index, entry) in entries.enumerated() {
                    if index > 0 { try append(Data(",".utf8)) }
                    try append(JSONEncoder().encode(entry.0))
                    try append(Data(":".utf8))
                    try emit(entry.1)
                }
                try append(Data("}".utf8))
            }
        }
        try emit(self)
        return result
    }
}
