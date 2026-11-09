import AppKit
import SwiftUI

enum VisualizationExportPNGRendererError: LocalizedError, Equatable {
    case invalidDimensions
    case imageRepresentationFailed
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidDimensions:
            return "Export dimensions are invalid."
        case .imageRepresentationFailed:
            return "The visualization preview could not be rendered."
        case .pngEncodingFailed:
            return "The visualization preview could not be encoded as PNG."
        }
    }
}

@MainActor
struct VisualizationExportPNGRenderer {
    func renderPNGData(for model: VisualizationExportRenderModel) throws -> Data {
        let dimensions = model.request.dimensions
        guard dimensions.isValid else {
            throw VisualizationExportPNGRendererError.invalidDimensions
        }

        let view = VisualizationExportRenderView(model: model)
        let hostingView = NSHostingView(rootView: view)
        let size = NSSize(width: dimensions.width, height: dimensions.height)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.setFrameSize(size)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: dimensions.width,
            pixelsHigh: dimensions.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw VisualizationExportPNGRendererError.imageRepresentationFailed
        }

        bitmap.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw VisualizationExportPNGRendererError.pngEncodingFailed
        }

        return data
    }

    func makeResult(
        for model: VisualizationExportRenderModel,
        imageFileURL: URL?,
        imageByteCount: Int,
        generatedAt: Date = Date()
    ) -> VisualizationExportResult {
        let request = model.request
        return VisualizationExportResult(
            requestID: request.id,
            exportType: request.exportType,
            imageFileURL: imageFileURL,
            imageByteCount: imageByteCount,
            dimensions: request.dimensions,
            metadata: VisualizationExportResultMetadata(
                generatedAt: generatedAt,
                appVersion: Bundle.main.marketingVersionOrDev,
                exportSchemaVersion: request.schemaVersion
            ),
            redactionSummary: request.redactionPolicy.summary,
            dataSummary: model.dataSummary,
            sourceDescriptor: VisualizationExportSourceDescriptor(request: request)
        )
    }
}
