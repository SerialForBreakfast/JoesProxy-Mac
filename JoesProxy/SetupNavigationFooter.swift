import SwiftUI

/// Lives outside the scrolling page so dismissal never depends on checklist height.
struct SetupNavigationFooter: View {
    let nextTitle: String
    let finishes: Bool
    let back: (() -> Void)?
    let close: () -> Void
    let next: () -> Void

    var body: some View {
        HStack {
            Button("Close", action: close)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("guidedSetupClose")
            Spacer()
            if let back { Button("Back", action: back) }
            Button(nextTitle, action: next)
                .accessibilityIdentifier(finishes ? "guidedSetupFinish" : "guidedSetupNext")
        }
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }
}
