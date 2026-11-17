import SwiftUI

struct SetupStep: View {
    enum Status {
        case complete, pending, working, needsAttention, manual

        var appearance: (symbol: String, color: Color, description: String) {
            switch self {
            case .complete: ("checkmark.circle.fill", .green, "Complete")
            case .pending: ("circle.dashed", .secondary, "Not verified")
            case .working: ("clock.fill", .orange, "In progress")
            case .needsAttention: ("exclamationmark.circle.fill", .red, "Needs attention")
            case .manual: ("person.circle", .secondary, "Manual step")
            }
        }
    }

    let title: String
    let status: Status

    init(_ title: String, _ status: Status) {
        self.title = title
        self.status = status
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: status.appearance.symbol)
                .foregroundStyle(status.appearance.color)
        }
        .font(.headline)
        .accessibilityValue(status.appearance.description)
    }
}
