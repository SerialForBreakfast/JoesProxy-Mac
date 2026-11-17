import Foundation

/// Persisted receipt for one successfully activated scenario fault (AI-2).
///
/// Stored on ``MCPScenarioRecord`` so cleanup survives process restart and can target the exact
/// inventory row created during activation.
struct MCPScenarioAppliedFaultReceipt: Equatable, Sendable, Codable {
    var faultIndex: Int
    var transactionID: String
    var inventoryTargetID: String
    var effectKind: MCPEffectKind
}

/// In-flight apply result returned to ``MCPScenarioExecutor`` before journal commit enriches the
/// transaction ID.
struct MCPFaultApplyReceipt: Equatable, Sendable {
    var transactionID: String
    var inventoryTargetID: String
    var effectKind: MCPEffectKind
    var faultIndex: Int

    func persisted(faultIndex: Int) -> MCPScenarioAppliedFaultReceipt {
        MCPScenarioAppliedFaultReceipt(
            faultIndex: faultIndex,
            transactionID: transactionID,
            inventoryTargetID: inventoryTargetID,
            effectKind: effectKind
        )
    }
}

enum MCPScenarioFaultApplicatorError: Error, Equatable, Sendable {
    case unsupportedFault(String)
    case storeWriteFailed(String)
    case bookmarkNotFound(UUID)
}

/// Applies and reverts scenario faults against the real MCP-owned stores (AI-2).
///
/// Concurrency: `@MainActor` — mutates ``ResponseOverrideStore``, bookmarks, and throttle config
/// on the same actor as the MCP controller graph.
@MainActor
final class MCPScenarioFaultApplicator {
    private let responseOverrideStore: ResponseOverrideStore
    private let bookmarkStore: any BookmarkStore
    private let bookmarkExecutor: (any BookmarkExecuting)?
    private let runningProxyPort: () -> UInt16?
    private let restorer: MCPRecoveryRestorer
    private let throttleConfigurationReader: () -> NetworkThrottleConfiguration
    private let throttleConfigurationWriter: (NetworkThrottleConfiguration) -> Void
    private let loopbackPolicyReader: () -> LoopbackDestinationPolicy

    init(
        responseOverrideStore: ResponseOverrideStore,
        bookmarkStore: any BookmarkStore,
        bookmarkExecutor: (any BookmarkExecuting)? = nil,
        runningProxyPort: @escaping () -> UInt16? = { nil },
        restorer: MCPRecoveryRestorer,
        throttleConfigurationReader: @escaping () -> NetworkThrottleConfiguration,
        throttleConfigurationWriter: @escaping (NetworkThrottleConfiguration) -> Void,
        loopbackPolicyReader: @escaping () -> LoopbackDestinationPolicy = { .disabled }
    ) {
        self.responseOverrideStore = responseOverrideStore
        self.bookmarkStore = bookmarkStore
        self.bookmarkExecutor = bookmarkExecutor
        self.runningProxyPort = runningProxyPort
        self.restorer = restorer
        self.throttleConfigurationReader = throttleConfigurationReader
        self.throttleConfigurationWriter = throttleConfigurationWriter
        self.loopbackPolicyReader = loopbackPolicyReader
    }

