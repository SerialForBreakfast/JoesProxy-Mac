//
//  CapturedURLRedaction.swift
//  JoesProxy
//
//  Privacy-aware URL display for captured ad and media diagnostics.
//

import Foundation

/// Strips query strings and fragments from URLs shown in Media Info and shareable summaries.
enum CapturedURLRedaction {
    /// Returns a host/path display string without query or fragment components.
    static func displayString(for urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if let url = URL(string: trimmed),
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.query = nil
            components.fragment = nil
            if let redacted = components.string, !redacted.isEmpty {
                return redacted
            }
        }

        return stripQueryAndFragment(from: trimmed)
    }

    private static func stripQueryAndFragment(from value: String) -> String {
        let withoutFragment = value.split(separator: "#", maxSplits: 1).first.map(String.init) ?? value
        return withoutFragment.split(separator: "?", maxSplits: 1).first.map(String.init) ?? withoutFragment
    }
}
