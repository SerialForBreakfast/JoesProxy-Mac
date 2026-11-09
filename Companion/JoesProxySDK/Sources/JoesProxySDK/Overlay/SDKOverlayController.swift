#if os(iOS) && DEBUG
import SwiftUI
import UIKit

/// Manages the debug overlay UIWindow and the 3-finger long-press activation gesture.
@MainActor
final class SDKOverlayController {
    private var window: UIWindow?
    private var gestureRecognizer: UIGestureRecognizer?

    var isVisible: Bool { window != nil }

    /// Registers the long-press activation gesture on the app's key window and
    /// begins collecting events from `OverlayEventStore.shared`.
    func activate() {
        OverlayEventStore.shared.startCollecting()

        guard let keyWindow = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else { return }

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.numberOfTouchesRequired = 3
        longPress.minimumPressDuration = 1.0
        keyWindow.addGestureRecognizer(longPress)
        gestureRecognizer = longPress
    }

    func show() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene })
                  .first(where: { $0.activationState == .foregroundActive }) else { return }

        let hostingController = UIHostingController(rootView: OverlayRootView())
        hostingController.view.backgroundColor = .clear

        let w = UIWindow(windowScene: scene)
        w.windowLevel = .statusBar + 1
        w.rootViewController = hostingController
        w.isHidden = false
        w.alpha = 0
        UIView.animate(withDuration: 0.25) { w.alpha = 1 }
        window = w
    }

    func hide() {
        guard let w = window else { return }
        UIView.animate(withDuration: 0.2) {
            w.alpha = 0
        } completion: { _ in
            w.isHidden = true
            self.window = nil
        }
    }

    @objc private func handleLongPress(_ gr: UIGestureRecognizer) {
        guard gr.state == .began else { return }
        show()
    }
}
#endif
