import Foundation

enum ReproPackageSource: String, Codable, Equatable, Sendable {
    case nativeCapture
    case harImport
}

struct ReproPackage: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let createdAt: Date
    let appVersion: String
    let title: String
    let notes: String
    let source: ReproPackageSource
    let sessions: [ReproSession]
    let hypothesisGraphs: [ReproHypothesisGraph]
    let scripts: [ReproScript]
    let redactionReport: ReproRedactionReport
}

struct ReproSession: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let request: ReproRequest
    let response: ReproResponse?
    let timing: ReproTiming
    let expectedOutcome: ReproExpectedOutcome
}

struct ReproRequest: Codable, Equatable, Sendable {
    let method: String
    let scheme: SessionScheme
    let host: String
    let port: Int?
    let path: String
    let headers: [HTTPHeaderField]
    let originalBodyByteCount: Int?
    let bodyOmittedForPrivacy: Bool
}

struct ReproResponse: Codable, Equatable, Sendable {
    let statusCode: Int
    let headers: [HTTPHeaderField]
    let originalBodyByteCount: Int?
    let bodyOmittedForPrivacy: Bool
}

struct ReproTiming: Codable, Equatable, Sendable {
    let startedAt: Date
    let duration: TimeInterval?
    let wireProfile: WireTimingProfile?
}

struct ReproExpectedOutcome: Codable, Equatable, Sendable {
    let statusCode: Int?
    let failureBucket: String?
}

struct ReproScript: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let sessionID: String
    let title: String
    let command: String
}

struct ReproHypothesisGraph: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let targetBugDescription: String
    let nodes: [ReproHypothesisNode]
    let currentNodeID: String?
    let isolatedRootCauseNodeID: String?
}

struct ReproHypothesisNode: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let parentID: String?
    let title: String
    let explanation: String
    let mutationKind: String
    let expectedOutcome: String
    let status: String
    let evidenceSummary: String?
}

struct ReproRedactionReport: Codable, Equatable, Sendable {
    let headerValuesRedacted: Int
    let queryValuesRedacted: Int
    let bodiesOmitted: Int
    let privateAddressesRedacted: Int
    let localPathsRedacted: Int
    let freeformSecretsRedacted: Int

    var totalRedactions: Int {
        headerValuesRedacted + queryValuesRedacted + bodiesOmitted + privateAddressesRedacted
            + localPathsRedacted + freeformSecretsRedacted
    }
}

struct ReproPackageInspection: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let title: String
    let source: ReproPackageSource
    let sessionCount: Int
    let hypothesisGraphCount: Int
    let scriptCount: Int
    let redactionReport: ReproRedactionReport
    let replayableSessionCount: Int
}

struct MCPReproExportResult: Codable, Equatable, Sendable {
    let outputPath: String
    let contentByteCount: Int
    let inspection: ReproPackageInspection
}
