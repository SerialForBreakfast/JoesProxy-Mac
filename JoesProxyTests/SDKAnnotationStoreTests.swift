import Foundation
import XCTest
@testable import JoesProxy

final class SDKAnnotationStoreTests: XCTestCase {
    func testBeginAndEndWindowProducesActiveLabelOnlyInsideAdjustedRange() async {
        let store = SDKAnnotationStore()
        let scopeID = UUID()
        let deviceStart = Date(timeIntervalSinceReferenceDate: 100)
        let deviceEnd = Date(timeIntervalSinceReferenceDate: 110)

        await store.add(
            makeAnnotation(
                scopeID: scopeID,
                label: "Home",
                lifecycle: .begin,
                deviceTimestamp: deviceStart
            ),
            clockOffsetMs: 2_000
        )
        await store.add(
            makeAnnotation(
                scopeID: scopeID,
                label: "Home",
                lifecycle: .end,
                deviceTimestamp: deviceEnd
            ),
            clockOffsetMs: 2_000
        )

        let before = await store.activeLabels(at: Date(timeIntervalSinceReferenceDate: 101.9))
        let during = await store.activeLabels(at: Date(timeIntervalSinceReferenceDate: 105))
        let after = await store.activeLabels(at: Date(timeIntervalSinceReferenceDate: 112.1))

        XCTAssertEqual(before, [])
        XCTAssertEqual(during, ["Home"])
        XCTAssertEqual(after, [])
    }

    func testInstantAnnotationIsStoredButNotActiveWindowLabel() async throws {
        let store = SDKAnnotationStore()
        let timestamp = Date(timeIntervalSinceReferenceDate: 200)

        await store.add(
            makeAnnotation(
                scopeID: nil,
                label: "Playback Start",
                lifecycle: .instant,
                deviceTimestamp: timestamp
            ),
            clockOffsetMs: 500
        )

        let annotations = await store.allAnnotations
        let annotation = try XCTUnwrap(annotations.first)
        let activeLabels = await store.activeLabels(at: timestamp.addingTimeInterval(0.5))

        XCTAssertEqual(annotation.label, "Playback Start")
        XCTAssertEqual(annotation.macTimestamp, timestamp.addingTimeInterval(0.5))
        XCTAssertEqual(activeLabels, [])
    }

    func testClearRemovesAnnotationsAndOpenWindows() async {
        let store = SDKAnnotationStore()
        let scopeID = UUID()
        await store.add(
            makeAnnotation(
                scopeID: scopeID,
                label: "Checkout",
                lifecycle: .begin,
                deviceTimestamp: Date(timeIntervalSinceReferenceDate: 300)
            ),
            clockOffsetMs: 0
        )

        await store.clear()

        let annotations = await store.allAnnotations
        let activeLabels = await store.activeLabels(at: Date(timeIntervalSinceReferenceDate: 301))

        XCTAssertEqual(annotations, [])
        XCTAssertEqual(activeLabels, [])
    }

    private func makeAnnotation(
        scopeID: UUID?,
        label: String,
        lifecycle: AnnotationLifecycle,
        deviceTimestamp: Date
    ) -> AnnotationEvent {
        AnnotationEvent(
            id: UUID(),
            scopeID: scopeID,
            label: label,
            kind: .screen,
            lifecycle: lifecycle,
            metadata: [:],
            deviceTimestamp: deviceTimestamp
        )
    }
}
