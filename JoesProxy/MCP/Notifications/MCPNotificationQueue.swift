import Foundation

/// Per-session bounded notification queue with coalescing and cross-category backpressure.
struct MCPNotificationQueue: Sendable {
    private(set) var events: [MCPNotificationEvent] = []
    private(set) var accumulatedDroppedCount = 0
    let capacity: Int

    init(capacity: Int = MCPServerLimits.maxNotificationQueueEvents) {
        self.capacity = capacity
    }

    mutating func enqueue(_ event: MCPNotificationEvent) {
        applySameOperationTerminalReplacement(for: event)
        if coalesceCaptureUpdate(for: event) {
            return
        }
        if events.count >= capacity {
            dropLowestPriorityEvent()
            accumulatedDroppedCount += 1
        }
        events.append(event)
    }

    mutating func drain() -> [MCPNotificationEvent] {
        let drained = events
        events = []
        return drained
    }

    /// Atomically reads and clears the accumulated drop count. Every call site that embeds
    /// `droppedEventCount` in an outbound event must go through this (not a plain read of
    /// `accumulatedDroppedCount`), or the same historical drop gets re-reported on every later
    /// notification instead of exactly once.
    mutating func takeDroppedCount() -> Int {
        defer { accumulatedDroppedCount = 0 }
        return accumulatedDroppedCount
    }

    private mutating func applySameOperationTerminalReplacement(for event: MCPNotificationEvent) {
        guard case .operationUpdated(let operationID, _, true) = event else { return }
        events.removeAll {
            if case .operationUpdated(let pendingID, _, false) = $0 {
                return pendingID == operationID
            }
            return false
        }
    }

    private mutating func coalesceCaptureUpdate(for event: MCPNotificationEvent) -> Bool {
        guard case .resourceUpdated(let uri, let incomingDropped) = event else { return false }
        guard let index = events.firstIndex(where: {
            if case .resourceUpdated(let existingURI, _) = $0 {
                return existingURI == uri
            }
            return false
        }) else {
            return false
        }
        if case .resourceUpdated(_, let existingDropped) = events[index] {
            events[index] = .resourceUpdated(
                uri: uri,
                droppedEventCount: existingDropped + incomingDropped + accumulatedDroppedCount
            )
            accumulatedDroppedCount = 0
        }
        return true
    }

    private mutating func dropLowestPriorityEvent() {
        guard !events.isEmpty else { return }
        var lowestIndex = 0
        var lowestPriority = events[0].priority
        for index in events.indices.dropFirst() {
            if events[index].priority < lowestPriority {
                lowestPriority = events[index].priority
                lowestIndex = index
            }
        }
        events.remove(at: lowestIndex)
    }
}
