import Foundation

/// Target mocking framework format for generated Swift test code.
enum SwiftMockFramework: String, CaseIterable, Sendable, Codable {
    case mocker = "mocker"
    case vanillaURLProtocol = "urlprotocol"

    var displayName: String {
        switch self {
        case .mocker:
            return "WeTransfer/Mocker"
        case .vanillaURLProtocol:
            return "Foundation URLProtocol"
        }
    }
}

/// How response fixture payloads are embedded in the generated Swift code.
enum SwiftMockFixtureMode: String, CaseIterable, Sendable, Codable {
    case inlineString = "inline"
    case bundledJSONFile = "bundle_file"

    var displayName: String {
        switch self {
        case .inlineString:
            return "Inline String Data"
        case .bundledJSONFile:
            return "Test Bundle JSON Files"
        }
    }
}

/// Options configuring the generation of Swift test suites and mock snippets.
struct SwiftMockExportOptions: Sendable, Codable, Equatable {
    var framework: SwiftMockFramework
    var fixtureMode: SwiftMockFixtureMode
    var testClassName: String
    var testMethodName: String
    var includeDelays: Bool
    var includeHeaders: Bool

    init(
        framework: SwiftMockFramework = .mocker,
        fixtureMode: SwiftMockFixtureMode = .inlineString,
        testClassName: String = "GeneratedNetworkFlowTests",
        testMethodName: String = "testUserJourneyFlow",
        includeDelays: Bool = false,
        includeHeaders: Bool = true
    ) {
        self.framework = framework
        self.fixtureMode = fixtureMode
        self.testClassName = testClassName
        self.testMethodName = testMethodName
        self.includeDelays = includeDelays
        self.includeHeaders = includeHeaders
    }
}

/// Companion fixture file generated alongside Swift test suite code.
struct SwiftMockFixtureFile: Sendable, Codable, Equatable {
    let filename: String
    let relativePath: String
    let data: Data
    let mimeType: String
}

/// A complete generated Swift mock suite with source code and companion fixtures.
struct SwiftMockGeneratedSuite: Sendable, Codable, Equatable {
    let swiftSourceCode: String
    let fixtureFiles: [SwiftMockFixtureFile]
    let sessionCount: Int
    let framework: SwiftMockFramework
    let generatedAt: Date

    init(
        swiftSourceCode: String,
        fixtureFiles: [SwiftMockFixtureFile] = [],
        sessionCount: Int,
        framework: SwiftMockFramework,
        generatedAt: Date = Date()
    ) {
        self.swiftSourceCode = swiftSourceCode
        self.fixtureFiles = fixtureFiles
        self.sessionCount = sessionCount
        self.framework = framework
        self.generatedAt = generatedAt
    }
}
