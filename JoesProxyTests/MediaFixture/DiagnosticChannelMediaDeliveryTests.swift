import Foundation
import XCTest
@testable import JoesProxy

/// Real isolated loopback transport, not target-player or proxy downstream-delivery acceptance.
final class DiagnosticChannelMediaDeliveryTests: XCTestCase {
    private enum FixtureRequestError: Error {
        case escapedLoopbackOrigin
    }
    private var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/HLS/multilingual-text-vod-v1")
    }

    func testLiveOriginDeliversSharedMediaAndEveryCaptionTrackWithRanges() async throws {
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        let now = anchor.addingTimeInterval(28)
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .liveLoop
        configuration.timeShiftMode = .warmDVR
        let server = try await HLSFixtureServer.make(profileDirectory: directory, startedAt: anchor,
            playbackConfiguration: configuration, clock: { now })
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.connectionProxyDictionary = [:]
        sessionConfiguration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        do {
            try await server.start()
            let base = try XCTUnwrap(server.baseURL)
            let master = try await fetch("master.m3u8", base: base, session: session)
            XCTAssertEqual(master.status, 200)
            XCTAssertEqual(master.contentType, "application/vnd.apple.mpegurl")
            XCTAssertEqual(master.bytes, server.response(forPath: "master.m3u8", method: "GET", rangeHeader: nil).body)
            let rejectedMethod = try await fetch("master.m3u8", base: base, session: session, method: "POST")
            XCTAssertEqual(rejectedMethod.status, 405)
            let spec = try XCTUnwrap(HLSFixtureProfileDescriptor.load(from: directory).textFixture)
            let paths = ["video-720/stream.m3u8", "audio-en/stream.m3u8"] + spec.tracks.map(\.playlistPath)
            for path in paths {
                let playlist = try await fetch(path, base: base, session: session)
                XCTAssertEqual(playlist.status, 200)
                let parsed = HLSStaticPlaylistParser.parse(String(decoding: playlist.bytes, as: UTF8.self))
                let segment = try XCTUnwrap(parsed.segments.last)
                let playlistURL = base.appendingPathComponent(path)
                let segmentURL = try XCTUnwrap(URL(string: segment.uri, relativeTo: playlistURL)?.absoluteURL)
                XCTAssertEqual(segmentURL.host, base.host)
                XCTAssertEqual(segmentURL.port, base.port)
                let relative = segmentURL.path + (segmentURL.query.map { "?" + $0 } ?? "")
                let expected = server.response(forPath: relative, method: "GET", rangeHeader: nil)
                let delivered = try await fetch(relative, base: base, session: session)
                XCTAssertEqual(delivered.status, 200)
                XCTAssertFalse(delivered.bytes.isEmpty)
                XCTAssertEqual(delivered.bytes, expected.body)
                XCTAssertEqual(delivered.contentLength, delivered.bytes.count)
                let head = try await fetch(relative, base: base, session: session, method: "HEAD")
                XCTAssertEqual(head.status, 200)
                XCTAssertTrue(head.bytes.isEmpty)
                XCTAssertEqual(head.contentLength, delivered.bytes.count)
                let ranged = try await fetch(relative, base: base, session: session, range: "bytes=0-5")
                XCTAssertEqual(ranged.status, 206)
                XCTAssertEqual(ranged.bytes, Data(delivered.bytes.prefix(6)))
                XCTAssertEqual(ranged.contentRange, "bytes 0-5/\(delivered.bytes.count)")
                let unpublished = try await fetch(segmentURL.path, base: base, session: session)
                XCTAssertEqual(unpublished.status, 404,
                    "Live media must not be available without its publication sequence")
                if path.hasPrefix("text/") {
                    XCTAssertNotNil(expected.textTrack)
                    XCTAssertTrue(String(decoding: delivered.bytes, as: UTF8.self).hasPrefix("WEBVTT"))
                    XCTAssertEqual(ranged.bytes, Data("WEBVTT".utf8))
                }
            }
            let missing = try await fetch("text/missing/stream.m3u8", base: base, session: session)
            XCTAssertEqual(missing.status, 404)
            try server.completeLive()
            let completed = try await fetch("text/en/stream.m3u8", base: base, session: session)
            XCTAssertTrue(String(decoding: completed.bytes, as: UTF8.self).contains("#EXT-X-ENDLIST"))
            await server.stop()
            XCTAssertFalse(server.isRunning)
            XCTAssertEqual(server.response(forPath: "master.m3u8", method: "GET", rangeHeader: nil).status, 410)
        } catch {
            await server.stop()
            throw error
        }
    }

    private func fetch(_ path: String, base: URL, session: URLSession,
                       range: String? = nil, method: String = "GET") async throws
        -> (bytes: Data, status: Int, contentType: String?, contentLength: Int?, contentRange: String?) {
        let url = try XCTUnwrap(URL(string: path, relativeTo: base)?.absoluteURL)
        guard base.scheme == "http", ["127.0.0.1", "::1", "[::1]"].contains(base.host ?? ""),
              url.scheme == base.scheme, url.host == base.host, url.port == base.port,
              url.user == nil, url.password == nil else {
            throw FixtureRequestError.escapedLoopbackOrigin
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(range, forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (bytes, http.statusCode, http.value(forHTTPHeaderField: "Content-Type"),
                http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
                http.value(forHTTPHeaderField: "Content-Range"))
    }
}
