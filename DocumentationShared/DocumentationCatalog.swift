import Foundation
import CryptoKit
import CoreFoundation

/// Immutable bundled documentation. No credentials, capture state, or network access.
struct DocumentationCatalog: Sendable {
    struct Index: Codable, Sendable {
        let schemaVersion: Int
        let revision: String
        let topics: [Topic]
    }
    struct Topic: Codable, Sendable, Identifiable {
        let id: String
        let title: String
        let summary: String
        let category: String
        let keywords: [String]
        let relatedTopics: [String]
        let file: String
        let hubSectionID: String?
        let capabilityReferences: [String]?
    }
    struct Section: Codable, Sendable {
        let id: String
        let title: String
        let markdown: String
    }
    struct Entry: Codable, Sendable {
        let topic: Topic
        let sections: [Section]
        let safetyContext: [Section]
        let matchedSectionID: String?
        let excerpt: String?
    }
    struct Page: Codable, Sendable {
        let schemaVersion: Int
        let source: String
        let appVersion: String
        let catalogRevision: String
        let catalogDigest: String
        let entries: [Entry]
        let nextCursor: String?
        let incomplete: Bool
        let notice: String
    }
    struct Query: Codable, Sendable {
        var operation: String
        var query: String? = nil
        var topic: String? = nil
        var section: String? = nil
        var category: String? = nil
        var cursor: String? = nil
        var limit: Int = 10
        var maxResponseBytes: Int = 8192

        init(operation: String, query: String? = nil, topic: String? = nil, section: String? = nil,
             category: String? = nil, cursor: String? = nil, limit: Int = 10, maxResponseBytes: Int = 8192) {
            self.operation = operation; self.query = query; self.topic = topic; self.section = section
            self.category = category; self.cursor = cursor; self.limit = limit; self.maxResponseBytes = maxResponseBytes
        }

        init(operation: String, arguments: [String: Any]) throws {
            let allowed: Set<String> = ["query", "topic", "section", "category", "cursor", "limit", "maxResponseBytes"]
            guard Set(arguments.keys).isSubset(of: allowed) else {
                throw Failure(reason: "invalidArguments", recovery: "Use the documented documentation query fields.")
            }
            for key in ["query", "topic", "section", "category", "cursor"] {
                if let value = arguments[key], !(value is String) {
                    throw Failure(reason: "invalidArguments", recovery: "\(key) must be a string.")
                }
            }
            func integer(_ name: String, fallback: Int) throws -> Int {
                guard let value = arguments[name] else { return fallback }
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                      number.doubleValue >= 0, number.doubleValue <= 32768 else {
                    throw Failure(reason: "invalidArguments", recovery: "\(name) must be a bounded integer.")
                }
                return number.intValue
            }
            self.init(operation: operation, query: arguments["query"] as? String, topic: arguments["topic"] as? String,
                section: arguments["section"] as? String, category: arguments["category"] as? String,
                cursor: arguments["cursor"] as? String, limit: try integer("limit", fallback: 10),
                maxResponseBytes: try integer("maxResponseBytes", fallback: 8192))
        }
    }
    struct Failure: LocalizedError, Sendable {
        let reason: String
        let recovery: String
        var errorDescription: String? { "\(reason): \(recovery)" }
    }
    private struct Cursor: Codable {
        let digest: String
        let queryDigest: String
        let offset: Int
    }
    let index: Index
    let digest: String
    private let sections: [String: [Section]]

