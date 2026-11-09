import SwiftUI

enum UtilityWindowKind: String {
    case about = "about-joesproxy"
    case mcpManagement = "mcp-management"
    case approvals = "mcp-approvals"
}

struct UtilityWindowRequest: Equatable {
    let id = UUID()
    let kind: UtilityWindowKind
}

/// App-owned panels do not depend on the full capture workspace being mounted.
struct UtilityWindowView: View {
    let kind: UtilityWindowKind
    @ObservedObject var presentation: AppPresentationState
    @ObservedObject var controller: MCPServerController
    @ObservedObject var validation: MCPSelfValidationCoordinator
    @ObservedObject var compact: CompactModeController
    let textScale: CGFloat
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch kind {
            case .about:
                AboutView(isPresented: Binding(get: { true }, set: { shown in
                    if !shown { dismiss() }
                }))
            case .mcpManagement:
                MCPManagementView(controller: controller, selfValidationCoordinator: validation,
                    textScale: textScale,
                    initialDestination: presentation.mcpManagementContext?.destination ?? .overview,
                    navigationRequestID: presentation.mcpManagementContext?.id)
            case .approvals:
                MCPCompactApprovalSheet(controller: controller, onDismiss: { dismiss() })
            }
        }
        .environment(\.appTextScale, textScale)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("utilityWindow-\(kind.rawValue)")
        .background(UtilityWindowLevel(isFloating: compact.isCompactModeActive && compact.isPinnedToForeground))
        .onDisappear {
            if kind == .about { presentation.isAboutPresented = false }
            if kind == .approvals { presentation.isCompactApprovalsPresented = false }
        }
    }
}

private struct UtilityWindowLevel: NSViewRepresentable {
    let isFloating: Bool

    final class WindowObserver: NSView {
        var level: NSWindow.Level = .normal {
            didSet { window?.level = level }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.level = level
        }
    }

    func makeNSView(context: Context) -> WindowObserver { WindowObserver() }
    func updateNSView(_ view: WindowObserver, context: Context) {
        view.level = isFloating ? .floating : .normal
    }
}
