import CryptoKit
import Foundation
import Network
import NIOCore
import NIOPosix
import XCTest
@testable import JoesProxy

final class UploadProxyIntegrationTests: XCTestCase {
    func testShutdownDuringStalledUploadIntakeDrainsAfterDiskReturns() async throws {
        let stall = UploadWriteStall()
        defer { stall.release() }
        try await runFixture(write: { try stall.write($0, $1) }) { proxy, upstream, service in
            let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxy.port)!, using: .tcp)
            defer { client.cancel(); stall.release() }
            try await NetworkConnectionIO.start(client, on: DispatchQueue(label: "upload.shutdown"))
            let header = "POST http://127.0.0.1:\(upstream)/upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1048576\r\n\r\n"
            try await NetworkConnectionIO.send(Data(header.utf8) + Data(repeating: 7, count: 1024), on: client)
            try await stall.waitUntilBlocked()
            let stopping = Task { await proxy.stop() }
            // Socket closure proves shutdown started; disk I/O still owns its reservation.
            _ = try? await NetworkConnectionIO.receiveAll(on: client)
            XCTAssertTrue(stall.isBlocked)
            XCTAssertEqual(service.budget.activeCount, 1)
            stall.release()
            await stopping.value
            XCTAssertEqual(service.budget.activeCount, 0)
            XCTAssertFalse(stall.timedOut)
        }
    }

    func testUploadResumesAfterDiskStallWithIdenticalBytes() async throws {
        let stall = UploadWriteStall()
        defer { stall.release() }
        try await runFixture(write: { try stall.write($0, $1) }) { proxy, upstream, service in
            let body = Data((0..<(500 * 1024 + 17)).map { UInt8(truncatingIfNeeded: $0) })
            let upload = Task { try await self.send(body: body, proxyPort: proxy.port, upstreamPort: upstream) }
            defer { stall.release(); upload.cancel() }
            try await stall.waitUntilBlocked()
            XCTAssertEqual(service.budget.activeCount, 1)
            let ordinary = try await self.send(body: Data([4, 5, 6]), proxyPort: proxy.port, upstreamPort: upstream)
            XCTAssertTrue(String(decoding: ordinary, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
            XCTAssertTrue(stall.isBlocked)
            stall.release()
            let response = String(decoding: try await upload.value, as: UTF8.self)
            let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"))
            XCTAssertTrue(response.hasSuffix(digest))
            XCTAssertFalse(stall.timedOut)
            XCTAssertLessThanOrEqual(stall.maximumChunkBytes, UploadBodySpool.maximumChunkBytes)
        }
    }

    func testStalledDiskBoundsAdmissionWhileOrdinaryTrafficContinues() async throws {
        let stall = UploadWriteStall()
        defer { stall.release() }
        try await runFixture(write: { try stall.write($0, $1) }) { proxy, upstream, service in
            var clients: [NWConnection] = []
            defer { stall.release(); clients.forEach { $0.cancel() } }
            for index in 0..<8 {
                let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxy.port)!, using: .tcp)
                clients.append(client)
                try await NetworkConnectionIO.start(client, on: DispatchQueue(label: "upload.stall.\(index)"))
                let header = "POST http://127.0.0.1:\(upstream)/upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1048576\r\n\r\n"
                try await NetworkConnectionIO.send(Data(header.utf8) + Data(repeating: 7, count: 1024), on: client)
                if index == 0 { try await stall.waitUntilBlocked() }
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while service.budget.activeCount < 8, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(service.budget.activeCount, 8)
            let rejected = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxy.port)!, using: .tcp)
            defer { rejected.cancel() }
            try await NetworkConnectionIO.start(rejected, on: DispatchQueue(label: "upload.stall.rejected"))
            try await NetworkConnectionIO.send(Data("POST http://127.0.0.1:\(upstream)/upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1048576\r\n\r\n".utf8), on: rejected)
            let response = String(decoding: try await NetworkConnectionIO.receiveAll(on: rejected), as: UTF8.self)
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 507"))
            XCTAssertTrue(response.contains("capacity is busy"))
            let started = Date()
            let ordinary = try await self.send(body: Data([1, 2, 3]), proxyPort: proxy.port, upstreamPort: upstream)
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertTrue(String(decoding: ordinary, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
            XCTAssertTrue(stall.isBlocked, "Ordinary delivery must finish before releasing the stalled file queue")
            await MainActor.run { XCTAssertTrue(stall.isBlocked) }
            XCTAssertEqual(service.budget.peakCount, 8)
            XCTAssertFalse(stall.timedOut)
            let evidence = XCTAttachment(string: "Synthetic disk stall: heldLeases=\(service.budget.activeCount), peakLeases=\(service.budget.peakCount), ordinaryDeliverySeconds=\(elapsed), maximumWriteChunkBytes=\(stall.maximumChunkBytes). Not an OS disk latency or process-memory ceiling.")
            evidence.lifetime = .keepAlways
            add(evidence)
        }
    }

    private func runFixture(overrides: ResponseOverrideStore? = nil, earlyResponse: Bool = false,
                            configuration: (any AppConfiguration)? = nil,
                            write: @escaping UploadBodySpool.WriteOperation = UploadBodySpool.diskWrite,
                            _ action: (ProxyServer, Int, UploadSpoolService) async throws -> Void) async throws {
        let sampler = CurrentProcessMetricsSampler()
        let before = sampler.sample()
        let started = Date()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/UploadProxyIntegrationTests/\(UUID().uuidString)")
        let service = UploadSpoolService(directory: root, write: write)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let upstream = try await ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(UploadDigestHandler(earlyResponse: earlyResponse)) }
            .bind(host: "127.0.0.1", port: 0).get()
        let proxy = ProxyServer(port: 0, configuration: configuration,
                                responseOverrideStore: overrides, uploadSpoolService: service)
        do {
            try await proxy.start()
            try await action(proxy, try XCTUnwrap(upstream.localAddress?.port), service)
            await proxy.stop()
            try await upstream.close().get()
            try await group.shutdownGracefully()
        } catch {
            await proxy.stop()
            try? await upstream.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
        XCTAssertEqual(service.budget.activeCount, 0)
        XCTAssertLessThanOrEqual(service.budget.peakCount, 8)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let after = sampler.sample()
        let evidence = XCTAttachment(string: "Upload loopback elapsedSeconds=\(Date().timeIntervalSince(started)) peakFileLeases=\(service.budget.peakCount) finalFileLeases=\(service.budget.activeCount) processFootprintBefore=\(before.physicalFootprintBytes) processFootprintAfter=\(after.physicalFootprintBytes). Process samples include the synthetic upstream and test buffers; not an app-only ceiling or 24-hour result.")
        evidence.lifetime = .keepAlways
        add(evidence)
        try FileManager.default.removeItem(at: root)
    }

    private func send(body: Data, proxyPort: UInt16, upstreamPort: Int) async throws -> Data {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPort)!, using: .tcp)
        defer { connection.cancel() }
        try await NetworkConnectionIO.start(connection, on: DispatchQueue(label: "upload.synthetic.client"))
        let header = "POST http://127.0.0.1:\(upstreamPort)/upload HTTP/1.1\r\nHost: 127.0.0.1:\(upstreamPort)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        try await NetworkConnectionIO.send(Data(header.utf8), on: connection)
        var offset = 0
        while offset < body.count {
            let end = min(body.count, offset + 16_384)
            try await NetworkConnectionIO.send(body.subdata(in: offset..<end), on: connection)
            offset = end
        }
        return try await NetworkConnectionIO.receiveAll(on: connection)
    }

    func testMidWriteDiskFullReturns507AndKeepsOtherRequestsWorking() async throws {
        try await runFixture(write: { fd, bytes in
            if lseek(fd, 0, SEEK_CUR) >= 17 { throw UploadBodySpoolError.diskIO(ENOSPC) }
            return try UploadBodySpool.diskWrite(fd, UnsafeRawBufferPointer(rebasing: bytes.prefix(17)))
        }) { proxy, upstream, service in
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxy.port)!, using: .tcp)
            defer { connection.cancel() }
            try await NetworkConnectionIO.start(connection, on: DispatchQueue(label: "upload.midwrite.failure"))
            let header = "POST http://127.0.0.1:\(upstream)/upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1048576\r\n\r\n"
            try await NetworkConnectionIO.send(Data(header.utf8) + Data(repeating: 7, count: 1024), on: connection)
            let failure = String(decoding: try await NetworkConnectionIO.receiveAll(on: connection), as: UTF8.self)
            XCTAssertTrue(failure.hasPrefix("HTTP/1.1 507"))
            XCTAssertTrue(failure.contains("Free disk space"))
            XCTAssertTrue(service.needsCleanup)
            let ordinary = try await self.send(body: Data([1, 2, 3]), proxyPort: proxy.port, upstreamPort: upstream)
            XCTAssertTrue(String(decoding: ordinary, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        }
    }

    func testLargeBinaryUploadPreservesBytesAndCleansSpool() async throws {
        try await runFixture { proxy, upstream, _ in
            let body = Data((0..<(6 * 1024 * 1024 + 17)).map { UInt8(truncatingIfNeeded: $0) })
            let response = try await self.send(body: body, proxyPort: proxy.port, upstreamPort: upstream)
            let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            XCTAssertTrue(String(decoding: response, as: UTF8.self).hasSuffix(digest))
            XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        }
    }

    func testConcurrentUploadsHaveIndependentBodies() async throws {
        try await runFixture { proxy, upstream, _ in
            let port = proxy.port
            try await withThrowingTaskGroup(of: Void.self) { tasks in
                for value in UInt8(1)...4 {
                    tasks.addTask {
                        let body = Data(repeating: value, count: 500 * 1024)
                        let response = try await self.send(body: body, proxyPort: port, upstreamPort: upstream)
                        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
                        XCTAssertTrue(String(decoding: response, as: UTF8.self).hasSuffix(digest))
                    }
                }
                try await tasks.waitForAll()
            }
        }
    }

    func testUnavailableStorageRejectsOnlyAffectedUpload() async throws {
        try await runFixture { proxy, upstream, service in
            // An unsafe directory is deterministic without filling the developer's disk.
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: service.directory.path)
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxy.port)!, using: .tcp)
            defer { connection.cancel() }
            try await NetworkConnectionIO.start(connection, on: DispatchQueue(label: "upload.storage.failure"))
            let header = "POST http://127.0.0.1:\(upstream)/upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1048576\r\n\r\n"
            try await NetworkConnectionIO.send(Data(header.utf8), on: connection)
            let failure = try await NetworkConnectionIO.receiveAll(on: connection)
            XCTAssertTrue(String(decoding: failure, as: UTF8.self).hasPrefix("HTTP/1.1 507"))
            XCTAssertTrue(String(decoding: failure, as: UTF8.self).contains("no rules were bypassed"))
            let ordinary = try await self.send(body: Data([1, 2, 3]), proxyPort: proxy.port, upstreamPort: upstream)
            XCTAssertTrue(String(decoding: ordinary, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        }
    }

    func testDisconnectDuringUploadDrainsAtShutdown() async throws {
        try await runFixture { proxy, upstream, service in
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxy.port)!, using: .tcp)
            try await NetworkConnectionIO.start(connection, on: DispatchQueue(label: "upload.disconnect"))
            let header = "POST http://127.0.0.1:\(upstream)/upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1048576\r\n\r\n"
            try await NetworkConnectionIO.send(Data(header.utf8) + Data(repeating: 3, count: 32_768), on: connection)
            for _ in 0..<100 where service.budget.activeCount == 0 {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(service.budget.activeCount, 1)
            connection.cancel()
        }
    }

    func testMapRemotePreservesSpooledUpload() async throws {
        let rules = ResponseOverrideStore()
        try await runFixture(overrides: rules) { proxy, upstream, _ in
            let source = CapturedRequest(method: "POST", scheme: .http, host: "127.0.0.1", port: upstream,
                path: "/upload", headers: [], bodyData: nil, bodySize: nil)
            let rule = try await rules.addMapRemoteRule(from: source, label: "Synthetic upload remap",
                remoteHost: "127.0.0.1", remotePort: upstream, remoteScheme: .http, remotePath: "/mapped")
            let body = Data(repeating: 91, count: 500 * 1024)
            let response = try await self.send(body: body, proxyPort: proxy.port, upstreamPort: upstream)
            let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            XCTAssertTrue(String(decoding: response, as: UTF8.self).hasSuffix(digest))
            let updated = await rules.rule(id: rule.id)
            XCTAssertEqual(updated?.hitCount, 1)
        }
    }

    func testEarlyUpstreamResponseDoesNotAppendUploadFailure() async throws {
        try await runFixture(earlyResponse: true) { proxy, upstream, _ in
            let response = try await self.send(body: Data(repeating: 11, count: 5 * 1024 * 1024),
                                               proxyPort: proxy.port, upstreamPort: upstream)
            let text = String(decoding: response, as: UTF8.self)
            XCTAssertTrue(text.hasPrefix("HTTP/1.1 200"))
            XCTAssertTrue(text.hasSuffix("early-response"))
            XCTAssertEqual(text.components(separatedBy: "HTTP/1.1").count, 2)
        }
    }

    func testRepeatedEarlyResponseAndImmediateShutdownSettlesUploadWorkers() async throws {
        for _ in 0..<5 {
            try await runFixture(earlyResponse: true) { proxy, upstream, _ in
                let response = try await self.send(body: Data(repeating: 11, count: 5 * 1024 * 1024),
                                                   proxyPort: proxy.port, upstreamPort: upstream)
                let text = String(decoding: response, as: UTF8.self)
                XCTAssertTrue(text.hasPrefix("HTTP/1.1 200"))
                XCTAssertTrue(text.hasSuffix("early-response"))
                XCTAssertEqual(text.components(separatedBy: "HTTP/1.1").count, 2)
                // runFixture stops immediately: receipt does not imply upload-worker completion.
            }
        }
    }

    @MainActor
    func testThrottledUploadPreservesBytesAndDrains() async throws {
        let configuration = MCPSelfValidationAppConfiguration()
        var throttle = NetworkThrottleConfiguration.defaults
        throttle.isEnabled = true
        throttle.selectedPresetID = "upload-test"
        throttle.presets = [NetworkThrottlePreset(id: "upload-test", name: "Synthetic upload",
            downstreamKbps: 10_000, upstreamKbps: 10_000, latencyMs: 1, isEditable: true)]
        configuration.networkThrottleConfiguration = throttle
        try await runFixture(configuration: configuration) { proxy, upstream, _ in
            let body = Data(repeating: 53, count: 500 * 1024)
            let response = try await self.send(body: body, proxyPort: proxy.port, upstreamPort: upstream)
            let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            XCTAssertTrue(String(decoding: response, as: UTF8.self).hasSuffix(digest))
        }
    }
}

/// Synthetic fixture only: deliberately retains a bounded test body to verify its exact digest.
private final class UploadDigestHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private var data = Data()
    private let earlyResponse: Bool
    private var responded = false
    init(earlyResponse: Bool) { self.earlyResponse = earlyResponse }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !responded else { return }
        let buffer = unwrapInboundIn(data)
        buffer.withUnsafeReadableBytes { self.data.append(contentsOf: $0) }
        let digest: String
        if earlyResponse {
            guard self.data.range(of: Data("\r\n\r\n".utf8)) != nil else { return }
            digest = "early-response"
        } else {
            guard let parsed = try? HTTPRequestParser().parseRequestFrame(self.data) else { return }
            digest = SHA256.hash(data: parsed.request.body).map { String(format: "%02x", $0) }.joined()
        }
        responded = true
        var response = context.channel.allocator.buffer(capacity: 200)
        response.writeString("HTTP/1.1 200 OK\r\nContent-Length: \(digest.utf8.count)\r\nConnection: close\r\n\r\n\(digest)")
        context.writeAndFlush(NIOAny(response)).whenComplete { _ in context.close(promise: nil) }
        self.data = Data()
    }
}
