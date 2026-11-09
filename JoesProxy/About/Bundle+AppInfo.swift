//
//  Bundle+AppInfo.swift
//  JoesProxy
//
//  Convenience accessors for Info.plist values used in the About view.
//

import Foundation

extension Bundle {
    /// The human-readable application name (`CFBundleName`).
    var appName: String { infoDictionary?["CFBundleName"] as? String ?? "JoesProxy" }

    /// The marketing version string, e.g. `"1.0.1"` (`CFBundleShortVersionString`).
    var marketingVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    /// Marketing version for export metadata and tests when the plist is fully resolved; `"dev"` if missing.
    var marketingVersionOrDev: String {
        let v = marketingVersion
        return v.isEmpty ? "dev" : v
    }

    /// `User-Agent` product token for demo/utility traffic, e.g. `JoesProxy/1.0.1` (from `Config/Version.xcconfig`).
    var joesProxyUserAgentProductToken: String { "JoesProxy/\(marketingVersionOrDev)" }

    /// The build number (`CFBundleVersion`): monotonic integer per shipped build; see `memlog/Research/ADR-Versioning-And-Releases.md`.
    var buildNumber: String { infoDictionary?["CFBundleVersion"] as? String ?? "" }

    /// The human-readable copyright string (`NSHumanReadableCopyright`).
    var humanReadableCopyright: String { infoDictionary?["NSHumanReadableCopyright"] as? String ?? "" }
}
