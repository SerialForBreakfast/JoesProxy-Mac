import Foundation
import UniformTypeIdentifiers

/// Limits for locally served Map Local directory trees (AS).
///
/// Reuses the same size budget as fixture static files so agents cannot accidentally force
/// multi‑hundred‑megabyte responses through the capture path.
enum LocalDirectoryLimits {
    /// Maximum bytes read for one served file (mirrors `HLSFixtureLimits.maxServedFileBytes`).
    static let maxServedFileBytes = 16 * 1024 * 1024
}

/// One HTTP response computed from a user-chosen directory — decoupled from NIO so unit tests
/// exercise path safety without a live channel.
struct LocalDirectoryResponse: Equatable, Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
}

/**
 Serves static files under a security-scoped directory root for Map Local `.localDirectory` rules.

 Concurrency: pure/sync; safe to call from the connection-handler async path. Reads disk per
 request (manual browser reload picks up file edits without recreating the rule). Reuses the
 traversal discipline proven in `HLSFixtureServer.isSafeRelativePath` — do not weaken it.
 */
struct LocalDirectoryServer: Sendable {
    let rootDirectory: URL
    /// Optional relative path inside `rootDirectory` served when the requested file is missing
    /// (opt-in failure-page mocking). Must itself pass the traversal guard.
    let notFoundRelativePath: String?

    /**
     Computes the response for one request path under `rootDirectory`.

     - Parameters:
       - rawPath: Absolute-within-prefix or relative path (query stripped). Empty / trailing slash
         resolves to `index.html` when present.
       - method: Only `GET`/`HEAD` are supported.
       - rangeHeader: Optional single-range `Range: bytes=` header.
     */
    func response(forPath rawPath: String, method: String, rangeHeader: String?) -> LocalDirectoryResponse {
        guard method == "GET" || method == "HEAD" else {
            return LocalDirectoryResponse(status: 405, headers: ["Allow": "GET, HEAD"], body: Data())
        }

        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        var relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if relative.isEmpty || relative.hasSuffix("/") {
            let indexCandidate = relative.isEmpty ? "index.html" : relative + "index.html"
            if isSafeRelativePath(indexCandidate), fileExistsAsRegularFile(relative: indexCandidate) {
                relative = indexCandidate
            } else if relative.hasSuffix("/") {
                relative = String(relative.dropLast())
            }
        }

        if !relative.isEmpty, isSafeRelativePath(relative), fileExistsAsRegularFile(relative: relative) {
            return serveFile(relative: relative, method: method, rangeHeader: rangeHeader)
        }

        if let notFoundRelativePath,
           !notFoundRelativePath.isEmpty,
           isSafeRelativePath(notFoundRelativePath),
           fileExistsAsRegularFile(relative: notFoundRelativePath) {
            return serveFile(relative: notFoundRelativePath, method: method, rangeHeader: nil, statusOverride: 404)
        }

        return LocalDirectoryResponse(status: 404, headers: [:], body: Data())
    }

    /// Whether `rawPath` resolves to an existing local file — the same resolution `response(forPath:
    /// method:rangeHeader:)` uses for its "hit" branch (including the `index.html` fallback), exposed
    /// separately so a caller can decide overlay/fail-open behavior for a `.localDirectory` rule's
    /// `missingFilePolicy` *before* this type ever computes a response (a miss under
    /// `.overlayFailOpen` should reach the real upstream server, not this type's own 404 handling).
    func hasLocalFile(forPath rawPath: String) -> Bool {
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        var relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if relative.isEmpty || relative.hasSuffix("/") {
            let indexCandidate = relative.isEmpty ? "index.html" : relative + "index.html"
            if isSafeRelativePath(indexCandidate), fileExistsAsRegularFile(relative: indexCandidate) {
                relative = indexCandidate
            } else if relative.hasSuffix("/") {
                relative = String(relative.dropLast())
            }
        }
        return !relative.isEmpty && isSafeRelativePath(relative) && fileExistsAsRegularFile(relative: relative)
    }

    /// Rejects any path that would escape `rootDirectory` — same discipline as
    /// `HLSFixtureServer` (`..`, standardized prefix, canonical symlink check).
    func isSafeRelativePath(_ relative: String) -> Bool {
        guard !relative.contains("..") else { return false }
        let candidate = rootDirectory.appendingPathComponent(relative).standardizedFileURL
        let base = rootDirectory.standardizedFileURL
        guard candidate.path.hasPrefix(base.path) else { return false }
        if let resolvedCandidate = try? URL(fileURLWithPath: candidate.path).resourceValues(forKeys: [.canonicalPathKey]).canonicalPath,
           let resolvedBase = try? URL(fileURLWithPath: base.path).resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            return resolvedCandidate.hasPrefix(resolvedBase)
        }
        return true
    }

    private func fileExistsAsRegularFile(relative: String) -> Bool {
        let fileURL = rootDirectory.appendingPathComponent(relative)
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]) else {
            return false
        }
        return values.isRegularFile == true
    }

    private func serveFile(
        relative: String,
        method: String,
        rangeHeader: String?,
        statusOverride: Int? = nil
    ) -> LocalDirectoryResponse {
        let fileURL = rootDirectory.appendingPathComponent(relative)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? Int,
              fileSize <= LocalDirectoryLimits.maxServedFileBytes else {
            return LocalDirectoryResponse(status: 404, headers: [:], body: Data())
        }

        let contentType = Self.contentType(forPathExtension: fileURL.pathExtension)
        if statusOverride == nil, let rangeHeader, let range = Self.parseSingleByteRange(rangeHeader, fileSize: fileSize) {
            guard let full = try? Data(contentsOf: fileURL), range.upperBound <= full.count else {
                return LocalDirectoryResponse(status: 500, headers: [:], body: Data())
            }
            let slice = full[range]
            let body = method == "HEAD" ? Data() : Data(slice)
            return LocalDirectoryResponse(
                status: 206,
                headers: [
                    "Content-Type": contentType,
                    "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(fileSize)",
                    "Content-Length": "\(range.count)",
                    "Accept-Ranges": "bytes"
                ],
                body: body
            )
        }

        let body: Data
        if method == "HEAD" {
            body = Data()
        } else {
            guard let loaded = try? Data(contentsOf: fileURL) else {
                return LocalDirectoryResponse(status: 500, headers: [:], body: Data())
            }
            body = loaded
        }
        return LocalDirectoryResponse(
            status: statusOverride ?? 200,
            headers: [
                "Content-Type": contentType,
                "Content-Length": "\(fileSize)",
                "Accept-Ranges": "bytes"
            ],
            body: body
        )
    }

    /// Not `private`: reused by single-file Map Local (`ResponseOverrideStore`/`MCPMutationService`)
    /// so extension→MIME-type inference has exactly one implementation, not a third duplicate.
    static func contentType(forPathExtension ext: String) -> String {
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }

    /// Parses a single-range `Range: bytes=start-end` header. Multi-range and suffix-only forms
    /// fall through to a full 200 (same policy as `HLSFixtureServer`).
    private static func parseSingleByteRange(_ header: String, fileSize: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0]), start >= 0, start < fileSize else { return nil }
        let end: Int
        if parts[1].isEmpty {
            end = fileSize - 1
        } else if let parsedEnd = Int(parts[1]) {
            end = min(parsedEnd, fileSize - 1)
        } else {
            return nil
        }
        guard end >= start else { return nil }
        return start..<(end + 1)
    }
}
