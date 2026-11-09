import XCTest
@testable import JoesProxy

final class SessionPerformanceTests: XCTestCase {
    private let recordingExportService = JSONSessionExportService()
    private let recordingImportService = JSONSessionRecordingImportService()

    func testSessionFilterEnginePerformanceOnLargeSessionSet() {
        let engine = SessionFilterEngine()
        let sessions = makeSyntheticSessions(count: 2_000)
        let criteria = SessionFilterCriteria(
            hostContains: "api",
            method: "GET",
            scheme: .https,
            inspectionMatch: .notTunneled,
            statusMatch: .range(200...299)
        )

        measure {
            _ = engine.filter(
                sessions,
                criteria: criteria,
                searchText: "users"
            )
        }
    }

    func testSessionExplorerBuilderPerformanceOnLargeSummarySet() {
        let sessions = makeSyntheticSessions(count: 2_000)
        let summaries = sessions.map(SessionSummary.init(record:))

        measure {
            _ = SessionExplorerBuilder.build(
                from: summaries,
                grouping: .byEndpoint,
                hostGrouping: .domainFamilies
            )
        }
    }

    func testSessionFindEnginePerformanceOnLargeBodySet() {
        let engine = SessionFindEngine()
        let sessions = makeSyntheticSessions(count: 2_000)

        measure {
            let outcome = engine.find(in: sessions, query: "index")
            XCTAssertFalse(outcome.results.isEmpty)
        }
    }

    /// Cold-path find: no body-text cache, all 2,000 sessions decoded from Data on every run.
    /// Compare with testSessionFindEngineWarmCachePath to see the decode-skip speedup.
    /// Rich 1 KB JSON bodies make the decode cost visible.
    func testSessionFindEngineColdCachePath() {
        let engine   = SessionFindEngine()
        let sessions = makeSyntheticSessionsWithRichBodies(count: 2_000)

        measure {
            let outcome = engine.find(in: sessions, query: "email")
            XCTAssertFalse(outcome.results.isEmpty)
        }
    }

    /// Warm-path find: body texts already decoded from a prior run, served from the cache.
    /// Compare with testSessionFindEngineColdCachePath — the difference is the UTF-8 decode
    /// cost for 2,000 × 1 KB bodies, which the warm path skips entirely.
    func testSessionFindEngineWarmCachePath() {
        let engine   = SessionFindEngine()
        let sessions = makeSyntheticSessionsWithRichBodies(count: 2_000)

        // One cold run to populate the cache (not measured).
        let seedOutcome = engine.find(in: sessions, query: "userId")
        let bodyTextCache = seedOutcome.decodedBodyTexts

        measure {
            let outcome = engine.find(in: sessions, query: "email", bodyTextCache: bodyTextCache)
            XCTAssertFalse(outcome.results.isEmpty)
            XCTAssertTrue(outcome.decodedBodyTexts.isEmpty,
                          "Warm run must not re-decode any session that was in the cache")
        }
    }

    /// Filter with active search text: inline header join runs at filter time (on demand).
    /// Sessions have 15 request + 15 response headers. This is now the production code path —
    /// searchableText was removed from SessionSummary so the join is deferred to filter time,
    /// eliminating O(sessions × headers) string work at capture time when no search is active.
    func testSessionFilterEngineWithSearchText() {
        let engine   = SessionFilterEngine()
        let sessions = makeSyntheticSessionsWithRichHeaders(count: 2_000)
        let criteria = SessionFilterCriteria(
            hostContains: "api",
            method: "GET",
            scheme: .https,
            inspectionMatch: .notTunneled,
            statusMatch: .range(200...299)
        )

        measure {
            _ = engine.filter(sessions, criteria: criteria, searchText: "users")
        }
    }

    /// Filter without search text: structured criteria only, zero header-join work.
    /// This is the common case during capture (user hasn't typed anything in search).
    func testSessionFilterEngineNoSearchText() {
        let engine   = SessionFilterEngine()
        let sessions = makeSyntheticSessionsWithRichHeaders(count: 2_000)
        let criteria = SessionFilterCriteria(
            hostContains: "api",
            method: "GET",
            scheme: .https,
            inspectionMatch: .notTunneled,
            statusMatch: .range(200...299)
        )

        measure {
            _ = engine.filter(sessions, criteria: criteria, searchText: "")
        }
    }

