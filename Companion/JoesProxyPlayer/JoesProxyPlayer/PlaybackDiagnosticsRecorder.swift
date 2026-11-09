//
//  PlaybackDiagnosticsRecorder.swift
//  JoesProxyPlayer
//
/// Collects AVMetric / KVO playback diagnostics and POSTs batches to the active fixture host
/// diagnostic path so JoesProxy capture records the probe side of a trial.
///

import AVFoundation
import Foundation

/// One structured diagnostic event emitted by JoePlayer.
struct JoePlayerDiagnosticEvent: Codable, Equatable, Sendable {
    let timestamp: Date
    let kind: String
    let detail: String
}

/// Batches diagnostic events and POSTs them to `/joeplayer/v1/events` on the stream host.
///
/// Concurrency: `@MainActor` for player observation; network POSTs use `URLSession` and must not
/// block the main actor beyond fire-and-forget `Task` scheduling.
@MainActor
final class PlaybackDiagnosticsRecorder: NSObject {
    private(set) var events: [JoePlayerDiagnosticEvent] = []
    private var statusObservation: NSKeyValueObservation?
    private var errorObservation: NSKeyValueObservation?
    private var metricTasks: [Task<Void, Never>] = []
    private var streamURL: URL?
    private let session: URLSession

    /// Creates a recorder.
    /// - Parameter session: Injected for tests; defaults to shared session.
    init(session: URLSession = .shared) {
        self.session = session
        super.init()
    }

    /// Begins observing `item` and remembering the fixture origin for diagnostic POSTs.
    func attach(to item: AVPlayerItem, streamURL: URL) {
        detach()
        self.streamURL = streamURL
        record(kind: "attach", detail: streamURL.absoluteString)

        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.record(kind: "itemStatus", detail: "\(observedItem.status.rawValue)")
                if let error = observedItem.error {
                    self.record(kind: "itemError", detail: error.localizedDescription)
                }
            }
        }
        errorObservation = item.observe(\.error, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor [weak self] in
                guard let self, let error = observedItem.error else { return }
                self.record(kind: "itemError", detail: error.localizedDescription)
            }
        }

        if #available(iOS 18.0, *) {
            startMetricStreams(for: item)
        }
    }

    /// Stops observers and cancels metric streaming.
    func detach() {
        statusObservation?.invalidate()
        errorObservation?.invalidate()
        statusObservation = nil
        errorObservation = nil
        metricTasks.forEach { $0.cancel() }
        metricTasks.removeAll()
    }

    /// Appends a diagnostic event and schedules a flush POST.
    func record(kind: String, detail: String) {
        let event = JoePlayerDiagnosticEvent(timestamp: Date(), kind: kind, detail: detail)
        events.append(event)
        Task { await flushLatest() }
    }

    /// POSTs the full event list to the diagnostic ingestion path on the stream host.
    func flushLatest() async {
        guard let streamURL,
              var components = URLComponents(url: streamURL, resolvingAgainstBaseURL: false) else {
            return
        }
        components.path = JoePlayerDiagnosticRoute.eventsPath
        components.query = nil
        guard let endpoint = components.url else { return }

        do {
            let body = try JSONEncoder().encode(events)
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                recordLocalOnly(kind: "diagPOST", detail: "status=\(http.statusCode)")
            }
        } catch {
            recordLocalOnly(kind: "diagPOSTError", detail: error.localizedDescription)
        }
    }

    private func recordLocalOnly(kind: String, detail: String) {
        events.append(JoePlayerDiagnosticEvent(timestamp: Date(), kind: kind, detail: detail))
    }

    @available(iOS 18.0, *)
    private func startMetricStreams(for item: AVPlayerItem) {
        let segmentMetrics = item.metrics(forType: AVMetricHLSMediaSegmentRequestEvent.self)
        metricTasks.append(Task { [weak self] in
            do {
                for try await event in segmentMetrics {
                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        self?.record(kind: "metricSegment", detail: String(describing: event))
                    }
                }
            } catch {
                await MainActor.run {
                    self?.record(kind: "metricSegmentError", detail: error.localizedDescription)
                }
            }
        })

        let switchMetrics = item.metrics(forType: AVMetricPlayerItemVariantSwitchEvent.self)
        metricTasks.append(Task { [weak self] in
            do {
                for try await event in switchMetrics {
                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        self?.record(kind: "metricVariantSwitch", detail: String(describing: event))
                    }
                }
            } catch {
                await MainActor.run {
                    self?.record(kind: "metricVariantSwitchError", detail: error.localizedDescription)
                }
            }
        })
    }
}

/// Shared path constants for JoePlayer → JoesProxy diagnostic ingestion.
enum JoePlayerDiagnosticRoute {
    /// Path POSTed on the active fixture reserved host.
    static let eventsPath = "/joeplayer/v1/events"
}
