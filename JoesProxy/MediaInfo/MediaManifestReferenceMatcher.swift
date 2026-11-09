//
//  MediaManifestReferenceMatcher.swift
//  JoesProxy
//
//  Shared URL and template matching helpers for manifest correlation.
//

import Foundation

enum MediaManifestReferenceMatcher {
    static func matchStrategy(currentURL: URL, candidateURL: URL) -> ManifestReferenceMatch.Strategy? {
        if normalizedAbsoluteString(currentURL) == normalizedAbsoluteString(candidateURL) {
            return .exactURL
        }

        if normalizedHost(currentURL) == normalizedHost(candidateURL),
           normalizedPath(currentURL) == normalizedPath(candidateURL) {
            return .hostAndPath
        }

        return nil
    }

    static func normalizedAbsoluteString(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        if let queryItems = components?.queryItems, !queryItems.isEmpty {
            components?.queryItems = queryItems.sorted {
                if $0.name == $1.name {
                    return ($0.value ?? "") < ($1.value ?? "")
                }
                return $0.name < $1.name
            }
        }
        return components?.url?.absoluteString ?? url.absoluteString
    }

    static func normalizedHost(_ url: URL) -> String? {
        url.host?.lowercased()
    }

    static func normalizedPath(_ url: URL) -> String {
        let path = url.path.isEmpty ? "/" : url.path
        if path.count > 1, path.hasSuffix("/") {
            return String(path.dropLast())
        }
        return path
    }
}
