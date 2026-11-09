import SwiftUI

/// Resolution controls for one pending MCP approval, shared by the Approvals window and MCP
/// Management. Every control names its request, so VoiceOver and the rotor can tell rows apart
/// when several approvals are pending. Wraps vertically when enlarged text no longer fits a row.
struct MCPPendingApprovalActions: View {
    let request: MCPApprovalRequest
    let allowOnceIdentifier: String
    let denyIdentifier: String
    let resolve: (MCPApprovalResolution) -> Void
    var artifactSources: ArtifactSourceRegistry? = nil

    var body: some View {
        if request.capability == .artifactCompare {
            if let artifactSources {
                ArtifactPairReviewView(registry: artifactSources, requestID: request.requestID, deny: { resolve(.denyOnce) })
            }
        } else if request.capability == .artifactSourceAccess, let artifactSources {
            ArtifactSourceReviewView(registry: artifactSources, requestID: request.requestID)
        } else {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actions }
            VStack(alignment: .leading, spacing: 6) { actions }
        }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Allow Once") { resolve(.allowOnce) }
            .accessibilityLabel(Self.accessibilityLabel("Allow Once", for: request))
            .accessibilityIdentifier(allowOnceIdentifier)
        if !request.capability.requiresOneUseApproval {
            Menu("Grant Access") {
                Button("Allow Until Session Ends") { resolve(.untilSessionEnd) }
                Button("Allow For 1 Hour") { resolve(.untilDate(Date().addingTimeInterval(3_600))) }
                Button("Add To Client Policy") { resolve(.durablePolicy) }
            }
            .fixedSize()
            .accessibilityLabel(Self.accessibilityLabel("Grant Access", for: request))
        }
        Button("Deny", role: .destructive) { resolve(.denyOnce) }
            .accessibilityLabel(Self.accessibilityLabel("Deny", for: request))
            .accessibilityIdentifier(denyIdentifier)
        Button("Always Deny") { resolve(.alwaysDeny) }
            .accessibilityLabel(Self.accessibilityLabel("Always Deny", for: request))
    }

    static func accessibilityLabel(_ action: String, for request: MCPApprovalRequest) -> String {
        "\(action): \(request.reason), client \(request.clientID)"
    }
}
