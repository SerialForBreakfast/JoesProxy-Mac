import XCTest
@testable import JoesProxy

final class AppVersioningTests: XCTestCase {
    func testBuiltBundleVersionMatchesVersionXcconfig() throws {
        let versionConfig = try VersionConfig.loadFromRepositoryRoot(startingAt: #filePath)

        XCTAssertEqual(Bundle.main.marketingVersion, versionConfig.marketingVersion)
        XCTAssertEqual(Bundle.main.buildNumber, versionConfig.buildNumber)
        XCTAssertEqual(
            Bundle.main.joesProxyUserAgentProductToken,
            "JoesProxy/\(versionConfig.marketingVersion)"
        )
    }
}

private struct VersionConfig {
    let marketingVersion: String
    let buildNumber: String

    static func loadFromRepositoryRoot(startingAt filePath: StaticString) throws -> VersionConfig {
        let fileURL = URL(fileURLWithPath: "\(filePath)")
        let repositoryRoot = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configURL = repositoryRoot
            .appendingPathComponent("Config")
            .appendingPathComponent("Version.xcconfig")

        let contents = try String(contentsOf: configURL, encoding: .utf8)
        let settings = parse(contents)

        guard let marketingVersion = settings["MARKETING_VERSION"], !marketingVersion.isEmpty else {
            throw VersionConfigError.missingKey("MARKETING_VERSION")
        }

        guard let buildNumber = settings["CURRENT_PROJECT_VERSION"], !buildNumber.isEmpty else {
            throw VersionConfigError.missingKey("CURRENT_PROJECT_VERSION")
        }

        return VersionConfig(marketingVersion: marketingVersion, buildNumber: buildNumber)
    }

    private static func parse(_ contents: String) -> [String: String] {
        var settings: [String: String] = [:]

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("//"), !line.hasPrefix("#") else { continue }

            let sanitizedLine = line.components(separatedBy: "#").first?.trimmingCharacters(in: .whitespaces) ?? line
            guard let equalsIndex = sanitizedLine.firstIndex(of: "=") else { continue }

            let key = sanitizedLine[..<equalsIndex].trimmingCharacters(in: .whitespaces)
            let value = sanitizedLine[sanitizedLine.index(after: equalsIndex)...]
                .trimmingCharacters(in: .whitespaces)

            settings[key] = value
        }

        return settings
    }
}

private enum VersionConfigError: Error, LocalizedError {
    case missingKey(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let key):
            return "Missing required version config key: \(key)"
        }
    }
}