    func apply(
        fault: MCPScenarioFault,
        faultIndex: Int,
        clientID: String,
        scenarioID: MCPScenarioID
    ) async throws -> MCPFaultApplyReceipt {
        let provenance = scenarioProvenance(clientID: clientID, scenarioID: scenarioID, fault: fault)
        switch fault {
        case .block(let matcher, let statusCode, let dropConnection):
            let ruleID = UUID()
            let rule = ResponseOverrideRule(
                id: ruleID,
                label: "scenario:\(scenarioID.rawValue)",
                requestMethod: matcher.method,
                requestScheme: matcher.scheme,
                host: matcher.host,
                port: matcher.port,
                path: matcher.path,
                matchMode: matcher.matchMode,
                sourceKind: .block,
                sourceDescription: ResponseOverrideSourceKind.block.sourceDescription,
                statusCode: statusCode,
                headers: [],
                bodySource: .inline(nil),
                isEnabled: true,
                mcpOrigin: .mcp,
                mcpProvenance: provenance,
                dropConnection: dropConnection
            )
            try await responseOverrideStore.addRule(MCPTargetRevisionFingerprint.ruleByApplyingRevision(rule))
            return MCPFaultApplyReceipt(
                transactionID: "",
                inventoryTargetID: ruleID.uuidString,
                effectKind: .block,
                faultIndex: faultIndex
            )

        case .mapLocal(let matcher, let bodyText, let contentType, let statusCode):
            let ruleID = UUID()
            let headers = [HTTPHeaderField(name: "Content-Type", value: contentType)]
            let rule = ResponseOverrideRule(
                id: ruleID,
                label: "scenario:\(scenarioID.rawValue)",
                requestMethod: matcher.method,
                requestScheme: matcher.scheme,
                host: matcher.host,
                port: matcher.port,
                path: matcher.path,
                matchMode: matcher.matchMode,
                sourceKind: .inlineText,
                sourceDescription: ResponseOverrideSourceKind.inlineText.sourceDescription,
                statusCode: statusCode,
                headers: headers,
                bodySource: .inline(bodyText.data(using: .utf8)),
                isEnabled: true,
                mcpOrigin: .mcp,
                mcpProvenance: provenance
            )
            try await responseOverrideStore.addRule(MCPTargetRevisionFingerprint.ruleByApplyingRevision(rule))
            return MCPFaultApplyReceipt(
                transactionID: "",
                inventoryTargetID: ruleID.uuidString,
                effectKind: .mapLocal,
                faultIndex: faultIndex
            )

        case .mapRemote(let matcher, let remoteHost, let remotePort, let remoteScheme, let remotePath, let remoteQueryPolicy, let remoteQuery, let allowLoopbackDestination, let preserveHostHeader):
            let allowLoopback = allowLoopbackDestination ?? false
            let preserveHost = preserveHostHeader ?? false
            do {
                try MCPMutationValidator.validateMapRemoteDestination(
                    host: remoteHost,
                    port: remotePort,
                    scheme: remoteScheme,
                    allowLoopbackDestination: allowLoopback,
                    policy: loopbackPolicyReader(),
                    reservedRegistry: .shared
                )
            } catch let error as MCPMutationValidationError {
                throw MCPScenarioFaultApplicatorError.storeWriteFailed(
                    MCPMutationValidator.structuredError(for: error).message
                )
            }
            let ruleID = UUID()
            let resolvedPort = remotePort ?? defaultPort(for: remoteScheme)
            let normalizedHost = LoopbackAddressInspector.stripBracketsAndTrailingDot(remoteHost).host
            let effectiveHost = normalizedHost.isEmpty ? remoteHost.lowercased() : normalizedHost
            let description = "\(ResponseOverrideSourceKind.mapRemote.sourceDescription): \(remoteScheme.rawValue)://\(effectiveHost):\(resolvedPort)\(remotePath ?? "")"
            let rule = ResponseOverrideRule(
                id: ruleID,
                label: "scenario:\(scenarioID.rawValue)",
                requestMethod: matcher.method,
                requestScheme: matcher.scheme,
                host: matcher.host,
                port: matcher.port,
                path: matcher.path,
                matchMode: matcher.matchMode,
                sourceKind: .mapRemote,
                sourceDescription: description,
                statusCode: 200,
                headers: [],
                bodySource: .inline(nil),
                isEnabled: true,
                mapRemoteHost: effectiveHost,
                mapRemotePort: resolvedPort,
                mapRemoteScheme: remoteScheme,
                mapRemotePath: remotePath,
                mapRemoteQueryPolicy: remoteQueryPolicy,
                mapRemoteQuery: remoteQuery,
                allowLoopbackDestination: allowLoopback,
                preserveHostHeader: preserveHost,
                mcpOrigin: .mcp,
                mcpProvenance: provenance
            )
            try await responseOverrideStore.addRule(MCPTargetRevisionFingerprint.ruleByApplyingRevision(rule))
            return MCPFaultApplyReceipt(
                transactionID: "",
                inventoryTargetID: ruleID.uuidString,
                effectKind: .mapRemote,
                faultIndex: faultIndex
            )

        case .bookmarkRewrite(let bookmarkID, let jsonPath, let overrideValue):
            var bookmarks = bookmarkStore.loadBookmarks()
            guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
                throw MCPScenarioFaultApplicatorError.bookmarkNotFound(bookmarkID)
            }
            var bookmark = bookmarks[index]
            let rewriteID: UUID
            if let existingIndex = bookmark.responseRewrites.firstIndex(where: { $0.jsonPath == jsonPath }) {
                rewriteID = bookmark.responseRewrites[existingIndex].id
                bookmark.responseRewrites[existingIndex].overrideValue = overrideValue
                bookmark.responseRewrites[existingIndex].isRuleEnabled = true
            } else {
                let rewrite = BookmarkResponseFieldRewrite(
                    id: UUID(),
                    jsonPath: jsonPath,
                    overrideValue: overrideValue,
                    isRuleEnabled: true
                )
                rewriteID = rewrite.id
                bookmark.responseRewrites.append(rewrite)
            }
            bookmark.mcpOrigin = .mcp
            bookmark.mcpProvenance = provenance
            bookmarks[index] = MCPTargetRevisionFingerprint.bookmarkByApplyingRevision(bookmark)
            try MCPBookmarkStoreSupport.saveBookmarks(
                bookmarks,
                to: bookmarkStore,
                applyingRevisionToUpdated: bookmarks[index],
                provenance: provenance,
                origin: .mcp
            )
            return MCPFaultApplyReceipt(
                transactionID: "",
                inventoryTargetID: "\(bookmarkID.uuidString):\(rewriteID.uuidString)",
                effectKind: .bookmarkRewrite,
                faultIndex: faultIndex
            )

        case .throttle(let configuration):
            var merged = MCPThrottleStoreSupport.normalizedConfiguration(
                configuration,
                provenance: provenance,
                origin: .mcp
            )
            merged.isEnabled = true
            throttleConfigurationWriter(MCPTargetRevisionFingerprint.throttleByApplyingRevision(merged))
            return MCPFaultApplyReceipt(
                transactionID: "",
                inventoryTargetID: "throttle",
                effectKind: .throttle,
                faultIndex: faultIndex
            )

        case .replay(let bookmarkID):
            guard let bookmarkExecutor else {
                throw MCPScenarioFaultApplicatorError.unsupportedFault("Replay faults require bookmark execution.")
            }
            guard let bookmark = bookmarkStore.loadBookmarks().first(where: { $0.id == bookmarkID }) else {
                throw MCPScenarioFaultApplicatorError.bookmarkNotFound(bookmarkID)
            }
            guard let proxyPort = runningProxyPort() else {
                throw MCPScenarioFaultApplicatorError.storeWriteFailed("Proxy is not running for replay fault.")
            }
            _ = try await bookmarkExecutor.execute(
                bookmark: bookmark,
                proxyPort: proxyPort,
                stripCredentials: true
            )
            return MCPFaultApplyReceipt(
                transactionID: "",
                inventoryTargetID: "replay:\(bookmarkID.uuidString)",
                effectKind: .bookmarkRewrite,
                faultIndex: faultIndex
            )

        case .jsonRewrite:
            throw MCPScenarioFaultApplicatorError.unsupportedFault(
                "JSON rewrite scenario faults are not yet supported by the fault applicator."
            )
        }
    }

    func rollback(fault: MCPScenarioFault, receipt: MCPFaultApplyReceipt) async throws {
        try await revert(receipt: receipt.persisted(faultIndex: receipt.faultIndex), fault: fault)
    }

    func revert(receipt: MCPScenarioAppliedFaultReceipt, fault: MCPScenarioFault? = nil) async throws {
        if receipt.inventoryTargetID.hasPrefix("replay:") {
            return
        }
        let item = MCPEffectInventoryItem(
            id: receipt.inventoryTargetID,
            kind: receipt.effectKind,
            displayLabel: receipt.inventoryTargetID,
            sanitizedTarget: receipt.inventoryTargetID,
            isEnabled: true,
            mcpOrigin: .mcp,
            clientID: nil,
            canRestore: false,
            canDetach: false
        )
        try await restorer.delete(item: item)
    }

    private func scenarioProvenance(
        clientID: String,
        scenarioID: MCPScenarioID,
        fault: MCPScenarioFault
    ) -> MCPProvenance {
        MCPProvenance(
            clientID: clientID,
            operationID: "scenario:\(scenarioID.rawValue)",
            capability: fault.capabilityID,
            createdAt: Date()
        )
    }

    private func defaultPort(for scheme: SessionScheme) -> Int {
        scheme == .https ? 443 : 80
    }
}
