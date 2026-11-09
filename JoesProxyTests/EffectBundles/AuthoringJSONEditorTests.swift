import XCTest
import SwiftUI
import AppKit
@testable import JoesProxy

@MainActor
final class AuthoringJSONEditorTests: XCTestCase {
    func testLiteralPasteAndReadonlyPreserveBinding() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = AuthoringJSONEditor.makeEditor()
        editor.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        window.contentView?.addSubview(editor)
        var value = #"{"title":"Before"}"#
        let coordinator = AuthoringJSONEditor.Coordinator(text: Binding(get: { value }, set: { value = $0 }))
        editor.delegate = coordinator
        editor.string = value
        XCTAssertTrue(window.makeFirstResponder(editor))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let pasted = "{\n  \"title\": \"Literal -- quotes\",\n  \"count\": 2\n}"
        pasteboard.setString(pasted, forType: .string)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertTrue(editor.readSelection(from: pasteboard, type: .string))
        XCTAssertEqual(editor.string, pasted)
        XCTAssertEqual(value, pasted)
        XCTAssertFalse(editor.isRichText)
        XCTAssertFalse(editor.isAutomaticQuoteSubstitutionEnabled)
        editor.isEditable = false
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        pasteboard.clearContents()
        pasteboard.setString("overwrite", forType: .string)
        _ = editor.readSelection(from: pasteboard, type: .string)
        XCTAssertEqual(value, pasted, "A prepared read-only editor must reject paste")
        XCTAssertFalse(window.isVisible)
    }

    func testTabAndBacktabTraverseNativeKeyLoopWithoutChangingJSON() {
        // Never display or make this window key: this checks native responder mechanics only.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 180, height: 100))
        let next = NSTextView(frame: NSRect(x: 200, y: 0, width: 180, height: 100))
        window.contentView?.addSubview(editor)
        window.contentView?.addSubview(next)
        editor.nextKeyView = next
        next.nextKeyView = editor
        editor.string = #"{"image":"original"}"#
        let coordinator = AuthoringJSONEditor.Coordinator(text: .constant(editor.string))
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertTrue(window.firstResponder === next)
        XCTAssertTrue(coordinator.textView(next, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.string, #"{"image":"original"}"#)
        XCTAssertFalse(coordinator.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:))),
            "JSON line breaks remain native editing commands")
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }
}
