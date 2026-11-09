import AppKit
import Network
import SwiftUI

/// A test-owned client and proxy. These seeded transitions do not represent live user approval.
@MainActor
final class MockJourneyUITestScenario: ObservableObject {
    @Published private(set) var status = "Preparing controlled client"
    @Published private(set) var title = ""
    @Published private(set) var detail = ""
    @Published private(set) var image: NSImage?
    @Published private(set) var complete = false
    private(set) var receivedPNG: Data?
    private(set) var receiptCount = 0
    private(set) var stopped = false
    private var started = false
    private let baseline = Data(#"{"items":[]}"#.utf8)
    private let baselineDetail = Data(#"{"id":2,"title":"Baseline detail","image":""}"#.utf8)

    func run(root: URL) async {
        guard !started else { return }
        started = true
        let origin = MCPSelfValidationFixtureOrigin(exactRoutes: [
            "/items": .init(body: String(decoding: baseline, as: UTF8.self), contentType: "application/json"),
            "/detail": .init(body: String(decoding: baselineDetail, as: UTF8.self), contentType: "application/json")
        ], loopbackOnly: true)
        // The real socket writer records into the app gate; this fixture uses a unique bundle ID.
        let gate = EffectBundleActivationGate.shared
        let rules = ResponseOverrideStore(effectBundleGate: gate)
        let recorder = ProxySessionRecorder(sessionStore: InMemorySessionStore())
        let proxy = ProxyServer(port: 0, bindHost: "127.0.0.1", sessionRecorder: recorder, responseOverrideStore: rules)
        let runs = HLSFixtureRunStore(persistenceURL: root.appendingPathComponent("runs.json"),
            profileRootURL: root.appendingPathComponent("profiles"), originRegistry: HLSFixtureOriginRegistry())
        runs.load()
        let hls = HLSSubstitutionCoordinator(runStore: runs,
            routeStore: HLSSubstitutionRouteStore(effectBundleGate: gate), responseOverrideStore: rules,
            persistenceURL: root.appendingPathComponent("hls.json"))
        let repository = EffectBundleRepository(persistenceURL: root.appendingPathComponent("bundles.json"),
            packagesRootURL: root.appendingPathComponent("packages"))
        let coordinator = EffectBundleActivationCoordinator(repository: repository, responseOverrideStore: rules,
            hlsCoordinator: hls, activationGate: gate, runtimeRootURL: root.appendingPathComponent("runtime"),
            schedulesTimers: false)
        var bundleID: UUID?
        do {
            try await origin.start()
            try await proxy.start()
            let base = origin.baseURL
            let listURL = base.appendingPathComponent("items")
            let detailURL = base.appendingPathComponent("detail")
            let imageURL = base.appendingPathComponent("artwork.png")
            let png = try MockIconRenderer.seal().png
            let scope = CapturedMockScope(host: "127.0.0.1", scheme: .http, port: Int(origin.port),
                path: "/items", clients: .address("127.0.0.1"))
            let related = CapturedRelatedResponse(source: baselineDetail,
                scope: .init(host: "127.0.0.1", scheme: .http, port: Int(origin.port), path: "/detail",
                             clients: .address("127.0.0.1")),
                edits: [.init(pointer: "/title", value: .string("Mock detail"))],
                images: [.init(pointer: "/image", assetID: "image-0")],
                identityLinks: [.init(pointer: "/id", primaryPointer: "/items/0/id")])
            let authoring = CollectionMockAuthoringService()
            let prepared = try await authoring.prepareCapturedPackage(ownerID: EffectBundleOwner.localUser.ownerID,
                idempotencyKey: UUID().uuidString, name: "Controlled client journey", source: baseline,
                draft: .init(collectionPointer: "/items", item: .object([
                    "id": .number("2"), "title": .string("Mock item"), "image": .string(""),
                    "detail": .string(detailURL.absoluteString)]), templateIndex: nil,
                    edits: [], identityPointers: ["/id"], countPointers: [], position: .append),
                scope: scope, images: [.init(itemPointer: "/image", bytes: png, originalURL: nil,
                    deliveryURL: imageURL, imageReference: "/artwork.png")],
                appVersion: "test", createdAt: Date(), relatedResponses: [related])
            bundleID = prepared.manifest.id
            _ = try await repository.importPreparedRevision(id: prepared.manifest.id, owner: .localUser,
                                                           authoringService: authoring)
            guard repository.record(id: prepared.manifest.id)?.state == .inactive,
                  try await fetch(listURL, port: proxy.port) == baseline else { throw Failure.baseline }
            guard let review = repository.record(id: prepared.manifest.id) else { throw Failure.baseline }
            _ = try await coordinator.activateFromLocalUI(reviewed: review, ttl: 120)
            let list = try await fetch(listURL, port: proxy.port)
            let object = try JSONSerialization.jsonObject(with: list) as? [String: Any]
            guard let item = (object?["items"] as? [[String: Any]])?.first,
                  let title = item["title"] as? String,
                  let detailAddress = item["detail"] as? String, detailAddress == detailURL.absoluteString,
                  let artworkAddress = item["image"] as? String,
                  let resolvedArtwork = URL(string: artworkAddress, relativeTo: base)?.absoluteURL,
                  resolvedArtwork == imageURL
                else { throw Failure.client }
            self.title = title
            let detailBytes = try await fetch(detailURL, port: proxy.port)
            let detailObject = try JSONSerialization.jsonObject(with: detailBytes) as? [String: Any]
            guard let detail = detailObject?["title"] as? String, detailObject?["id"] as? Int == 2,
                  detailObject?["image"] as? String == artworkAddress else { throw Failure.client }
            self.detail = detail
            let received = try await fetch(resolvedArtwork, port: proxy.port)
            guard received == png, let image = NSImage(data: received) else { throw Failure.client }
            self.image = image
            receivedPNG = received
            await recorder.waitForPendingStoreFlush()
            for _ in 0..<100 {
                receiptCount = gate.evidence(bundleID: prepared.manifest.id).receipts.filter {
                    $0.delivery == .downstreamWriteSucceeded && $0.matchesExpectedDelivery == true
                }.count
                if receiptCount >= 3 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard receiptCount == 3 else { throw Failure.receipts }
            _ = try await coordinator.stop(id: prepared.manifest.id)
            guard try await fetch(listURL, port: proxy.port) == baseline,
                  try await fetch(detailURL, port: proxy.port) == baselineDetail,
                  repository.record(id: prepared.manifest.id)?.isServing == false,
                  await rules.rules().isEmpty else { throw Failure.restoration }
            stopped = true
            status = "Baseline: 0 items · Mock: 1 item, detail and artwork · Stop: baseline restored"
        } catch {
            status = "Controlled journey failed: \(error)"
        }
        if let bundleID { _ = try? await coordinator.stop(id: bundleID) }
        await proxy.stop()
        await origin.stop()
        complete = stopped
    }

    private enum Failure: Error { case baseline, client, receipts, restoration, response }

    private func fetch(_ url: URL, port: UInt16) async throws -> Data {
        guard url.host == "127.0.0.1", let originPort = url.port else { throw Failure.client }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let timeout = DispatchWorkItem { connection.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        defer { timeout.cancel(); connection.cancel() }
        try await NetworkConnectionIO.start(connection, on: DispatchQueue(label: "mock.journey.client"))
        try await NetworkConnectionIO.send(Data(("GET \(url.absoluteString) HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(originPort)\r\nConnection: close\r\n\r\n").utf8), on: connection)
        var data = Data()
        while data.count < 3 * 1_024 * 1_024 {
            let (bytes, complete) = try await NetworkConnectionIO.receive(on: connection)
            data.append(bytes)
            if let split = data.range(of: Data("\r\n\r\n".utf8)) {
                let headers = String(decoding: data[..<split.lowerBound], as: UTF8.self)
                let length = headers.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }
                if let length, length >= 0, data.count - split.upperBound >= length {
                    guard headers.hasPrefix("HTTP/1.1 200") else { throw Failure.response }
                    return Data(data[split.upperBound..<split.upperBound + length])
                }
            }
            if complete { break }
        }
        throw Failure.response
    }
}

struct MockJourneyUITestView: View {
    @Environment(\.appTextScale) private var textScale
    @StateObject private var scenario = MockJourneyUITestScenario()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Controlled mock client").appFont(.headline, scale: textScale)
            Text(scenario.status).accessibilityIdentifier("mockJourneyStatus")
            Text("Rendered from the captured mock responses; retained here after Stop for review.")
            Text(scenario.title).accessibilityIdentifier("mockJourneyTitle")
            Text(scenario.detail).accessibilityIdentifier("mockJourneyDetail")
            if let image = scenario.image {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 240, height: 240)
                    .accessibilityLabel("Mock artwork received through the proxy")
                    .accessibilityIdentifier("mockJourneyArtwork")
            }
            if scenario.complete { Text("3 delivery receipts verified; test listeners stopped.").accessibilityIdentifier("mockJourneyComplete") }
        }.appFont(.body, scale: textScale).padding(24).frame(width: 760, height: 600)
            .background(UITestPrimaryScreenWindowConfigurator().frame(width: 0, height: 0))
            .task {
                guard let scope = try? RuntimeStorageScope.uiTest(environment: ProcessInfo.processInfo.environment) else { return }
                await scenario.run(root: scope.root)
            }
    }
}
