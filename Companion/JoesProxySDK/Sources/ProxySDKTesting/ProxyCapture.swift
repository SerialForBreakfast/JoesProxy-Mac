import Foundation
import JoesProxySDK

/// Collects network events from ProxySDK during a bounded test window.
///
/// Create via `ProxySDK.shared.startCapture(label:)` in `setUp`, then call `end()` in `tearDown`
/// or at the assertion site. All assertions on `ProxyCapture` are no-ops when no proxy is connected.
///
/// - Note: Thread-safe via internal locking. Designed for use in `@MainActor` test suites but
///   safe to call `end()` from any context.
public final class ProxyCapture: @unchecked Sendable {
    public let label: String
    public let captureStart: Date

    private let box: EventBox
    private weak var sdk: ProxySDK?
    private let handlerID: UUID

    init(label: String, sdk: ProxySDK?, handlerID: UUID, box: EventBox) {
        self.label = label
        self.captureStart = Date()
        self.sdk = sdk
        self.handlerID = handlerID
        self.box = box
    }

    /// Creates a `ProxyCapture` pre-populated with a fixed event list, with no live proxy connection.
    ///
    /// Use this in unit tests to exercise assertion logic without a running proxy:
    /// ```swift
    /// let cap = ProxyCapture.makeFixture(events: [
    ///     NetworkEventFixture.make(cacheStatus: .hit),
    /// ])
    /// try cap.assertCDNHit(matching: "cdn.")
    /// ```
    public static func makeFixture(label: String = "test", events: [NetworkEvent]) -> ProxyCapture {
        let box = EventBox()
        for event in events { box.append(event) }
        return ProxyCapture(label: label, sdk: nil, handlerID: UUID(), box: box)
    }

    /// Snapshot of events collected so far. Safe to access before calling `end()`.
    public var capturedEvents: [NetworkEvent] {
        box.captured
    }

    /// Stops collecting events and returns the full captured array.
    ///
    /// Safe to call multiple times; subsequent calls return the same frozen array.
    @discardableResult
    public func end() -> [NetworkEvent] {
        let events = box.finish()
        Task { @MainActor [weak sdk, handlerID] in
            sdk?.removeNetworkEventHandler(handlerID)
        }
        return events
    }

    /// Returns a `DiagnosticReport` snapshot computed from the events captured so far.
    ///
    /// Call after `end()` for the complete picture, or before `end()` for a mid-capture snapshot.
    public func diagnosticReport() -> DiagnosticReport {
        DiagnosticReport(
            label: label,
            captureStart: captureStart,
            captureEnd: box.endedAt ?? Date(),
            events: box.captured
        )
    }
}

// MARK: - ProxySDK extension

@MainActor
extension ProxySDK {
    /// Begins collecting network events under the given label.
    ///
    /// Register in `setUp`, call `end()` in `tearDown`, run assertions between:
    /// ```swift
    /// override func setUp() async throws {
    ///     capture = ProxySDK.shared.startCapture(label: "CheckoutFlow")
    /// }
    /// override func tearDown() async throws {
    ///     capture.end()
    /// }
    /// ```
    public func startCapture(label: String) -> ProxyCapture {
        let box = EventBox()
        let id = onNetworkEvent { event in
            box.append(event)
        }
        return ProxyCapture(label: label, sdk: self, handlerID: id, box: box)
    }
}

// MARK: - Internal event box

/// Internal append-only store with a lock; satisfies @Sendable handler requirement.
final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [NetworkEvent] = []
    private var _ended = false
    private var _endedAt: Date?

    func append(_ event: NetworkEvent) {
        lock.withLock {
            guard !_ended else { return }
            _events.append(event)
        }
    }

    /// Freezes the store and returns the captured array.
    func finish() -> [NetworkEvent] {
        lock.withLock {
            if !_ended {
                _ended = true
                _endedAt = Date()
            }
            return _events
        }
    }

    var captured: [NetworkEvent] {
        lock.withLock { _events }
    }

    var endedAt: Date? {
        lock.withLock { _endedAt }
    }
}
