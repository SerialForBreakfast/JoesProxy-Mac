//
//  MediaHostSignals.swift
//  JoesProxy
//
//  Brand-neutral host and URL heuristics for HLS stream classification.
//  Ad-serving hosts are generic ad-tech infrastructure; live detection uses
//  path/query shape rather than vendor CDN hostnames.
//

import Foundation

/// Shared, brand-neutral signals used by ``MediaDetector`` and Media Info UI.
enum MediaHostSignals {
    /// Returns `true` when `host` looks like a known ad-serving endpoint
    /// (DoubleClick / Google syndication), not a content brand CDN.
    static func isAdServingHost(_ host: String) -> Bool {
        let lowercased = host.lowercased()
        return lowercased.contains("doubleclick.net")
            || lowercased.contains("googlesyndication.com")
            || lowercased.contains("googleadservices.com")
    }

    /// Best-effort live/linear detection from the manifest URL path and query.
    ///
    /// - Parameter manifestURL: Absolute URL of the discovered HLS master or media playlist.
    /// - Returns: `true` when path or query components include common live tokens
    ///   (`live`, `linear`, `channel`). Less precise than a vendor-CDN allowlist;
    ///   prefer this over hardcoding content-brand hostnames.
    static func indicatesLivePlayback(_ manifestURL: URL) -> Bool {
        let path = manifestURL.path.lowercased()
        let query = (manifestURL.query ?? "").lowercased()
        let haystack = path + "?" + query
        let tokens = ["live", "linear", "channel"]
        return tokens.contains { token in
            haystack.range(of: #"(^|[/\?&=._-])\#(token)($|[/\?&=._-])"#, options: .regularExpression) != nil
        }
    }
}
