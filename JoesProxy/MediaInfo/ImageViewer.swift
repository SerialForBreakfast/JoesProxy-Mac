//
//  ImageViewer.swift
//  JoesProxy
//
//  Previews image responses in the session detail. Supports JPEG, PNG, GIF, WebP.
//

import AppKit
import SwiftUI

/// Displays an image from response body data with dimensions and size metadata.
struct ImageViewer: View {
    let bodyData: Data
    let contentType: String?
    let sessionID: UUID
    let contentRevision: UInt64
    @State private var preview = ImagePreviewModel()
    private var imageSize: CGSize? { preview.image?.size }
    private var metadata: ImageMetadata? { preview.metadata }
    private var visualReport: VisualAssetReport? { preview.visualReport }
    private var previewKey: ImagePreviewKey {
        ImagePreviewKey(sessionID: sessionID, revision: contentRevision, contentType: contentType)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = metadata?.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                if preview.isLoading || preview.attemptCount == 0 {
                    ProgressView()
                        .controlSize(.small)
                } else if let nsImage = preview.image {
                    imageContent(nsImage: nsImage)
                } else {
                    Text("Unable to decode image")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: previewKey) {
            preview.request(key: previewKey, data: bodyData)
        }
        .onDisappear { preview.cancelAndClear() }
    }

    @ViewBuilder
    private func imageContent(nsImage: NSImage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 400, maxHeight: 400)
                .accessibilityLabel("Image preview")

            if let visualReport {
                VisualWireInspectorTileView(report: visualReport)
            }

            HStack(spacing: 12) {
                if let size = imageSize {
                    Text("\(Int(size.width)) x \(Int(size.height))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text("\(bodyData.count) bytes")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let contentType {
                    Text(contentType)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if let metadata {
                imageMetadataSection(metadata)
            }
        }
    }

    @ViewBuilder
    private func imageMetadataSection(_ metadata: ImageMetadata) -> some View {
        GroupBox("Captured Image Metadata") {
            VStack(alignment: .leading, spacing: 8) {
                if let containerTypeIdentifier = metadata.containerTypeIdentifier {
                    metadataRow("Container", value: containerTypeIdentifier)
                }
                if let preferredMIMEType = metadata.preferredMIMEType {
                    metadataRow("Detected MIME", value: preferredMIMEType)
                }
                if metadata.frameCount > 1 {
                    metadataRow("Frames", value: "\(metadata.frameCount)")
                }
                if let orientationDescription = metadata.orientationDescription {
                    metadataRow("Orientation", value: orientationDescription)
                }
                if let colorModel = metadata.colorModel {
                    metadataRow("Color Model", value: colorModel)
                }
                if let hasAlpha = metadata.hasAlpha {
                    metadataRow("Alpha", value: hasAlpha ? "Present" : "None")
                }
                if let dpiDescription = metadata.dpiDescription {
                    metadataRow("Resolution", value: dpiDescription)
                }
                if let exifSummary = metadata.exifSummary {
                    if let make = exifSummary.make {
                        metadataRow("Camera Make", value: make)
                    }
                    if let model = exifSummary.model {
                        metadataRow("Camera Model", value: model)
                    }
                    if let lensModel = exifSummary.lensModel {
                        metadataRow("Lens", value: lensModel)
                    }
                    if let dateTimeOriginal = exifSummary.dateTimeOriginal {
                        metadataRow("Captured At", value: dateTimeOriginal)
                    }
                }
                if !metadata.auxiliaryDataTypes.isEmpty {
                    metadataRow("Auxiliary", value: metadata.auxiliaryDataTypes.joined(separator: ", "))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.system(.body, design: .monospaced))
        }
    }
}
