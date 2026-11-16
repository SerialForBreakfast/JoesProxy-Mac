#if DEBUG
import SwiftUI
import ScreenCaptureKit

/// Captures only the synthetic setup sheet owned by this process.
struct SetupPageScreenshotFixture: View {
    static let isEnabled = UITestLaunchConfiguration.current?.fixture == .demoSessions
        && ProcessInfo.processInfo.arguments.contains("--ui-test-capture-setup-pages")

    let section: GuidedSetupSection
    @State private var receipt = ""

    var body: some View {
        Color.clear
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Setup screenshot receipt")
            .accessibilityValue(receipt)
            .accessibilityIdentifier("setupScreenshotReceipt-\(receipt)")
            .allowsHitTesting(false)
            .task(id: section) {
                do {
                    try await Task.sleep(for: .milliseconds(800))
                    let sheets = NSApp.windows.filter { $0.isVisible && $0.sheetParent != nil }
                    guard sheets.count == 1, let sheet = sheets.first, let parent = sheet.sheetParent,
                          parent.frame.contains(sheet.frame) else { throw CocoaError(.fileReadUnknown) }
                    let content = try await SCShareableContent.currentProcess
                    guard let window = content.windows.first(where: { $0.windowID == CGWindowID(parent.windowNumber) })
                    else { throw CocoaError(.fileReadNoSuchFile) }
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let config = SCStreamConfiguration()
                    config.width = Int(window.frame.width * CGFloat(filter.pointPixelScale))
                    config.height = Int(window.frame.height * CGFloat(filter.pointPixelScale))
                    config.showsCursor = false
                    config.ignoreShadowsSingleWindow = true
                    config.includeChildWindows = true
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    try Task.checkCancellation()
                    let scale = CGFloat(filter.pointPixelScale)
                    let bounds = CGRect(x: (sheet.frame.minX - parent.frame.minX) * scale,
                                        y: (parent.frame.maxY - sheet.frame.maxY) * scale,
                                        width: sheet.frame.width * scale, height: sheet.frame.height * scale)
                    guard let cropped = image.cropping(to: bounds),
                          let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
                    else { throw CocoaError(.fileWriteUnknown) }
                    let scope = try RuntimeStorageScope.uiTest(environment: ProcessInfo.processInfo.environment)
                    try png.write(to: scope.file("setup-\(section.rawValue).png"), options: .withoutOverwriting)
                    receipt = section.rawValue
                } catch is CancellationError {
                } catch {
                    receipt = error.localizedDescription
                }
            }
    }
}
#endif
