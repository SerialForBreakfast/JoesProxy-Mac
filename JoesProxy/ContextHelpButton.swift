//
//  ContextHelpButton.swift
//  JoesProxy
//
//  A small question-mark button that presents a popover with contextual help content.
//  Used in toolbar strips and inspector headers throughout the main window.
//

import SwiftUI

struct ContextHelpButton<PopoverContent: View>: View {
    @Environment(\.appTextScale) private var appTextScale
    let accessibilityLabel: String
    let accessibilityHint: String
    let accessibilityIdentifier: String?
    @ViewBuilder let popoverContent: () -> PopoverContent
    @State private var isPresented = false

    init(
        accessibilityLabel: String,
        accessibilityHint: String,
        accessibilityIdentifier: String? = nil,
        @ViewBuilder popoverContent: @escaping () -> PopoverContent
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.accessibilityIdentifier = accessibilityIdentifier
        self.popoverContent = popoverContent
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: isPresented ? "questionmark.circle.fill" : "questionmark.circle")
                .appFont(.subheadline, scale: appTextScale)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityValue(isPresented ? "Showing help" : "Help hidden")
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent()
                .accessibilityElement(children: .contain)
        }
    }
}