    func testTimelineClassifyAllPerformanceOnLargeCapture() {
        let sessions = makeSyntheticSessions(count: 500)
        let analyzer = TimelineAnalyzer()

        measure(metrics: [XCTClockMetric()]) {
            let events = analyzer.classifyAll(sessions: sessions)
            XCTAssertEqual(events.count, 500)
        }
    }

    func testJSONSyntaxHighlighterPerformanceOnLargeJSON() {
        let json = makeLargeSyntheticJSONString(elementCount: 500)
        XCTAssertGreaterThan(json.count, 50_000)

        measure(metrics: [XCTClockMetric()]) {
            let spans = JSONSyntaxHighlighter.spans(for: json)
            XCTAssertFalse(spans.isEmpty)
        }
    }

    func testHTTPResponseParserStreamingChunkPerformance() {
        let parser = HTTPResponseParser()
        let fullData = makeLargeSyntheticResponseBodyData(contentLength: 500_000)
        let chunkSize = fullData.count / 50

        measure(metrics: [XCTClockMetric()]) {
            var currentLength = chunkSize
            var frameState: HTTPResponseFrameState?
            for _ in 0..<50 {
                let subdata = fullData.subdata(in: 0..<currentLength)
                if let state = frameState {
                    _ = parser.isComplete(dataCount: subdata.count, bodyData: subdata, frameState: state)
                } else if let state = parser.parseFrameState(from: subdata, requestMethod: "GET") {
                    frameState = state
                    _ = parser.isComplete(dataCount: subdata.count, bodyData: subdata, frameState: state)
                }
                currentLength += chunkSize
            }
        }
    }

