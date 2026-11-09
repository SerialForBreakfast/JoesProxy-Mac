//
//  MCPCompactApprovalSheet.swift
//  JoesProxy
//
/// Minimal pending-approval surface for menu bar / compact workflows (AO Axis 1).
/// Thin view over ``MCPServerController/resolvePending(requestID:resolution:)`` — not a second
/// implementation of ``MCPManagementView``.
///

import SwiftUI

/// Lists pending MCP approvals and resolves them with the same resolution cases as management UI.
struct MCPCompactApprovalSheet: View {
    @ObservedObject var controller: MCPServerController
    let onDismiss: () -> Void

    @Environment(\.appTextScale) private var textScale
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pending MCP Approvals")
                    .appFont(.headline, scale: textScale, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("mcpCompactApprovalsDone")
            }

            if let statusMessage {
                Text(statusMessage)
                    .appFont(.caption, scale: textScale)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("mcpCompactApprovalsStatus")
            }

            if let sources = controller.artifactSources { ArtifactActiveSharesView(registry: sources) }
            if controller.pendingApprovals.isEmpty {
                Text("No pending approvals.")
                    .appFont(.body, scale: textScale)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .accessibilityIdentifier("mcpCompactApprovalsEmpty")
            } else {
                List {
                    ForEach(controller.pendingApprovals, id: \.requestID) { request in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(request.reason)
                                .appFont(.headline, scale: textScale, weight: .semibold)
                            Text("Client \(request.clientID) · \(request.capability.rawValue)")
                                .appFont(.caption, scale: textScale)
                            Text("Expires \(request.expiresAt.formatted())")
                                .appFont(.caption, scale: textScale)
                                .foregroundStyle(.secondary)
                            MCPPendingApprovalActions(
                                request: request,
                                allowOnceIdentifier: "mcpCompactApproveOnce",
                                denyIdentifier: "mcpCompactDenyOnce",
                                resolve: { resolve(requestID: request.requestID, resolution: $0) },
                                artifactSources: controller.artifactSources
                            )
                            .appFont(.body, scale: textScale)
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Pending approval: \(request.reason)")
                    }
                }
                .accessibilityIdentifier("mcpCompactApprovalsList")
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: controller.pendingApprovals.contains(where: { $0.capability == .artifactSourceAccess || $0.capability == .artifactCompare }) ? 600 : 320)
        .onAppear {
            controller.refreshPendingApprovals()
        }
        .onDisappear { controller.artifactSources?.cancelUnsharedReviews() }
    }

    private func resolve(requestID: String, resolution: MCPApprovalResolution) {
        do {
            _ = try controller.resolvePending(requestID: requestID, resolution: resolution)
            controller.refreshPendingApprovals()
            statusMessage = nil
            if controller.pendingApprovals.isEmpty {
                onDismiss()
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
