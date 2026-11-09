import Combine
import Foundation

/// Holds the optional Inspector presentation graph for the full application target.
///
/// Constructing this host is deliberately cheap. Agent launches retain only the host until a
/// person explicitly chooses the Inspector route; shared runtime work must not call `loadInspector`.
@MainActor
final class InspectorWorkspaceHost: ObservableObject {
    private let coordinator: AppCoordinator
    private var inspectorChangeObservation: AnyCancellable?
    @Published private(set) var isInspectorRequested = false
    @Published private(set) var isAgentRequested = false
    @Published private(set) var transitionFailure: String?
    @Published private(set) var activeWorkspace: LaunchWorkspacePreference
    private var isTransitioning = false

    init(coordinator: AppCoordinator, forceAgent: Bool = false) {
        self.coordinator = coordinator
        // Resolve once. Editing the next-launch preference must not tear down a live workspace.
        activeWorkspace = forceAgent ? .agent : coordinator.configuration.launchWorkspacePreference
    }

    func loadInspector() -> ProxyViewModel {
        let inspector = coordinator.viewModel
        if inspectorChangeObservation == nil {
            inspectorChangeObservation = inspector.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
        return inspector
    }

    func openInspector() {
        guard !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        _ = loadInspector()
        transitionFailure = nil
        isAgentRequested = false
        isInspectorRequested = true
        activeWorkspace = .inspector
    }

    @discardableResult
    func returnToAgent(presentationBlocked: Bool = false) -> Bool {
        guard !isTransitioning else { return false }
        isTransitioning = true
        defer { isTransitioning = false }
        guard !presentationBlocked else {
            transitionFailure = "Finish or close the open Inspector editor before switching workspaces."
            return false
        }
        if let failure = coordinator.releaseInspector() {
            transitionFailure = failure
            return false
        }
        inspectorChangeObservation = nil
        transitionFailure = nil
        isInspectorRequested = false
        isAgentRequested = true
        activeWorkspace = .agent
        return true
    }
}
