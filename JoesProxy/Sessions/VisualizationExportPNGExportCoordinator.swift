import AppKit
import Foundation
import UniformTypeIdentifiers

/// Coordinates PNG visualization export from a render model to a user-selected destination.
///
/// The coordinator is `@MainActor` because the default renderer uses `NSHostingView` and the default
/// destination selector presents `NSSavePanel`. Tests inject non-UI closures so the export happy path
/// can be verified without driving AppKit panels.
@MainActor
struct VisualizationExportPNGExportCoordinator {
    enum Destination: Equatable {
        case cancelled
        case file(URL)
    }

    enum Outcome: Equatable {
        case cancelled
        case exported(VisualizationExportResult)
    }

    typealias DestinationSelector = @MainActor (VisualizationExportRenderModel, String) -> Destination
    typealias PNGRenderer = @MainActor (VisualizationExportRenderModel) throws -> Data
    typealias PNGWriter = @MainActor (Data, URL) throws -> Void
    typealias ResultBuilder = @MainActor (VisualizationExportRenderModel, URL?, Int) -> VisualizationExportResult

    private let destinationSelector: DestinationSelector
    private let pngRenderer: PNGRenderer
    private let pngWriter: PNGWriter
    private let resultBuilder: ResultBuilder

    init(
        destinationSelector: @escaping DestinationSelector = Self.presentSavePanel,
        pngRenderer: @escaping PNGRenderer = { try VisualizationExportPNGRenderer().renderPNGData(for: $0) },
        pngWriter: @escaping PNGWriter = { data, destinationURL in
            try data.write(to: destinationURL, options: .atomic)
        },
        resultBuilder: @escaping ResultBuilder = { model, imageFileURL, imageByteCount in
            VisualizationExportPNGRenderer().makeResult(
                for: model,
                imageFileURL: imageFileURL,
                imageByteCount: imageByteCount
            )
        }
    ) {
        self.destinationSelector = destinationSelector
        self.pngRenderer = pngRenderer
        self.pngWriter = pngWriter
        self.resultBuilder = resultBuilder
    }

    func export(model: VisualizationExportRenderModel) throws -> Outcome {
        let defaultFileName = Self.defaultPNGFileName(for: model.request)

        switch destinationSelector(model, defaultFileName) {
        case .cancelled:
            return .cancelled
        case .file(let destinationURL):
            let pngData = try pngRenderer(model)
            try pngWriter(pngData, destinationURL)
            let result = resultBuilder(model, destinationURL, pngData.count)
            return .exported(result)
        }
    }

    static func defaultPNGFileName(for request: VisualizationExportRequest, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let slug = request.exportType.title
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        return "joesproxy-\(slug)-\(formatter.string(from: now)).png"
    }

    private static func presentSavePanel(
        model: VisualizationExportRenderModel,
        defaultFileName: String
    ) -> Destination {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = defaultFileName
        savePanel.title = "Export Visualization"
        savePanel.message = "Exported visualizations use the current redaction settings."

        guard savePanel.runModal() == .OK, let destinationURL = savePanel.url else {
            return .cancelled
        }

        return .file(destinationURL)
    }
}
