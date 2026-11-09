import Foundation

struct SDKAnnotation: Equatable, Sendable, Identifiable {
    let id: UUID
    let scopeID: UUID?
    let label: String
    let kind: AnnotationKind
    let lifecycle: AnnotationLifecycle
    let metadata: [String: String]
    let deviceTimestamp: Date
    let macTimestamp: Date
    let endedAt: Date?
}

actor SDKAnnotationStore {
    private var annotations: [SDKAnnotation] = []
    private var openWindowIndexesByScopeID: [UUID: Int] = [:]

    var allAnnotations: [SDKAnnotation] {
        annotations
    }

    func add(_ event: AnnotationEvent, clockOffsetMs: Int) {
        let macTimestamp = event.deviceTimestamp.addingTimeInterval(Double(clockOffsetMs) / 1_000)

        switch event.lifecycle {
        case .instant:
            annotations.append(annotation(from: event, macTimestamp: macTimestamp, endedAt: nil))

        case .begin:
            let annotation = annotation(from: event, macTimestamp: macTimestamp, endedAt: nil)
            annotations.append(annotation)
            if let scopeID = event.scopeID {
                openWindowIndexesByScopeID[scopeID] = annotations.count - 1
            }

        case .end:
            closeWindow(for: event, macTimestamp: macTimestamp)
            annotations.append(annotation(from: event, macTimestamp: macTimestamp, endedAt: nil))
        }
    }

    func activeLabels(at date: Date) -> [String] {
        annotations
            .filter { annotation in
                guard annotation.lifecycle == .begin else {
                    return false
                }

                guard annotation.macTimestamp <= date else {
                    return false
                }

                if let endedAt = annotation.endedAt {
                    return date <= endedAt
                }

                return true
            }
            .map(\.label)
    }

    /// Nearest `.playbackStart` annotation to `date`, in either direction. Used to compute
    /// `DRMLicenseEvent.relativeToPlaybackStartMs`, which is negative when the license request
    /// precedes the playback-start marker — the common case for pre-fetched licenses.
    func nearestPlaybackStart(to date: Date) -> Date? {
        annotations
            .filter { $0.kind == .playbackStart }
            .min { abs($0.macTimestamp.timeIntervalSince(date)) < abs($1.macTimestamp.timeIntervalSince(date)) }?
            .macTimestamp
    }

    func clear() {
        annotations.removeAll()
        openWindowIndexesByScopeID.removeAll()
    }

    private func closeWindow(for event: AnnotationEvent, macTimestamp: Date) {
        guard let scopeID = event.scopeID,
              let index = openWindowIndexesByScopeID.removeValue(forKey: scopeID),
              annotations.indices.contains(index) else {
            return
        }

        let openAnnotation = annotations[index]
        annotations[index] = SDKAnnotation(
            id: openAnnotation.id,
            scopeID: openAnnotation.scopeID,
            label: openAnnotation.label,
            kind: openAnnotation.kind,
            lifecycle: openAnnotation.lifecycle,
            metadata: openAnnotation.metadata,
            deviceTimestamp: openAnnotation.deviceTimestamp,
            macTimestamp: openAnnotation.macTimestamp,
            endedAt: macTimestamp
        )
    }

    private func annotation(
        from event: AnnotationEvent,
        macTimestamp: Date,
        endedAt: Date?
    ) -> SDKAnnotation {
        SDKAnnotation(
            id: event.id,
            scopeID: event.scopeID,
            label: event.label,
            kind: event.kind,
            lifecycle: event.lifecycle,
            metadata: event.metadata,
            deviceTimestamp: event.deviceTimestamp,
            macTimestamp: macTimestamp,
            endedAt: endedAt
        )
    }
}
