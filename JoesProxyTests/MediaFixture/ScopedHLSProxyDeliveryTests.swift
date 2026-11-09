import Foundation
import Network
import XCTest
@testable import JoesProxy

final class ScopedHLSProxyDeliveryTests: XCTestCase {
    func testReviewedSubtitleFaultPreservesSiblingDownstreamDelivery() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/HLS/multilingual-text-vod-v1")
        let configuration = HLSFixtureProfileDescriptor.load(from: directory).defaultPlaybackConfiguration
        let fixture = try await HLSFixtureServer.make(profileDirectory: directory,
                                                     playbackConfiguration: configuration)
        let registry = HLSFixtureOriginRegistry()
        let gate = EffectBundleActivationGate.shared
        let routes = HLSSubstitutionRouteStore(effectBundleGate: gate)
        let runID = UUID()
        let id = UUID()
        let bundleID = UUID()
        let activationID = UUID()
        let manifest = EffectBundleManifest(schemaVersion: EffectBundleSchema.currentVersion, id: bundleID,
            name: "Synthetic scoped media", notes: "", createdAt: Date(), appVersion: "test",
            privacy: .exactContent, defaultTTLSeconds: 60, assets: [], responseEffects: [],
            hlsSubstitutions: [.init(id: id, profileID: "multilingual-text-vod-v1", profileVersion: "1",
                profileAssetIDs: [], profileRootLogicalPath: "media", origin: .init(scheme: .http, host: "media.example.test"),
                scope: .selectedPlaylist(path: "/master.m3u8?variant=reviewed"), playbackConfiguration: configuration,
                requestPolicy: .init(clientAddress: "127.0.0.1", missingTextTrackID: "es"))])
        gate.register(bundleID: bundleID, responseRuleIDs: [], hlsExperimentIDs: [id])
        gate.registerResources(manifest: manifest, activationID: activationID)
        gate.open(bundleID: bundleID)
        defer { gate.unregister(bundleID: bundleID) }
        let mount = "/.joesproxy/hls-substitution/\(id.uuidString.lowercased())/"
        await registry.register(host: "fixture.hls.joesproxy.invalid", runID: runID, server: fixture,
                                permitsDirectAccess: false)
        let experiment = HLSSubstitutionExperiment(id: id, owner: .localUser,
            profileID: "multilingual-text-vod-v1", origin: .init(scheme: .http, host: "media.example.test"),
            scope: .selectedPlaylist(path: "/master.m3u8?variant=reviewed"), mountPath: mount,
            fixtureRunID: runID, state: .active, startedAt: Date(), expiresAt: nil, stoppedAt: nil,
            metrics: .init(), requestPolicy: .init(clientAddress: "127.0.0.1", missingTextTrackID: "es"))
        try await routes.install(experiment)
        let proxy = ProxyServer(port: 0, fixtureOriginRegistry: registry, hlsSubstitutionRouteStore: routes)
        try await proxy.start()
        do {
            let bypass = try await fetch("/master.m3u8", port: proxy.port, host: "fixture.hls.joesproxy.invalid")
            XCTAssertTrue(bypass.hasPrefix("HTTP/1.1 403"))
            for (path, status) in [("/master.m3u8?variant=reviewed", 200),
                                   (mount + "text/es/stream.m3u8", 404),
                                   (mount + "text/en/stream.m3u8", 200),
                                   (mount + "audio-en/stream.m3u8", 200),
                                   (mount + "video-720/stream.m3u8?reference=/text/es/fault", 200)] {
                let response = try await fetch(path, port: proxy.port)
                XCTAssertTrue(response.hasPrefix("HTTP/1.1 \(status)"), response)
                if status == 200 { XCTAssertTrue(response.contains("#EXTM3U")) }
                else { XCTAssertFalse(response.contains("#EXTM3U")) }
            }
            for _ in 0..<100 {
                if gate.observationSnapshot(bundleID: bundleID).filter({ $0.delivery == .downstreamWriteSucceeded }).count == 5 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let receipts = gate.observationSnapshot(bundleID: bundleID)
            XCTAssertEqual(receipts.count, 5)
            XCTAssertTrue(receipts.allSatisfy { $0.identity.activationID == activationID && $0.delivery == .downstreamWriteSucceeded })
            XCTAssertEqual(receipts.filter { $0.outcome == "http_404" }.count, 1)
            XCTAssertEqual(receipts.first { $0.outcome == "http_404" }?.textTrack?.id, "es")
            gate.close(bundleID: bundleID)
            await routes.remove(experimentID: id)
            XCTAssertFalse(gate.allows(bundleID: bundleID))
            XCTAssertEqual(gate.observationSnapshot(bundleID: bundleID), receipts)
            await proxy.stop()
            await registry.unregister(host: "fixture.hls.joesproxy.invalid", runID: runID)
        } catch {
            await proxy.stop()
            await registry.unregister(host: "fixture.hls.joesproxy.invalid", runID: runID)
            throw error
        }
    }

    private func fetch(_ path: String, port: UInt16, host: String = "media.example.test") async throws -> String {
        let connection = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(.init(rawValue: port)), using: .tcp)
        defer { connection.cancel() }
        try await NetworkConnectionIO.start(connection, on: DispatchQueue(label: "tests.scoped-media"))
        let request = "GET http://\(host)\(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
        try await NetworkConnectionIO.send(Data(request.utf8), on: connection)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                connection.cancel()
                throw URLError(.timedOut)
            }
            group.addTask {
            var data = Data()
            while data.count < 65_536 {
                let (bytes, complete) = try await NetworkConnectionIO.receive(on: connection)
                data.append(bytes)
                if let separator = data.range(of: Data("\r\n\r\n".utf8)) {
                    let headers = String(decoding: data[..<separator.lowerBound], as: UTF8.self)
                    let length = headers.components(separatedBy: "\r\n")
                        .first { $0.lowercased().hasPrefix("content-length:") }
                        .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }
                    if let length, data.count - separator.upperBound >= length { break }
                }
                if complete { break }
            }
            return String(decoding: data, as: UTF8.self)
            }
            defer { group.cancelAll() }
            let result = try await group.next()
            return try XCTUnwrap(result)
        }
    }
}
