//
//  QRCodeView.swift
//  JoesProxy
//
//  Reusable SwiftUI view that renders a QR code for a URL string using CoreImage.
//  No additional dependencies are required beyond the system CoreImage framework.
//
//  Usage:
//    QRCodeView(urlString: "http://192.168.1.5:8765", size: 200)
//
//  The URL string is also shown as selectable text beneath the code for accessibility
//  and manual-entry fallback.
//

import SwiftUI
import CoreImage

/// A view that renders a QR code from a URL string and shows the URL as selectable text.
///
/// The QR image is generated with `CIQRCodeGenerator` (CoreImage). No additional Swift
/// packages are required.
///
/// - When `urlString` is empty the view shows a placeholder rectangle.
/// - The image uses `interpolation(.none)` to keep pixel-art QR squares sharp when scaled.
struct QRCodeView: View {

    /// The URL string encoded into the QR code image. May differ from `displayURLString` — e.g. a
    /// `x-safari-https://` deep link that forces the scan to open in Safari specifically instead of
    /// the device's default browser, while the plain `https://` form is still shown/selectable for
    /// manual entry (typing the `x-safari-` form into a browser's address bar does nothing useful).
    let urlString: String

    /// Text shown beneath the code for accessibility and manual-entry fallback. Defaults to
    /// `urlString` when not supplied, matching every existing call site's behavior.
    var displayURLString: String?

    /// Rendered size of the QR code image, in points. Defaults to 200.
    var size: CGFloat = 200

    private var resolvedDisplayString: String {
        displayURLString ?? urlString
    }

    var body: some View {
        VStack(spacing: 10) {
            if let image = makeQRCodeImage(for: urlString, size: size) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: size, height: size)
                    .accessibilityLabel("QR code for \(resolvedDisplayString)")
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: size, height: size)
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "qrcode")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("QR code unavailable")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("QR code unavailable")
            }

            if !resolvedDisplayString.isEmpty {
                Text(resolvedDisplayString)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: size)
            }
        }
    }

    // MARK: - Image Generation

    /// Generates a QR-code `NSImage` for the given URL string at the requested point size.
    ///
    /// Returns `nil` if the string is empty or CoreImage cannot produce output.
    func makeQRCodeImage(for urlString: String, size: CGFloat) -> NSImage? {
        guard !urlString.isEmpty,
              let data = urlString.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage, outputImage.extent.width > 0 else {
            return nil
        }

        let scale = size / outputImage.extent.width
        let scaledImage = outputImage.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 24) {
        QRCodeView(urlString: "http://192.168.1.5:8765", size: 200)
        QRCodeView(urlString: "", size: 120)
    }
    .padding()
}
