//
//  RequestMethodBadge.swift
//  JoesProxy
//
//  A colored pill badge displaying an HTTP method label. Used in both the session
//  table/explorer rows and the session detail inspector strip.
//

import SwiftUI

struct RequestMethodBadge: View {
    let method: String
    let scale: CGFloat

    var body: some View {
        Text(method.uppercased())
            .appFont(.caption, scale: scale, weight: .bold)
            .foregroundStyle(.white)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(minWidth: minimumWidth)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityLabel("\(method.uppercased()) request method")
    }

    private var minimumWidth: CGFloat {
        max(54 * scale, 54)
    }

    private var horizontalPadding: CGFloat {
        max(6 * scale, 6)
    }

    private var verticalPadding: CGFloat {
        max(2 * scale, 2)
    }

    private var backgroundColor: Color {
        switch method.uppercased() {
        case "GET":
            return .blue
        case "POST":
            return .green
        case "PUT":
            return .orange
        case "PATCH":
            return Color(red: 0.55, green: 0.35, blue: 0.0)
        case "DELETE":
            return .red
        case "HEAD":
            return .purple
        case "CONNECT":
            return .indigo
        default:
            return .gray
        }
    }
}
