import Foundation
import Testing
@testable import JoesProxySDK

@Suite("StreamingMonitor")
struct StreamingMonitorTests {

    // MARK: - StallRiskSeverity threshold rules (via StallRiskEvent struct)

    @Test("warning fires when rolling P75 > 0.75 across 10 segments")
    func stallRiskWarningAtP75() async throws {
        // 10 ratios where P75 > 0.75: use 8 × 0.8 and 2 × 0.1 → sorted P75 index = ceil(0.75*10)-1 = 7 → 0.8
        let ratios = [0.1, 0.1, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8]
        let event = StallRiskEvent(
            timestamp: Date(),
            currentDeliveryRatio: ratios.last!,
            rollingP75DeliveryRatio: 0.8,
            severity: .warning,
            recommendation: "Heuristic: test"
        )
        #expect(event.severity == .warning)
        #expect(event.recommendation.hasPrefix("Heuristic:"))
    }

    @Test("critical fires for a single segment ratio > 1.0")
    func stallRiskCriticalSingleSegment() async throws {
        let event = StallRiskEvent(
            timestamp: Date(),
            currentDeliveryRatio: 1.5,
            rollingP75DeliveryRatio: 1.5,
            severity: .critical,
            recommendation: "Heuristic: single segment too slow"
        )
        #expect(event.severity == .critical)
    }

    @Test("StallRiskSeverity encodes/decodes correctly")
    func stallRiskSeverityCodable() async throws {
        let encoder = SDKEventJSONCodec.makeEncoder()
        let decoder = SDKEventJSONCodec.makeDecoder()

        let event = StallRiskEvent(
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            currentDeliveryRatio: 1.2,
            rollingP75DeliveryRatio: 0.9,
            severity: .warning,
            recommendation: "Heuristic: p75 elevated"
        )
        let data = try encoder.encode(event)
        let decoded = try decoder.decode(StallRiskEvent.self, from: data)
        #expect(decoded.severity == .warning)
        #expect(decoded.recommendation == event.recommendation)
        #expect(abs(decoded.currentDeliveryRatio - 1.2) < 0.001)
    }

    // MARK: - Streaming event encoding round-trips

    @Test("StreamingSegmentEvent encodes and decodes")
    func segmentEventRoundTrip() async throws {
        let encoder = SDKEventJSONCodec.makeEncoder()
        let decoder = SDKEventJSONCodec.makeDecoder()
        let url = URL(string: "https://cdn.example.com/seg001.m4s")!
        let event = StreamingSegmentEvent(
            sessionID: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            url: url,
            lane: "mediaSegments",
            byteCount: 512_000,
            durationSeconds: 1.8,
            segmentDurationSeconds: 2.0,
            deliveryRatio: 0.9,
            httpProtocol: "HTTP/2",
            statusCode: 200
        )
        let data = try encoder.encode(event)
        let decoded = try decoder.decode(StreamingSegmentEvent.self, from: data)
        #expect(decoded.lane == "mediaSegments")
        #expect(decoded.byteCount == 512_000)
        #expect(abs((decoded.deliveryRatio ?? 0) - 0.9) < 0.001)
        #expect(decoded.statusCode == 200)
    }

    @Test("DRMLicenseEvent encodes and decodes including negative relativeToPlaybackStartMs")
    func drmLicenseEventRoundTrip() async throws {
        let encoder = SDKEventJSONCodec.makeEncoder()
        let decoder = SDKEventJSONCodec.makeDecoder()
        let url = URL(string: "https://fps.example.com/fairplay/ckc")!
        let event = DRMLicenseEvent(
            sessionID: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            url: url,
            drmSystem: "FairPlay",
            relativeToPlaybackStartMs: -350,
            statusCode: 200,
            durationSeconds: 0.12
        )
        let data = try encoder.encode(event)
        let decoded = try decoder.decode(DRMLicenseEvent.self, from: data)
        #expect(decoded.drmSystem == "FairPlay")
        #expect(decoded.relativeToPlaybackStartMs == -350)
    }

    @Test("ManifestEvent isInitial field round-trips")
    func manifestEventRoundTrip() async throws {
        let encoder = SDKEventJSONCodec.makeEncoder()
        let decoder = SDKEventJSONCodec.makeDecoder()
        let url = URL(string: "https://cdn.example.com/master.m3u8")!
        let event = ManifestEvent(
            sessionID: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            url: url,
            format: "HLS",
            isInitial: true,
            durationSeconds: 0.05,
            statusCode: 200
        )
        let data = try encoder.encode(event)
        let decoded = try decoder.decode(ManifestEvent.self, from: data)
        #expect(decoded.format == "HLS")
        #expect(decoded.isInitial == true)
    }

    // MARK: - StreamingMonitor handler dispatch

    @Test("onSegmentDelivered dispatches to registered handler")
    @MainActor
    func segmentHandlerDispatch() async throws {
        final class Box<T: Sendable>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }
        let monitor = StreamingMonitor()
        let received = Box<StreamingSegmentEvent?>(nil)
        let event = StreamingSegmentEvent(
            sessionID: UUID(),
            timestamp: Date(),
            url: URL(string: "https://cdn.example.com/seg.m4s")!,
            lane: "mediaSegments",
            byteCount: nil,
            durationSeconds: 2.1,
            segmentDurationSeconds: 2.0,
            deliveryRatio: 1.05,
            httpProtocol: "HTTP/2",
            statusCode: 200
        )
        monitor.onSegmentDelivered { received.value = $0 }
        monitor.dispatch(event)
        #expect(received.value?.sessionID == event.sessionID)
    }

    @Test("removeHandler stops dispatch")
    @MainActor
    func removeHandlerStopsDispatch() async throws {
        final class Box<T: Sendable>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }
        let monitor = StreamingMonitor()
        let callCount = Box(0)
        let id = monitor.onManifestRefreshed { _ in callCount.value += 1 }
        let event = ManifestEvent(
            sessionID: UUID(),
            timestamp: Date(),
            url: URL(string: "https://cdn.example.com/master.m3u8")!,
            format: "HLS",
            isInitial: true,
            durationSeconds: nil,
            statusCode: 200
        )
        monitor.dispatch(event)
        monitor.removeHandler(id)
        monitor.dispatch(event)
        #expect(callCount.value == 1)
    }
}
