import Foundation
import Network
import SwiftUI

/// Bounded loopback traffic for editorial acceptance. Never uses the user's proxy or rules.
@MainActor
final class TransportAssetUITestScenario: ObservableObject {
    @Published private(set) var status = "Preparing demonstration"
    @Published private(set) var completed = false
    let bundleID = UUID()
    private var started = false
    static let host = "media.example.test"
    static let playlist = Data("""
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:6
    #EXT-X-MEDIA-SEQUENCE:0
    #EXTINF:6.0,
    segment-0.ts
    #EXTINF:6.0,
    segment-1.ts
    #EXTINF:6.0,
    segment-2.ts
    #EXT-X-ENDLIST

    """.utf8)

    static func isEnabled(_ fixture: UITestLaunchConfiguration.Fixture?) -> Bool {
        fixture == .transportAssets || fixture == .streamingAssets
    }

    func run(fixture: UITestLaunchConfiguration.Fixture?, store: any SessionStore, root: URL) async {
        guard Self.isEnabled(fixture), !started else { return }
        started = true
        let gate = EffectBundleActivationGate.shared
        let rules = ResponseOverrideStore(effectBundleGate: gate)
        let recorder = ProxySessionRecorder(sessionStore: store)
        let proxy = ProxyServer(port: 0, bindHost: "127.0.0.1", sessionRecorder: recorder,
                                responseOverrideStore: rules)
        let asset = root.appendingPathComponent("transport-demonstration-\(bundleID).json")
        defer { try? FileManager.default.removeItem(at: asset) }
        do {
            let body = Data(#"{"collection":"Coast","items":[{"id":1,"title":"Harbor"}]}"#.utf8)
            try body.write(to: asset, options: .atomic)
            var retained = Self.rule(path: "/collection.json", body: body, type: "application/json")
            retained.bodySource = .file(asset)
            retained.authoredResource = .init(bundleID: bundleID, revisionID: bundleID,
                activationID: UUID(), resourceID: retained.id, assetID: "collection-demonstration",
                expectedSHA256: EffectBundleValidator.sha256Hex(body))
            try await rules.addRule(retained)
            let responses: [(String, Data, String, Int)] = [
                ("/stream/playlist.m3u8", Self.playlist, "application/vnd.apple.mpegurl", 200),
                ("/stream/segment-0.ts", Data("Synthetic segment zero".utf8), "video/mp2t", 200),
                ("/stream/segment-1.ts", Data("Controlled segment unavailable".utf8), "text/plain", 503),
                ("/stream/segment-2.ts", Data("Synthetic segment two".utf8), "video/mp2t", 200)
            ]
            for (path, bytes, type, status) in responses {
                try await rules.addRule(Self.rule(path: path, body: bytes, type: type, status: status))
            }
            try await proxy.start()
            let received = try await Self.fetch(path: "/collection.json", port: proxy.port)
            guard received.status == 200, received.body == body else { throw ScenarioError.responseMismatch }
            if fixture == .streamingAssets {
                for (path, bytes, _, status) in responses {
                    let response = try await Self.fetch(path: path, port: proxy.port)
                    guard response.status == status, response.body == bytes else { throw ScenarioError.responseMismatch }
                }
            }
            await recorder.waitForPendingStoreFlush()
            for _ in 0..<100 {
                if gate.evidence(bundleID: bundleID).receipts.first?.delivery == .downstreamWriteSucceeded { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard let receipt = gate.evidence(bundleID: bundleID).receipts.first,
                  receipt.delivery == .downstreamWriteSucceeded, receipt.matchesExpectedDelivery == true,
                  receipt.sessionID != nil else { throw ScenarioError.missingReceipt }
            // Exercise the real retained-file failure without falling through to an external origin.
            try FileManager.default.removeItem(at: asset)
            let request = CapturedRequest(method: "GET", scheme: .http, host: Self.host, port: 80,
                path: "/collection.json", headers: [], bodyData: nil, bodySize: nil, clientAddress: "127.0.0.1")
            do {
                _ = try await rules.ruleDecision(for: request)
                throw ScenarioError.expectedReadFailure
            } catch is ResponseOverrideError { }
            guard gate.evidence(bundleID: bundleID).receipts.contains(where: {
                $0.evaluation == .assetReadFailed && $0.delivery == .notApplied
            }) else { throw ScenarioError.missingReceipt }
            await proxy.stop()
            completed = true
            status = "Demonstration complete · loopback verified · listener stopped"
        } catch {
            await proxy.stop()
            status = "Demonstration failed: \(error.localizedDescription)"
        }
    }

    private static func rule(path: String, body: Data, type: String, status: Int = 200) -> ResponseOverrideRule {
        ResponseOverrideRule(requestMethod: "GET", requestScheme: .http, host: host, port: 80,
            path: path, sourceKind: .inlineText, sourceDescription: "Controlled loopback demonstration",
            statusCode: status, headers: [.init(name: "Content-Type", value: type)], bodySource: .inline(body),
            sourceClientAddress: "127.0.0.1")
    }

    private enum ScenarioError: Error { case responseMismatch, missingReceipt, expectedReadFailure, invalidResponse }

    private static func fetch(path: String, port: UInt16) async throws -> (status: Int, body: Data) {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let timeout = DispatchWorkItem { connection.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        defer { timeout.cancel(); connection.cancel() }
        try await NetworkConnectionIO.start(connection, on: DispatchQueue(label: "editorial.loopback"))
        try await NetworkConnectionIO.send(Data(("GET http://\(host)\(path) HTTP/1.1\r\n"
            + "Host: \(host)\r\nConnection: close\r\n\r\n").utf8), on: connection)
        var data = Data()
        while data.count < 65_536 {
            let (bytes, complete) = try await NetworkConnectionIO.receive(on: connection)
            data.append(bytes)
            if let split = data.range(of: Data("\r\n\r\n".utf8)) {
                let headers = String(decoding: data[..<split.lowerBound], as: UTF8.self)
                let length = headers.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }
                if let length, data.count - split.upperBound >= length,
                   let status = headers.split(whereSeparator: \.isWhitespace).dropFirst().first.flatMap({ Int($0) }) {
                    return (status, Data(data[split.upperBound...]))
                }
            }
            if complete { break }
        }
        throw ScenarioError.invalidResponse
    }
}

struct TransportAssetEvidenceUITestView: View {
    @Environment(\.appTextScale) private var textScale
    @ObservedObject var scenario: TransportAssetUITestScenario
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Controlled retained-asset demonstration").appFont(.headline, scale: textScale)
                Text("Real loopback transport, followed by a local missing-file check. Rendering and playback are unconfirmed.")
                    .appFont(.body, scale: textScale)
                if scenario.completed { EffectBundleEvidenceView(bundleID: scenario.bundleID) }
            }.padding()
        }
        .frame(width: 900, height: 680)
        .background(UITestPrimaryScreenWindowConfigurator().frame(width: 0, height: 0))
    }
}