    init(directory: URL) throws {
        let indexURL = directory.appendingPathComponent("documentation-index.json")
        guard let bytes = try? Data(contentsOf: indexURL), bytes.count <= 1_048_576 else {
            throw Failure(reason: "catalogUnavailable", recovery: "Use the documentation packaged with this JoesProxy installation.")
        }
        let decoded: Index
        do { decoded = try JSONDecoder().decode(Index.self, from: bytes) }
        catch { throw Failure(reason: "invalidCatalog", recovery: "The installed documentation index is malformed.") }
        guard decoded.schemaVersion == 1 else {
            throw Failure(reason: "unsupportedCatalogVersion", recovery: "Use matching CLI and app documentation versions.")
        }
        guard !decoded.revision.isEmpty, !decoded.topics.isEmpty, decoded.topics.count <= 512,
              Set(decoded.topics.map(\.id)).count == decoded.topics.count else {
            throw Failure(reason: "invalidCatalog", recovery: "Topic IDs must be unique and the catalog must be nonempty.")
        }
        let ids = Set(decoded.topics.map(\.id))
        var loaded: [String: [Section]] = [:]
        var hasher = SHA256()
        hasher.update(data: bytes)
        for topic in decoded.topics {
            guard Self.validID(topic.id), topic.file == "doc-\(topic.id).md",
                  topic.relatedTopics.allSatisfy(ids.contains) else {
                throw Failure(reason: "invalidCatalog", recovery: "Correct topic filenames, IDs and related-topic references.")
            }
            let url = directory.appendingPathComponent(topic.file)
            guard url.resolvingSymlinksInPath().deletingLastPathComponent().path == directory.resolvingSymlinksInPath().path,
                  let data = try? Data(contentsOf: url), data.count <= 262_144,
                  let text = String(data: data, encoding: .utf8) else {
                throw Failure(reason: "missingTopic", recovery: "Bundled topic \(topic.id) is missing, oversized, or unreadable. Repair the matching app installation.")
            }
            let parsed = try Self.parse(text)
            guard !parsed.isEmpty else { throw Failure(reason: "invalidCatalog", recovery: "Every topic needs named Markdown sections.") }
            loaded[topic.id] = parsed
            hasher.update(data: data)
        }
        index = decoded
        sections = loaded
        digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func bundledDirectory(executableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0]),
                                 resourceURL: URL? = Bundle.main.resourceURL) throws -> URL {
        let candidates = [resourceURL,
            executableURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")]
        for base in candidates.compactMap({ $0 }) {
            for directory in [base.appendingPathComponent("Documentation"), base] {
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent("documentation-index.json").path) {
                    return directory
                }
            }
        }
        throw Failure(reason: "catalogUnavailable", recovery: "Run the CLI bundled in JoesProxy.app with its Resources directory intact.")
    }

    func topicSections(_ id: String) -> [Section] { sections[id] ?? [] }

    func execute(_ request: Query, source: String, appVersion: String) throws -> Page {
        guard ["list", "search", "read"].contains(request.operation),
              (1...20).contains(request.limit), (2048...32768).contains(request.maxResponseBytes),
              (request.query?.utf8.count ?? 0) <= 512, (request.cursor?.utf8.count ?? 0) <= 2048,
              [request.topic, request.section, request.category].allSatisfy({ ($0?.utf8.count ?? 0) <= 96 }) else {
            throw Failure(reason: "invalidArguments", recovery: "Use list/search/read, limit 1–20, maxResponseBytes 2048–32768 and a query up to 512 UTF-8 bytes.")
        }
        let hasIrrelevantArguments = request.operation == "read"
            ? request.query != nil || request.category != nil
            : request.topic != nil || request.section != nil || (request.operation == "list" && request.query != nil)
        guard !hasIrrelevantArguments else {
            throw Failure(reason: "invalidArguments", recovery: "Use list with optional category; search with query and optional category; read with topic and optional section. Example: docs read --topic workflow-image --section prepare.")
        }
        let queryText = Self.normalize(request.query ?? "")
        if request.operation == "search", queryText.isEmpty {
            throw Failure(reason: "invalidArguments", recovery: "Supply a nonempty search query, or use documentation_list.")
        }
        if let category = request.category, !index.topics.contains(where: { $0.category == category }) {
            throw Failure(reason: "unknownCategory", recovery: "List topics without a category to discover valid categories.")
        }
        var identity = request
        identity.cursor = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let queryDigest = SHA256.hash(data: try encoder.encode(identity)).map { String(format: "%02x", $0) }.joined()
        var offset = 0
        if let token = request.cursor {
            guard let bytes = Data(base64Encoded: token), let cursor = try? JSONDecoder().decode(Cursor.self, from: bytes),
                  cursor.digest == digest, cursor.queryDigest == queryDigest, cursor.offset >= 0 else {
                throw Failure(reason: "staleCursor", recovery: "Repeat the original documentation query without a cursor.")
            }
            offset = cursor.offset
        }
        let candidates: [Entry]
        if request.operation == "read" {
            guard let topic = index.topics.first(where: { $0.id == request.topic }) else {
                throw Failure(reason: "unknownTopic", recovery: "Use documentation_search or documentation_list to select a stable topic ID.")
            }
            let selected = topicSections(topic.id).filter { request.section == nil || $0.id == request.section }
            guard !selected.isEmpty else { throw Failure(reason: "unknownSection", recovery: "Read the topic without a section to discover section IDs.") }
            let safety = topicSections(topic.id).filter { ["safety", "context"].contains($0.id) }
            candidates = selected.map { selectedSection in
                Entry(topic: topic, sections: [selectedSection],
                    safetyContext: safety.filter { $0.id != selectedSection.id }, matchedSectionID: nil, excerpt: nil)
            }
        } else {
            var ranked: [(topic: Topic, score: Int)] = []
            for topic in index.topics where request.category == nil || topic.category == request.category {
                let title = Self.normalize(topic.title)
                let keywords = Self.normalize(topic.keywords.joined(separator: " "))
                let body = Self.normalize(topicSections(topic.id).map { $0.title + " " + $0.markdown }.joined(separator: " "))
                let score: Int
                if topic.id == request.query { score = 100 }
                else if title == queryText { score = 90 }
                else if title.contains(queryText) { score = 70 }
                else if keywords.contains(queryText) { score = 50 }
                else if body.contains(queryText) { score = 20 }
                else { score = 0 }
                if request.operation == "list" || score > 0 { ranked.append((topic, score)) }
            }
            ranked.sort {
                if $0.score != $1.score { return $0.score > $1.score }
                if ($0.topic.category == "help") != ($1.topic.category == "help") {
                    return $0.topic.category == "help"
                }
                if ($0.topic.category == "glossary") != ($1.topic.category == "glossary") {
                    return $0.topic.category != "glossary"
                }
                return $0.topic.id < $1.topic.id
            }
            candidates = ranked.map { rankedTopic in
                let match = request.operation == "search" ? topicSections(rankedTopic.topic.id).first {
                    Self.normalize($0.title + " " + $0.markdown).contains(queryText)
                } : nil
                return Entry(topic: rankedTopic.topic, sections: [], safetyContext: [], matchedSectionID: match?.id,
                    excerpt: request.operation == "search" ? String((match?.markdown ?? rankedTopic.topic.summary).prefix(240)) : nil)
            }
        }
        guard offset <= candidates.count else { throw Failure(reason: "staleCursor", recovery: "Restart the query without a cursor.") }
        func page(_ entries: [Entry], next: Int) throws -> Page {
            let more = next < candidates.count
            let token = more ? try encoder.encode(Cursor(digest: digest, queryDigest: queryDigest, offset: next)).base64EncodedString() : nil
            return Page(schemaVersion: 1, source: source, appVersion: appVersion, catalogRevision: index.revision,
                catalogDigest: digest, entries: entries, nextCursor: token, incomplete: more,
                notice: "Documentation is not runtime readiness, permission, delivery or target-outcome evidence. Check current capabilities and obtain required authorization before acting. Follow nextCursor for remaining sections; no missing request establishes caching.")
        }
        var entries: [Entry] = []
        for entry in candidates.dropFirst(offset).prefix(request.limit) {
            let trial = entries + [entry]
            if try encoder.encode(page(trial, next: offset + trial.count)).count > request.maxResponseBytes { break }
            entries = trial
        }
        if entries.isEmpty, offset < candidates.count {
            throw Failure(reason: "responseBudgetTooSmall", recovery: "Increase maxResponseBytes up to 32768; sections are never silently truncated.")
        }
        return try page(entries, next: offset + entries.count)
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 96 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
    private static func parse(_ text: String) throws -> [Section] {
        var result: [Section] = []
        var title = "", id = "", lines: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("## "), let marker = line.range(of: " {#"), line.hasSuffix("}") {
                if !id.isEmpty { result.append(Section(id: id, title: title, markdown: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))) }
                title = String(line[line.index(line.startIndex, offsetBy: 3)..<marker.lowerBound])
                id = String(line[marker.upperBound..<line.index(before: line.endIndex)])
                guard validID(id) else { throw Failure(reason: "invalidCatalog", recovery: "Use stable ASCII section IDs.") }
                lines = []
            } else if !id.isEmpty { lines.append(line) }
        }
        if !id.isEmpty { result.append(Section(id: id, title: title, markdown: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))) }
        guard Set(result.map(\.id)).count == result.count else { throw Failure(reason: "invalidCatalog", recovery: "Section IDs must be unique within a topic.") }
        return result
    }
}

/// Cache once; actor isolation keeps disk loading and search outside UI/network executors.
actor DocumentationService {
    static let shared = DocumentationService()
    private var catalog: DocumentationCatalog?
    func snapshot() throws -> DocumentationCatalog {
        if catalog == nil { catalog = try DocumentationCatalog(directory: DocumentationCatalog.bundledDirectory()) }
        guard let catalog else { throw DocumentationCatalog.Failure(reason: "catalogUnavailable", recovery: "Reopen a complete installation.") }
        return catalog
    }
    func query(_ query: DocumentationCatalog.Query, source: String, appVersion: String) throws -> DocumentationCatalog.Page {
        let catalog = try snapshot()
        return try catalog.execute(query, source: source, appVersion: appVersion)
    }
}