    func testProxySessionRecorderThroughput() {
        let responseData = Data("{\"ok\":true}".utf8)
        let request = CapturedRequest(
            method: "GET",
            scheme: .https,
            inspectionKind: .interceptedTLS,
            host: "api.example.com",
            port: 443,
            path: "/v1/items",
            headers: [HTTPHeaderField(name: "Host", value: "api.example.com")],
            bodyData: nil,
            bodySize: nil
        )
        let response = CapturedResponse(
            statusCode: 200,
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
            bodyData: responseData,
            bodySize: responseData.count
        )

        measure(metrics: [XCTClockMetric()]) {
            let expectation = XCTestExpectation(description: "recorder throughput")
            let store = InMemorySessionStore()
            let recorder = ProxySessionRecorder(sessionStore: store)

            Task {
                for _ in 0..<100 {
                    let id = await recorder.beginSession(request: request)
                    await recorder.completeSession(id: id, response: response)
                }
                await recorder.waitForPendingStoreFlush()
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
            XCTAssertEqual(store.sessions.count, 100)
        }
    }

    func testJSONTreeParserPerformanceOnLargeJSON() {
        let json = makeLargeSyntheticJSONString(elementCount: 500)
        let data = Data(json.utf8)

        measure(metrics: [XCTClockMetric()]) {
            do {
                let root = try JSONTreeParser.parse(data)
                XCTAssertNotNil(root)
            } catch {
                XCTFail("Parse failed: \(error)")
            }
        }
    }

    func testSessionStoreAppendPerformanceOnLargeCapture() {
        let sessions = makeSyntheticSessions(count: 1_500)

        measure {
            let store = InMemorySessionStore()
            for session in sessions {
                store.append(session)
            }
            XCTAssertEqual(store.sessions.count, sessions.count)
        }
    }

    func testRecordingFidelitySizeComparisonOnRepresentativeCapture() throws {
        let envelope = makeRepresentativeRecordingEnvelope()
        let sizes = try Dictionary(
            uniqueKeysWithValues: RecordingSaveFidelity.allCases.map { fidelity in
                (fidelity, try exportRecordingSize(envelope: envelope, fidelity: fidelity))
            }
        )

        XCTAssertLessThan(sizes[.metadataOnly]!, sizes[.fullRecording]!)
        XCTAssertLessThan(sizes[.textBodiesOnly]!, sizes[.fullRecording]!)
        XCTAssertLessThan(sizes[.mediaFocused]!, sizes[.fullRecording]!)
        XCTAssertLessThan(sizes[.metadataOnly]!, sizes[.textBodiesOnly]!)
    }

    func testFullRecordingExportPerformanceOnRepresentativeCapture() {
        let envelope = makeRepresentativeRecordingEnvelope()

        measure(metrics: [XCTClockMetric()]) {
            let destinationURL = temporaryRecordingURL()
            defer { try? FileManager.default.removeItem(at: destinationURL) }

            do {
                try recordingExportService.exportAsRecording(
                    envelope,
                    to: destinationURL,
                    fidelity: .fullRecording
                )
            } catch {
                XCTFail("Export failed: \(error)")
            }
        }
    }

    func testMetadataOnlyExportPerformanceOnRepresentativeCapture() {
        let envelope = makeRepresentativeRecordingEnvelope()

        measure(metrics: [XCTClockMetric()]) {
            let destinationURL = temporaryRecordingURL()
            defer { try? FileManager.default.removeItem(at: destinationURL) }

            do {
                try recordingExportService.exportAsRecording(
                    envelope,
                    to: destinationURL,
                    fidelity: .metadataOnly
                )
            } catch {
                XCTFail("Export failed: \(error)")
            }
        }
    }

    func testFullRecordingImportPerformanceOnRepresentativeCapture() throws {
        let envelope = makeRepresentativeRecordingEnvelope()
        let destinationURL = temporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        try recordingExportService.exportAsRecording(
            envelope,
            to: destinationURL,
            fidelity: .fullRecording
        )

        measure(metrics: [XCTClockMetric()]) {
            let expectation = XCTestExpectation(description: "import finished")

            Task {
                do {
                    _ = try await self.recordingImportService.open(from: destinationURL)
                } catch {
                    XCTFail("Import failed: \(error)")
                }
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }

    func testMetadataOnlyImportPerformanceOnRepresentativeCapture() throws {
        let envelope = makeRepresentativeRecordingEnvelope()
        let destinationURL = temporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        try recordingExportService.exportAsRecording(
            envelope,
            to: destinationURL,
            fidelity: .metadataOnly
        )

        measure(metrics: [XCTClockMetric()]) {
            let expectation = XCTestExpectation(description: "import finished")

            Task {
                do {
                    _ = try await self.recordingImportService.open(from: destinationURL)
                } catch {
                    XCTFail("Import failed: \(error)")
                }
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }

    private func makeSyntheticSessions(count: Int) -> [SessionRecord] {
        let hosts = [
            "api.example.com",
            "media.example.com",
            "cdn.example.net",
            "auth.example.com",
            "images.example.net",
            "stream.example.net"
        ]
        let methods = ["GET", "POST", "PUT", "DELETE", "PATCH"]
        let statuses = [200, 201, 204, 301, 302, 400, 401, 404, 429, 500]
        let now = Date()

        return (0..<count).map { index in
            let host = hosts[index % hosts.count]
            let method = methods[index % methods.count]
            let scheme: SessionScheme = index.isMultiple(of: 3) ? .http : .https
            let inspectionKind: SessionInspectionKind = index.isMultiple(of: 7) ? .tunneledTLS : (scheme == .https ? .interceptedTLS : .plain)
            let statusCode = statuses[index % statuses.count]
            let bodyData = "{\"index\":\(index),\"host\":\"\(host)\"}".data(using: .utf8)
            let startedAt = now.addingTimeInterval(TimeInterval(-count + index))

            return SessionRecord(
                request: CapturedRequest(
                    method: method,
                    scheme: scheme,
                    inspectionKind: inspectionKind,
                    host: host,
                    port: scheme == .https ? 443 : 80,
                    path: syntheticPath(index: index),
                    headers: [HTTPHeaderField(name: "Host", value: host)],
                    bodyData: method == "GET" ? nil : bodyData,
                    bodySize: method == "GET" ? nil : bodyData?.count
                ),
                response: CapturedResponse(
                    statusCode: statusCode,
                    headers: [HTTPHeaderField(name: "Content-Type", value: index.isMultiple(of: 4) ? "application/json" : "text/plain")],
                    bodyData: inspectionKind == .tunneledTLS ? nil : bodyData,
                    bodySize: inspectionKind == .tunneledTLS ? nil : bodyData?.count
                ),
                state: statusCode >= 400 ? .failed : .completed,
                timing: SessionTiming(
                    startedAt: startedAt,
                    completedAt: startedAt.addingTimeInterval(0.02 + Double(index % 5) * 0.01)
                ),
                failure: statusCode >= 400 ? SessionFailure(message: "Synthetic failure \(statusCode)") : nil
            )
        }
    }

    private func syntheticPath(index: Int) -> String {
        switch index % 4 {
        case 0:
            return "/v1/users/\(index % 500)/profile"
        case 1:
            return "/v2/projects/\(index % 80)/builds/\(index)"
        case 2:
            return "/stream/\(index % 12)/segment-\(index % 400).m4s"
        default:
            return "/assets/\(index % 24)/image-\(index % 600).jpg"
        }
    }

    private func makeRepresentativeRecordingEnvelope() -> SessionExportEnvelope {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sessions = [
            makeRecordingSession(
                method: "GET",
                host: "stream.example.com",
                path: "/playlist/master.m3u8",
                responseBody: hlsManifestBody(),
                contentType: "application/vnd.apple.mpegurl",
                startedAt: now
            ),
            makeRecordingSession(
                method: "GET",
                host: "stream.example.com",
                path: "/video/init-main.m4s",
                responseBody: Data(repeating: 0xAA, count: 220_000),
                contentType: "video/mp4",
                startedAt: now.addingTimeInterval(1)
            ),
            makeRecordingSession(
                method: "GET",
                host: "cdn.example.com",
                path: "/video/segment-001.m4s",
                responseBody: Data(repeating: 0xBB, count: 420_000),
                contentType: "video/mp4",
                startedAt: now.addingTimeInterval(2)
            ),
            makeRecordingSession(
                method: "GET",
                host: "api.example.com",
                path: "/playback/bootstrap",
                responseBody: Data("{\"streamingUrl\":\"https://stream.example.com/playlist/master.m3u8\",\"token\":\"abc\"}".utf8),
                contentType: "application/json",
                startedAt: now.addingTimeInterval(3)
            ),
            makeRecordingSession(
                method: "POST",
                host: "auth.example.com",
                path: "/license",
                requestBody: Data("{\"challenge\":\"deadbeef\"}".utf8),
                responseBody: Data(repeating: 0xCC, count: 96_000),
                requestContentType: "application/json",
                contentType: "application/octet-stream",
                startedAt: now.addingTimeInterval(4)
            ),
            makeRecordingSession(
                method: "GET",
                host: "api.example.com",
                path: "/v1/catalog",
                responseBody: Data("{\"items\":[{\"id\":1},{\"id\":2},{\"id\":3}]}".utf8),
                contentType: "application/json",
                startedAt: now.addingTimeInterval(5)
            ),
            makeRecordingSession(
                method: "GET",
                host: "images.example.com",
                path: "/assets/poster.jpg",
                responseBody: Data(repeating: 0xDD, count: 180_000),
                contentType: "image/jpeg",
                startedAt: now.addingTimeInterval(6)
            )
        ]

        return SessionExportEnvelope(
            exportedAt: now.addingTimeInterval(10),
            appVersion: Bundle.main.marketingVersionOrDev,
            proxyPort: 9090,
            sessionCount: sessions.count,
            sessions: sessions
        )
    }

    private func makeRecordingSession(
        method: String,
        host: String,
        path: String,
        requestBody: Data? = nil,
        responseBody: Data?,
        requestContentType: String? = nil,
        contentType: String,
        startedAt: Date
    ) -> SessionRecord {
        var requestHeaders = [HTTPHeaderField(name: "Host", value: host)]
        if let requestContentType {
            requestHeaders.append(HTTPHeaderField(name: "Content-Type", value: requestContentType))
        }

        return SessionRecord(
            request: CapturedRequest(
                method: method,
                scheme: .https,
                inspectionKind: .interceptedTLS,
                host: host,
                port: 443,
                path: path,
                headers: requestHeaders,
                bodyData: requestBody,
                bodySize: requestBody?.count
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HTTPHeaderField(name: "Content-Type", value: contentType)],
                bodyData: responseBody,
                bodySize: responseBody?.count
            ),
            state: .completed,
            timing: SessionTiming(
                startedAt: startedAt,
                completedAt: startedAt.addingTimeInterval(0.15)
            )
        )
    }

    private func hlsManifestBody() -> Data {
        Data("""
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1920x1080
        video/main.m3u8
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="English",DEFAULT=YES,AUTOSELECT=YES,URI="audio/en.m3u8"
        """.utf8)
    }

    private func exportRecordingSize(
        envelope: SessionExportEnvelope,
        fidelity: RecordingSaveFidelity
    ) throws -> Int {
        let destinationURL = temporaryRecordingURL()
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        try recordingExportService.exportAsRecording(envelope, to: destinationURL, fidelity: fidelity)
        let attributes = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
        return attributes[.size] as? Int ?? 0
    }

    /// Appends a timing result line to memlog/perf_measurements.txt so numbers are
    /// always readable regardless of how xcodebuild captures test output.
    /// Uses #file to derive the project root reliably — no environment variables needed.
    private func temporaryRecordingURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jproxy")
    }

    /// Sessions with ~1 KB JSON response bodies — enough decode work to make cold vs warm
    /// cache timing meaningfully different at 2,000 sessions.
    private func makeSyntheticSessionsWithRichBodies(count: Int) -> [SessionRecord] {
        let hosts  = ["api.example.com", "media.example.com", "auth.example.com"]
        let now    = Date()
        return (0..<count).map { index in
            let host = hosts[index % hosts.count]
            // ~1 KB JSON body per response
            let responseJSON = """
            {"userId":\(index),"email":"user\(index)@example.com","name":"Test User \(index)",\
            "role":"member","createdAt":"2025-01-01T00:00:00Z",\
            "preferences":{"theme":"dark","language":"en","notifications":true},\
            "tags":["tag\(index % 10)","tag\(index % 7)","tag\(index % 5)"]}
            """
            let bodyData = responseJSON.data(using: .utf8)!
            let startedAt = now.addingTimeInterval(TimeInterval(-count + index))
            return SessionRecord(
                request: CapturedRequest(
                    method: "GET",
                    scheme: .https,
                    inspectionKind: .interceptedTLS,
                    host: host,
                    port: 443,
                    path: "/v1/users/\(index)",
                    headers: [HTTPHeaderField(name: "Host", value: host)],
                    bodyData: nil,
                    bodySize: nil
                ),
                response: CapturedResponse(
                    statusCode: 200,
                    headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
                    bodyData: bodyData,
                    bodySize: bodyData.count
                ),
                state: .completed,
                timing: SessionTiming(
                    startedAt: startedAt,
                    completedAt: startedAt.addingTimeInterval(0.05)
                )
            )
        }
    }

    /// Sessions with 15 request headers and 15 response headers — enough header-join work to
    /// make the no-cache vs searchableText-cache timing difference clearly visible.
    private func makeSyntheticSessionsWithRichHeaders(count: Int) -> [SessionRecord] {
        let hosts  = ["api.example.com", "media.example.com", "auth.example.com"]
        let now    = Date()
        // A realistic browser/client request header set (~15 headers)
        let requestHeaders: [HTTPHeaderField] = [
            HTTPHeaderField(name: "Host",            value: "api.example.com"),
            HTTPHeaderField(name: "Accept",          value: "application/json, text/plain, */*"),
            HTTPHeaderField(name: "Accept-Language", value: "en-US,en;q=0.9"),
            HTTPHeaderField(name: "Accept-Encoding", value: "gzip, deflate, br"),
            HTTPHeaderField(name: "Authorization",   value: "Bearer eyJhbGciOiJSUzI1NiJ9.stub"),
            HTTPHeaderField(name: "Content-Type",    value: "application/json"),
            HTTPHeaderField(name: "User-Agent",      value: "MyApp/3.2.1 (iPhone; iOS 17.4)"),
            HTTPHeaderField(name: "X-Request-ID",    value: "req-abc123"),
            HTTPHeaderField(name: "X-Client-Version",value: "3.2.1"),
            HTTPHeaderField(name: "X-Platform",      value: "ios"),
            HTTPHeaderField(name: "X-Device-ID",     value: "device-xyz-987"),
            HTTPHeaderField(name: "Cache-Control",   value: "no-cache"),
            HTTPHeaderField(name: "Connection",      value: "keep-alive"),
            HTTPHeaderField(name: "Origin",          value: "https://app.example.com"),
            HTTPHeaderField(name: "Referer",         value: "https://app.example.com/dashboard"),
        ]
        let responseHeaders: [HTTPHeaderField] = [
            HTTPHeaderField(name: "Content-Type",        value: "application/json; charset=utf-8"),
            HTTPHeaderField(name: "Content-Encoding",    value: "gzip"),
            HTTPHeaderField(name: "Cache-Control",       value: "no-store, max-age=0"),
            HTTPHeaderField(name: "X-Request-ID",        value: "req-abc123"),
            HTTPHeaderField(name: "X-RateLimit-Limit",   value: "1000"),
            HTTPHeaderField(name: "X-RateLimit-Remaining",value: "987"),
            HTTPHeaderField(name: "X-RateLimit-Reset",   value: "1700000060"),
            HTTPHeaderField(name: "Strict-Transport-Security", value: "max-age=31536000"),
            HTTPHeaderField(name: "X-Content-Type-Options", value: "nosniff"),
            HTTPHeaderField(name: "X-Frame-Options",     value: "DENY"),
            HTTPHeaderField(name: "Vary",                value: "Accept-Encoding, Authorization"),
            HTTPHeaderField(name: "ETag",                value: "\"abc123def456\""),
            HTTPHeaderField(name: "Age",                 value: "0"),
            HTTPHeaderField(name: "Server",              value: "nginx/1.24.0"),
            HTTPHeaderField(name: "Transfer-Encoding",   value: "chunked"),
        ]
        let bodyData = "{\"ok\":true}".data(using: .utf8)!
        return (0..<count).map { index in
            let host = hosts[index % hosts.count]
            let startedAt = now.addingTimeInterval(TimeInterval(-count + index))
            return SessionRecord(
                request: CapturedRequest(
                    method: "GET",
                    scheme: .https,
                    inspectionKind: .interceptedTLS,
                    host: host,
                    port: 443,
                    path: "/v1/items/\(index)",
                    headers: requestHeaders,
                    bodyData: nil,
                    bodySize: nil
                ),
                response: CapturedResponse(
                    statusCode: 200,
                    headers: responseHeaders,
                    bodyData: bodyData,
                    bodySize: bodyData.count
                ),
                state: .completed,
                timing: SessionTiming(
                    startedAt: startedAt,
                    completedAt: startedAt.addingTimeInterval(0.05)
                )
            )
        }
    }

    private func makeLargeSyntheticJSONString(elementCount: Int) -> String {
        var items: [String] = []
        items.reserveCapacity(elementCount)
        for i in 0..<elementCount {
            items.append("""
            {"id":\(i),"name":"item_\(i)","active":\(i % 2 == 0),"score":\(Double(i) * 1.5),"tags":["alpha","beta","gamma_\(i % 10)"],"metadata":{"createdBy":"system","version":\(i % 5),"notes":null,"payload":"abc_123_xyz_\(i)"}}
            """)
        }
        return "{\"total\":\(elementCount),\"items\":[\(items.joined(separator: ","))]}"
    }

    private func makeLargeSyntheticResponseBodyData(contentLength: Int) -> Data {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(contentLength)\r\nConnection: keep-alive\r\n\r\n"
        var data = Data(header.utf8)
        data.append(Data(repeating: 0x5A, count: contentLength))
        return data
    }
}
