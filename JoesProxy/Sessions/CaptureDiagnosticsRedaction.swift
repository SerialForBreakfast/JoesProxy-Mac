//
//  CaptureDiagnosticsRedaction.swift
//  JoesProxy
//
//  Shareable redaction helpers for long-capture diagnostics (AD-1).
//

import Foundation

/// Redacts paths and URLs for shareable diagnostic output — never emits query values.
enum CaptureDiagnosticsRedaction {
    /// Returns a bounded path category: query/fragment stripped, first two segments, IDs normalized.
    static func pathCategory(for rawPath: String) -> String {
        let withoutFragment = rawPath.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let withoutQuery = withoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let normalizedPath = String(withoutQuery)
        let barePath = normalizedPath.isEmpty ? "/" : normalizedPath

        let components = barePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .prefix(2)
            .map { normalize(segment: String($0)) }

        guard !components.isEmpty else {
            return "/"
        }

        return "/" + components.joined(separator: "/")
    }

    private static func normalize(segment: String) -> String {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "/"
        }

        if Int(trimmed) != nil || UUID(uuidString: trimmed.lowercased()) != nil {
            return ":id"
        }

        return trimmed
    }
}
