//
//  MediaParserDiagnostics.swift
//  JoesProxy
//
//  Redacted, structured diagnostics for user-initiated media inspection.
//

import Foundation

enum MediaParserDiagnosticOutcome: String, Sendable, Equatable {
    case success
    case partial
    case noMetadata = "no_metadata"
    case invalidContainer = "invalid_container"
    case unsupportedStream = "unsupported_stream"
    case noAccessUnits = "no_access_units"
}

struct MediaParserDiagnostics: Sendable, Equatable {
    let parser: String
    let outcome: MediaParserDiagnosticOutcome
    let bytesAvailable: Int
    let bytesInspected: Int
    let completedStages: [String]
    let counters: [String: Int]
    let warnings: [String]

    var logMessage: String {
        let counterSummary = counters
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let stageSummary = completedStages.joined(separator: ",")
        return [
            "media_parse",
            "parser=\(parser)",
            "outcome=\(outcome.rawValue)",
            "bytesAvailable=\(bytesAvailable)",
            "bytesInspected=\(bytesInspected)",
            "stages=\(stageSummary.isEmpty ? "none" : stageSummary)",
            counterSummary
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }
}
