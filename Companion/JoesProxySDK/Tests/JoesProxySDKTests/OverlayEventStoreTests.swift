#if DEBUG
import Foundation
import Testing
@testable import JoesProxySDK
import ProxySDKTesting

@Suite("OverlayEventStore")
struct OverlayEventStoreTests {

    // MARK: - Ring buffer

    @Test("ring buffer caps at 50 events, newest first")
    @MainActor
    func ringBufferCapacity() async throws {
        let store = OverlayEventStore()
        let events = (0..<51).map { i in
            NetworkEventFixture.make(
                url: URL(string: "https://api.example.com/v\(i)")!,
                timestamp: Date(timeIntervalSince1970: Double(i))
            )
        }
        for event in events { store.appendEvent(event) }

        #expect(store.events.count == 50)
        // Most recently appended (index 50, url /v50) should be first
        #expect(store.events.first?.url.path == "/v50")
        // Oldest (v0) should have been evicted
        #expect(store.events.contains(where: { $0.url.path == "/v0" }) == false)
    }

    // MARK: - Auth cascade detection

    @Test("detects cascade: 401 + 2 same-host events within 200ms")
    @MainActor
    func authCascadeDetected() async throws {
        let store = OverlayEventStore()
        let host = "api.example.com"
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // 401 trigger
        let trigger = NetworkEventFixture.make(
            url: URL(string: "https://\(host)/auth")!,
            statusCode: 401,
            timestamp: t0
        )
        // Two cascade events within 150 ms
        let follow1 = NetworkEventFixture.make(
            url: URL(string: "https://\(host)/data1")!,
            statusCode: 200,
            timestamp: t0.addingTimeInterval(0.1)
        )
        let follow2 = NetworkEventFixture.make(
            url: URL(string: "https://\(host)/data2")!,
            statusCode: 200,
            timestamp: t0.addingTimeInterval(0.15)
        )

        store.appendEvent(follow2)
        store.appendEvent(follow1)
        store.appendEvent(trigger)

        #expect(store.authCascadeGroups.count == 1)
        let group = store.authCascadeGroups[0]
        #expect(group.trigger.id == trigger.id)
        #expect(group.cascade.count == 2)
        #expect(group.holdDurationMs == 100)
    }

    @Test("no cascade when follow-up events are beyond 200ms window")
    @MainActor
    func authCascadeNotDetectedOutsideWindow() async throws {
        let store = OverlayEventStore()
        let host = "api.example.com"
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        let trigger = NetworkEventFixture.make(
            url: URL(string: "https://\(host)/auth")!,
            statusCode: 401,
            timestamp: t0
        )
        let late1 = NetworkEventFixture.make(
            url: URL(string: "https://\(host)/data1")!,
            statusCode: 200,
            timestamp: t0.addingTimeInterval(0.25)   // beyond 200ms window
        )
        let late2 = NetworkEventFixture.make(
            url: URL(string: "https://\(host)/data2")!,
            statusCode: 200,
            timestamp: t0.addingTimeInterval(0.30)
        )

        store.appendEvent(late2)
        store.appendEvent(late1)
        store.appendEvent(trigger)

        #expect(store.authCascadeGroups.isEmpty)
    }

    // MARK: - Third-party summary

    @Test("third-party summary groups by sourceSDK")
    @MainActor
    func thirdPartySummary() async throws {
        let store = OverlayEventStore()

        for _ in 0..<3 {
            store.appendEvent(NetworkEventFixture.make(sourceSDK: "Firebase"))
        }
        store.appendEvent(NetworkEventFixture.make(sourceSDK: "Amplitude"))
        store.appendEvent(NetworkEventFixture.make(sourceSDK: nil))   // first-party, not counted

        let summary = store.thirdPartySummary
        #expect(summary["Firebase"] == 3)
        #expect(summary["Amplitude"] == 1)
        #expect(summary.count == 2)
    }
}
#endif
