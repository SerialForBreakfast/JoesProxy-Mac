import Combine
import Foundation

enum WorkspaceNoticeSeverity: Int, Comparable, Sendable {
    case advisory
    case blocking

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct WorkspacePersistentNotice: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let message: String
    let severity: WorkspaceNoticeSeverity
    var actionID: String? = nil
    var actionTitle: String? = nil
    var isDismissible: Bool = true
}

struct WorkspaceToast: Identifiable, Equatable, Sendable {
    let id: UUID
    let message: String

    init(message: String, id: UUID = UUID()) {
        self.id = id
        self.message = message
    }
}

/// Bounded, presentation-only notice state for the main workspace.
@MainActor
final class WorkspaceNoticeCoordinator: ObservableObject {
    @Published private(set) var persistentNotices: [WorkspacePersistentNotice] = []
    @Published private(set) var toast: WorkspaceToast?

    private var toastDismissalTask: Task<Void, Never>?

    var highestPriorityNotice: WorkspacePersistentNotice? {
        persistentNotices.max {
            if $0.severity != $1.severity { return $0.severity < $1.severity }
            return $0.id > $1.id
        }
    }

    func present(_ notice: WorkspacePersistentNotice) {
        persistentNotices.removeAll { $0.id == notice.id }
        persistentNotices.append(notice)
    }

    func dismissPersistentNotice(id: String) {
        guard persistentNotices.first(where: { $0.id == id })?.isDismissible != false else { return }
        persistentNotices.removeAll { $0.id == id }
    }

    func presentToast(_ message: String, duration: Duration = .seconds(3)) {
        guard toast?.message != message else { return }
        toastDismissalTask?.cancel()
        let presented = WorkspaceToast(message: message)
        toast = presented
        toastDismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, self?.toast?.id == presented.id else { return }
            self?.toast = nil
        }
    }

    func dismissToast() {
        toastDismissalTask?.cancel()
        toastDismissalTask = nil
        toast = nil
    }
}
