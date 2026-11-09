//
//  MediaDeliveryHeaderSummary.swift
//  JoesProxy
//
//  Extracts a bounded, read-only subset of captured response headers that are
//  useful when inspecting manifest and media delivery behavior.
//

import Foundation

struct MediaDeliveryHeaderSummary: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        let name: String
        let value: String
    }

    let items: [Item]

    static func from(
        response: CapturedResponse?,
        mediaType: MediaType?,
        structure: BinaryMediaStructure?
    ) -> MediaDeliveryHeaderSummary? {
        guard let response, shouldSummarize(mediaType: mediaType, structure: structure) else {
            return nil
        }

        let interestingHeaders = response.headers.compactMap { field -> Item? in
            guard isInterestingHeader(field.name) else {
                return nil
            }

            let trimmed = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return nil
            }

            return Item(
                name: field.name,
                value: truncated(trimmed)
            )
        }

        guard !interestingHeaders.isEmpty else {
            return nil
        }

        return MediaDeliveryHeaderSummary(items: Array(interestingHeaders.prefix(8)))
    }

    private static func shouldSummarize(
        mediaType: MediaType?,
        structure: BinaryMediaStructure?
    ) -> Bool {
        switch mediaType {
        case .hls, .dash:
            return true
        case .adXml:
            return true
        case .video:
            guard let role = structure?.role else {
                return false
            }
            return role == .initializationAsset || role == .mediaFragment || role == .transportSegment
        default:
            return false
        }
    }

    private static func isInterestingHeader(_ name: String) -> Bool {
        let lowercase = name.lowercased()
        if [
            "cache-control",
            "age",
            "etag",
            "last-modified",
            "server",
            "via",
            "content-range",
            "accept-ranges"
        ].contains(lowercase) {
            return true
        }

        return lowercase.hasPrefix("x-")
            || lowercase.hasPrefix("cf-")
            || lowercase.contains("akamai")
            || lowercase.contains("fastly")
    }

    private static func truncated(_ value: String) -> String {
        let maxLength = 120
        if value.count <= maxLength {
            return value
        }
        return String(value.prefix(maxLength - 1)) + "…"
    }
}
