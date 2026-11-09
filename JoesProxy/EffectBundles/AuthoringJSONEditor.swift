import SwiftUI
import AppKit

/// Literal JSON input must not inherit prose substitutions from the user's text settings.
struct AuthoringJSONEditor: NSViewRepresentable {
    @Binding var text: String
    let label: String
    let identifier: String
    @Environment(\.appTextScale) private var textScale
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = Self.makeEditor()
        editor.delegate = context.coordinator
        scroll.documentView = editor
        updateNSView(scroll, context: context)
        return scroll
    }

    static func makeEditor() -> NSTextView {
        let editor = NSTextView()
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 5, height: 5)
        return editor
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        if editor.string != text { editor.string = text }
        editor.font = .monospacedSystemFont(ofSize: AppFontRole.body.pointSize * textScale, weight: .regular)
        editor.textColor = isEnabled ? .textColor : .disabledControlTextColor
        editor.isEditable = isEnabled
        editor.setAccessibilityLabel(label)
        editor.setAccessibilityIdentifier(identifier)
        editor.setAccessibilityHelp("Enter literal JSON. Tab moves to the next control; Shift-Tab moves to the previous control.")
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let window = textView.window else { return false }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                window.selectNextKeyView(textView)
                return true
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                window.selectPreviousKeyView(textView)
                return true
            }
            return false
        }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
        }
    }
}
