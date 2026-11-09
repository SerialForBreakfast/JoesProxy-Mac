import Foundation

/// Builds MCP effect inventory rows from live stores and the durable journal.
enum MCPEffectInventoryBuilder {
    static func build(
        rules: [ResponseOverrideRule],
        bookmarks: [Bookmark],
        throttleConfiguration: NetworkThrottleConfiguration,
        journalEntries: [MCPEffectJournalEntry],
        openAPIMockPacks: [OpenAPIMockPack] = []
    ) -> [MCPEffectInventoryItem] {
        var items: [MCPEffectInventoryItem] = []

        for rule in rules where rule.mcpOrigin == .mcp {
            let kind = effectKind(for: rule.sourceKind)
            let journalEntry = latestCommittedEntry(for: rule.id.uuidString, in: journalEntries)
            items.append(
                MCPEffectInventoryItem(
                    id: rule.id.uuidString,
                    kind: kind,
                    displayLabel: rule.label ?? kindTitle(kind),
                    sanitizedTarget: sanitizedOverrideTarget(rule),
                    isEnabled: rule.isEnabled,
                    mcpOrigin: rule.mcpOrigin ?? .mcp,
                    clientID: rule.mcpProvenance?.clientID,
                    canRestore: journalEntry?.rollbackSnapshot != nil,
                    canDetach: true
                )
            )
        }

        for bookmark in bookmarks where bookmark.mcpOrigin == .mcp {
            for rewrite in bookmark.responseRewrites {
                let itemID = "\(bookmark.id.uuidString):\(rewrite.id.uuidString)"
                let journalEntry = latestCommittedEntry(for: itemID, in: journalEntries)
                items.append(
                    MCPEffectInventoryItem(
                        id: itemID,
                        kind: .bookmarkRewrite,
                        displayLabel: rewrite.jsonPath,
                        sanitizedTarget: "\(bookmark.name) · \(rewrite.jsonPath)",
                        isEnabled: rewrite.isRuleEnabled,
                        mcpOrigin: bookmark.mcpOrigin ?? .mcp,
                        clientID: bookmark.mcpProvenance?.clientID,
                        canRestore: journalEntry?.rollbackSnapshot != nil,
                        canDetach: true
                    )
                )
            }

            if bookmark.responseRewrites.isEmpty {
                items.append(
                    MCPEffectInventoryItem(
                        id: bookmark.id.uuidString,
                        kind: .responseOverride,
                        displayLabel: bookmark.name,
                        sanitizedTarget: sanitizedBookmarkTarget(bookmark),
                        isEnabled: false,
                        mcpOrigin: bookmark.mcpOrigin ?? .mcp,
                        clientID: bookmark.mcpProvenance?.clientID,
                        canRestore: false,
                        canDetach: true
                    )
                )
            }
        }

        for pack in openAPIMockPacks where pack.mcpProvenance != nil && pack.isServing {
            let journalEntry = latestCommittedEntry(for: pack.id.rawValue.uuidString, in: journalEntries)
            items.append(
                MCPEffectInventoryItem(
                    id: pack.id.rawValue.uuidString,
                    kind: .openAPIMockPack,
                    displayLabel: "OpenAPI mock pack",
                    sanitizedTarget: pack.origin.displayString,
                    isEnabled: pack.isServing,
                    mcpOrigin: .mcp,
                    clientID: pack.mcpProvenance?.clientID,
                    canRestore: journalEntry?.rollbackSnapshot != nil,
                    canDetach: true
                )
            )
        }

        if throttleConfiguration.mcpOrigin == .mcp {
            let journalEntry = latestCommittedEntry(for: "throttle", in: journalEntries)
            let isActive = throttleConfiguration.isEnabled && throttleConfiguration.effectivePreset() != nil
            items.append(
                MCPEffectInventoryItem(
                    id: "throttle",
                    kind: .throttle,
                    displayLabel: "Network throttle",
                    sanitizedTarget: throttleConfiguration.effectivePreset()?.name ?? "Custom throttle",
                    isEnabled: isActive,
                    mcpOrigin: .mcp,
                    clientID: throttleConfiguration.mcpProvenance?.clientID,
                    canRestore: journalEntry?.rollbackSnapshot != nil,
                    canDetach: true
                )
            )
        }

        return items.sorted { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled {
                return lhs.isEnabled && !rhs.isEnabled
            }
            return lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel) == .orderedAscending
        }
    }

    static func latestCommittedEntry(
        for targetID: String,
        in entries: [MCPEffectJournalEntry]
    ) -> MCPEffectJournalEntry? {
        entries
            .filter { $0.targetID == targetID && $0.phase == .committed }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    static func effectKind(for sourceKind: ResponseOverrideSourceKind) -> MCPEffectKind {
        switch sourceKind {
        case .block:
            return .block
        case .mapRemote:
            return .mapRemote
        case .bookmarkRewrite:
            return .bookmarkRewrite
        case .liveResponseRewrite:
            return .liveResponseRewrite
        case .collectionMock:
            return .collectionMock
        case .capturedResponse, .inlineText, .localFile, .fixtureRun, .localDirectory:
            return .mapLocal
        }
    }

    private static func kindTitle(_ kind: MCPEffectKind) -> String {
        switch kind {
        case .mapLocal: return "Map Local"
        case .mapRemote: return "Map Remote"
        case .block: return "Block"
        case .bookmarkRewrite: return "Bookmark rewrite"
        case .liveResponseRewrite: return "Live response rewrite"
        case .collectionMock: return "Collection mock"
        case .throttle: return "Throttle"
        case .responseOverride: return "Response override"
        case .responseDraft: return "Response draft"
        case .hlsFixtureRun: return "HLS fixture run"
        case .certificateTrustCleanup: return "Certificate trust cleanup"
        case .openAPIMockPack: return "OpenAPI mock pack"
        case .diagnosticRun: return "Diagnostic run"
        case .effectBundle: return "Effect bundle"
        }
    }

    private static func sanitizedOverrideTarget(_ rule: ResponseOverrideRule) -> String {
        "\(rule.requestMethod) \(rule.host)\(rule.path)"
    }

    private static func sanitizedBookmarkTarget(_ bookmark: Bookmark) -> String {
        let request = bookmark.request
        return "\(request.method) \(request.host)\(request.path)"
    }
}
