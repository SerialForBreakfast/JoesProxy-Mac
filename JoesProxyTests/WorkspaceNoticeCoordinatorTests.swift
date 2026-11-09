import XCTest
@testable import JoesProxy

@MainActor
final class WorkspaceNoticeCoordinatorTests: XCTestCase {
    func testDismissalCannotMasqueradeAsRecovery() {
        let coordinator = WorkspaceNoticeCoordinator()
        let notice = WorkspacePersistentNotice(id: "persistence", title: "Recovery needs attention",
            message: "Storage unavailable", severity: .blocking, actionID: "storage",
            actionTitle: "Review recovery", isDismissible: false)
        coordinator.present(notice)
        coordinator.dismissPersistentNotice(id: notice.id)
        XCTAssertEqual(coordinator.highestPriorityNotice, notice)
        XCTAssertEqual(coordinator.highestPriorityNotice?.actionID, "storage")
    }

    func testBlockingNoticeWinsPriority() {
        let coordinator = WorkspaceNoticeCoordinator()
        coordinator.present(
            WorkspacePersistentNotice(
                id: "advisory",
                title: "Advisory",
                message: "Review this later.",
                severity: .advisory
            )
        )
        coordinator.present(
            WorkspacePersistentNotice(
                id: "blocking",
                title: "Blocked",
                message: "Action is required.",
                severity: .blocking
            )
        )

        XCTAssertEqual(coordinator.highestPriorityNotice?.id, "blocking")
    }

    func testPersistentNoticeWithSameIDIsReplaced() {
        let coordinator = WorkspaceNoticeCoordinator()
        coordinator.present(
            WorkspacePersistentNotice(id: "same", title: "First", message: "One", severity: .advisory)
        )
        coordinator.present(
            WorkspacePersistentNotice(id: "same", title: "Second", message: "Two", severity: .blocking)
        )

        XCTAssertEqual(coordinator.persistentNotices.count, 1)
        XCTAssertEqual(coordinator.highestPriorityNotice?.title, "Second")
    }

    func testDuplicateToastDoesNotReplaceCurrentToast() {
        let coordinator = WorkspaceNoticeCoordinator()
        coordinator.presentToast("Done", duration: .seconds(60))
        let firstID = coordinator.toast?.id
        coordinator.presentToast("Done", duration: .seconds(60))

        XCTAssertEqual(coordinator.toast?.id, firstID)
        coordinator.dismissToast()
    }
}
