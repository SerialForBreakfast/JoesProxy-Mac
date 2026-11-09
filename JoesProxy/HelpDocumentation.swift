import Foundation
import os
import SwiftUI

/// UI reads an immutable snapshot; loading and indexing happen on DocumentationService's actor.
enum HelpDocumentation {
    private static let storage = OSAllocatedUnfairLock<DocumentationCatalog?>(initialState: nil)
    static var catalog: DocumentationCatalog? { storage.withLock { $0 } }
    static func load() async throws {
        let catalog = try await DocumentationService.shared.snapshot()
        storage.withLock { $0 = catalog }
    }
    static func topic(_ id: String) -> DocumentationCatalog.Topic? {
        catalog?.index.topics.first { $0.id == id }
    }
    static func text(_ id: String, section: String) -> String {
        catalog?.topicSections(id).first { $0.id == section }?.markdown ?? "Documentation unavailable."
    }
    static func bullets(_ id: String, section: String) -> [String] {
        text(id, section: section).components(separatedBy: .newlines).filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
    }
}

private struct HelpDocumentationLoading: ViewModifier {
    @Environment(\.appTextScale) private var textScale
    let onLoad: () -> Void
    @State private var ready = false
    @State private var failure: String?
    @State private var attempt = 0
    func body(content: Content) -> some View {
        Group {
            if ready { content }
            else if let failure {
                VStack {
                    Text(failure)
                    Button("Retry Loading Help") { attempt += 1 }
                }.padding().accessibilityIdentifier("helpDocumentationError")
            } else { ProgressView("Loading Help…").padding() }
        }
        .appFont(.body, scale: textScale)
        .task(id: attempt) {
            do {
                try await HelpDocumentation.load()
                try Task.checkCancellation()
                onLoad()
                ready = true
            } catch is CancellationError { }
            catch { failure = "Bundled documentation could not be loaded. Reopen a complete JoesProxy installation." }
        }
    }
}

extension View {
    func loadHelpDocumentation(onLoad: @escaping () -> Void) -> some View {
        modifier(HelpDocumentationLoading(onLoad: onLoad))
    }
}
