import Foundation
import XCTest
@testable import JoesProxy

final class TimedMetadataCandidateResolverTests: XCTestCase {
    func testSelectedItemContextDoesNotExpandPlaylistIntoSegments() {
        let manifestSession = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/media.m3u8",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "application/vnd.apple.mpegurl")],
            bodyData: Data("""
            #EXTM3U
            #EXTINF:6.0,
            https://video.example.com/seg-1.ts
            """.utf8)
        )
        let segmentSession = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/seg-1.ts",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "video/mp2t")],
            bodyData: Data(repeating: 0x47, count: 188)
        )

        let context = TimedMetadataCandidateResolver.selectedItemContext(
            for: manifestSession,
            parsedHLSManifestSessions: parsedHLSManifestSessions(from: [manifestSession]),
            sessions: [manifestSession, segmentSession]
        )

        XCTAssertFalse(context.isAnalysisAvailable)
        XCTAssertTrue(context.candidates.isEmpty)
    }

    func testSelectedItemContextContainsOnlySelectedSegment() throws {
        let selected = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/selected.ts",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "video/mp2t")],
            bodyData: Data(repeating: 0x47, count: 188)
        )
        let other = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/other.ts",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "video/mp2t")],
            bodyData: Data(repeating: 0x47, count: 188)
        )

        let context = TimedMetadataCandidateResolver.selectedItemContext(
            for: selected,
            parsedHLSManifestSessions: [],
            sessions: [selected, other]
        )

        XCTAssertEqual(context.candidates.count, 1)
        XCTAssertEqual(try XCTUnwrap(context.candidates.first).sessionID, selected.id)
    }

    func testMediaPlaylistResolvesCapturedSegmentCandidates() {
        let manifestSession = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/media.m3u8",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "application/vnd.apple.mpegurl")],
            bodyData: Data("""
            #EXTM3U
            #EXT-X-TARGETDURATION:6
            #EXTINF:6.0,
            https://video.example.com/seg-1.ts
            #EXTINF:6.0,
            https://video.example.com/seg-2.ts
            """.utf8)
        )

        let segmentOne = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/seg-1.ts",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "video/mp2t")],
            bodyData: Data(repeating: 0x47, count: 188)
        )

        let sessions = [manifestSession, segmentOne]
        let parsedManifests = parsedHLSManifestSessions(from: sessions)
        let context = TimedMetadataCandidateResolver.context(
            for: manifestSession,
            parsedHLSManifestSessions: parsedManifests,
            sessions: sessions
        )

        XCTAssertEqual(context.trigger, .hlsMediaPlaylist)
        XCTAssertTrue(context.isAnalysisAvailable)
        XCTAssertEqual(context.referencedSegmentCount, 2)
        XCTAssertEqual(context.capturedSegmentCount, 1)
        XCTAssertEqual(context.candidates.count, 1)
        XCTAssertEqual(context.candidates.first?.sessionID, segmentOne.id)
        XCTAssertEqual(context.candidates.first?.segmentSequence, 0)
    }

    func testMasterPlaylistUsesCapturedChildMediaPlaylists() {
        let masterSession = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/master.m3u8",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "application/vnd.apple.mpegurl")],
            bodyData: Data("""
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=1000000
            https://video.example.com/1080.m3u8
            """.utf8)
        )

        let mediaPlaylistSession = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/1080.m3u8",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "application/vnd.apple.mpegurl")],
            bodyData: Data("""
            #EXTM3U
            #EXTINF:6.0,
            https://video.example.com/seg-1.ts
            """.utf8)
        )

        let segmentSession = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/seg-1.ts",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "video/mp2t")],
            bodyData: Data(repeating: 0x47, count: 188)
        )

        let sessions = [masterSession, mediaPlaylistSession, segmentSession]
        let parsedManifests = parsedHLSManifestSessions(from: sessions)
        let context = TimedMetadataCandidateResolver.context(
            for: masterSession,
            parsedHLSManifestSessions: parsedManifests,
            sessions: sessions
        )

        XCTAssertEqual(context.trigger, .hlsMasterPlaylist)
        XCTAssertTrue(context.isAnalysisAvailable)
        XCTAssertEqual(context.referencedSegmentCount, 1)
        XCTAssertEqual(context.capturedSegmentCount, 1)
        XCTAssertEqual(context.candidates.first?.sessionID, segmentSession.id)
    }

    func testCapturedSegmentUsesManifestTimingWhenCorrelated() {
        let manifestSession = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/media.m3u8",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "application/vnd.apple.mpegurl")],
            bodyData: Data("""
            #EXTM3U
            #EXTINF:6.0,
            https://video.example.com/seg-1.ts
            #EXTINF:6.0,
            https://video.example.com/seg-2.ts
            """.utf8)
        )

        let segmentSession = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/seg-2.ts",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "video/mp2t")],
            bodyData: Data(repeating: 0x47, count: 188)
        )

        let sessions = [manifestSession, segmentSession]
        let parsedManifests = parsedHLSManifestSessions(from: sessions)
        let context = TimedMetadataCandidateResolver.context(
            for: segmentSession,
            parsedHLSManifestSessions: parsedManifests,
            sessions: sessions
        )

        XCTAssertEqual(context.trigger, .capturedMediaSegment)
        XCTAssertTrue(context.isAnalysisAvailable)
        XCTAssertEqual(context.candidates.first?.segmentSequence, 1)
        XCTAssertEqual(try XCTUnwrap(context.candidates.first?.relativePlaybackTime), 6.0, accuracy: 0.001)
    }

    func testAnalyzeReturnsParserResultsForCapturedSegment() {
        let assetID = UUID()
        let id3Tag = makeID3Tag(frames: [makeTextFrame(identifier: "TIT2", text: "Chapter 1")])
        let segmentSession = makeSession(
            id: assetID,
            host: "video.example.com",
            path: "/seg-1.ts",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "video/mp2t")],
            bodyData: makeTransportStreamData(payload: id3Tag)
        )

        let context = TimedMetadataCandidateResolver.context(
            for: segmentSession,
            parsedHLSManifestSessions: [],
            sessions: [segmentSession]
        )
        let results = TimedMetadataCandidateResolver.analyze(
            candidates: context.candidates,
            sessions: [segmentSession]
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].assetID, assetID)
        XCTAssertEqual(results[0].markers.first?.payloadSummary, "TIT2: Chapter 1")

        let unrelated = makeSession(id: UUID(), host: "video.example.com", path: "/unrelated.ts",
            responseHeaders: [], bodyData: Data(repeating: 0, count: 1_024))
        let retained = TimedMetadataCandidateResolver.capturedSessions(
            for: context.candidates, in: [unrelated, segmentSession])
        XCTAssertEqual(retained.map(\.id), [assetID])
        XCTAssertTrue(TimedMetadataCandidateResolver.analyze(
            candidates: context.candidates, sessions: retained, shouldCancel: { true }).isEmpty)
    }

    func testMasterPlaylistWithoutCapturedChildPlaylistsIsUnavailable() {
        let masterSession = makeSession(
            id: UUID(),
            host: "video.example.com",
            path: "/master.m3u8",
            responseHeaders: [HTTPHeaderField(name: "Content-Type", value: "application/vnd.apple.mpegurl")],
            bodyData: Data("""
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=1000000
            https://video.example.com/1080.m3u8
            """.utf8)
        )

        let context = TimedMetadataCandidateResolver.context(
            for: masterSession,
            parsedHLSManifestSessions: parsedHLSManifestSessions(from: [masterSession]),
            sessions: [masterSession]
        )

        XCTAssertEqual(context.trigger, .hlsMasterPlaylist)
        XCTAssertFalse(context.isAnalysisAvailable)
        XCTAssertTrue(context.notes.contains { $0.contains("master playlist") })
    }

    private func parsedHLSManifestSessions(from sessions: [SessionRecord]) -> [ParsedHLSManifestSession] {
        sessions.compactMap { candidate in
            guard MediaDetector.mediaType(for: candidate) == .hls,
                  let response = candidate.response,
                  let bodyData = MediaDetector.decodedResponseBody(for: response),
                  let manifestText = String(data: bodyData, encoding: .utf8) else {
                return nil
            }

            return ParsedHLSManifestSession(
                sessionID: candidate.id,
                host: candidate.request.host,
                path: candidate.request.path,
                manifest: HLSParser.parse(
                    manifestText,
                    baseURL: MediaDetector.absoluteURL(for: candidate.request)
                )
            )
        }
    }

    private func makeSession(
        id: UUID,
        host: String,
        path: String,
        responseHeaders: [HTTPHeaderField],
        bodyData: Data? = nil
    ) -> SessionRecord {
        SessionRecord(
            id: id,
            request: CapturedRequest(
                method: "GET",
                scheme: .https,
                inspectionKind: .interceptedTLS,
                host: host,
                port: 443,
                path: path,
                headers: [],
                bodyData: nil,
                bodySize: nil
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: responseHeaders,
                bodyData: bodyData,
                bodySize: bodyData?.count,
                source: .upstream
            ),
            state: .completed,
            timing: SessionTiming(startedAt: Date(), completedAt: Date())
        )
    }

    private func makeID3Tag(frames: [Data]) -> Data {
        let frameData = frames.reduce(into: Data()) { $0.append($1) }
        var data = Data()
        data.append(contentsOf: [0x49, 0x44, 0x33])
        data.append(contentsOf: [0x03, 0x00, 0x00])
        data.append(synchsafeBytes(frameData.count))
        data.append(frameData)
        return data
    }

    private func makeTextFrame(identifier: String, text: String) -> Data {
        var payload = Data([0x03])
        payload.append(text.data(using: .utf8)!)
        return makeFrame(identifier: identifier, payload: payload)
    }

    private func makeFrame(identifier: String, payload: Data) -> Data {
        var data = Data()
        data.append(identifier.data(using: .ascii)!)
        data.append(uint32Bytes(UInt32(payload.count)))
        data.append(contentsOf: [0x00, 0x00])
        data.append(payload)
        return data
    }

    private func makeTransportStreamData(payload: Data) -> Data {
        var data = Data()
        data.append(makePacket(pid: 0x0101, payload: payload))
        return data
    }

    private func makePacket(pid: Int, payload: Data) -> Data {
        var packet = Data(repeating: 0xFF, count: 188)
        packet[0] = 0x47
        packet[1] = UInt8((pid >> 8) & 0x1F)
        packet[2] = UInt8(pid & 0xFF)
        packet[3] = 0x10
        let copyCount = min(payload.count, 188 - 4)
        packet.replaceSubrange(4..<(4 + copyCount), with: payload.prefix(copyCount))
        return packet
    }

    private func uint32Bytes(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    private func synchsafeBytes(_ value: Int) -> Data {
        Data([
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F)
        ])
    }
}
