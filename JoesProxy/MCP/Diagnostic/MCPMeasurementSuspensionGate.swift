import Foundation

/// Thread-safe flag read from the proxy capture path while a clean measurement is active.
///
/// Concurrency: lock-protected; safe to read from NIO event loops and write from `@MainActor` UI.
enum MCPMeasurementSuspensionGate {
    private static let lock = NSLock()
    private static var _isActive = false
    private static var _diagnosticLabel: String?

    /// When true, captured responses receive `measurementContext = .effectsSuspended`.
    static var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isActive
    }

    /// Human-readable diagnostic label shown on exports during suspension.
    static var diagnosticLabel: String? {
        lock.lock()
        defer { lock.unlock() }
        return _diagnosticLabel
    }

    static func activate(diagnosticLabel: String) {
        lock.lock()
        _isActive = true
        _diagnosticLabel = diagnosticLabel
        lock.unlock()
    }

    static func deactivate() {
        lock.lock()
        _isActive = false
        _diagnosticLabel = nil
        lock.unlock()
    }
}
