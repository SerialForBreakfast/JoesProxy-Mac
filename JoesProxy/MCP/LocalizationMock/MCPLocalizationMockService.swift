//
//  MCPLocalizationMockService.swift
//  JoesProxy
//
//  MCP tool service for Autonomous Localization and Pseudo-Localization Mocking.
//

import Foundation

@MainActor
final class MCPLocalizationMockService {

    private let sessionStore: SessionStore

    init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
    }

    /// Lists all available localization presets.
    func listPresets() -> [MCPLocalizationPresetDTO] {
        LocalizationPresetKind.allCases.map {
            MCPLocalizationPresetDTO(
                id: $0.rawValue,
                title: $0.title,
                summary: $0.summary
            )
        }
    }

    /// Generates a preview of a localized mock response for a captured session.
    func previewLocalizationTransform(
        sessionID: UUID,
        presetID: String,
        preserveURLs: Bool = true,
        preserveIDs: Bool = true
    ) throws -> MCPLocalizationTransformDTO {
        guard let session = sessionStore.sessions.first(where: { $0.id == sessionID }) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Session ID \(sessionID) not found.")
        }
        guard let preset = LocalizationPresetKind(rawValue: presetID) else {
            throw MCPStructuredError(code: .malformedRequest, message: "Unknown localization preset '\(presetID)'.")
        }

        let bodyData = session.response?.bodyData ?? Data()
        var options = LocalizationTransformOptions()
        options.preset = preset
        options.preserveURLs = preserveURLs
        options.preserveIDs = preserveIDs

        let result = LocalizationMockEngine.transform(jsonData: bodyData, options: options)

        return MCPLocalizationTransformDTO(
            sessionID: sessionID.uuidString,
            preset: presetID,
            mutatedStringCount: result.mutatedStringCount,
            skippedStringCount: result.skippedStringCount,
            expansionPercentage: result.expansionPercentage,
            previewTransformedJSON: result.transformedString
        )
    }
}
