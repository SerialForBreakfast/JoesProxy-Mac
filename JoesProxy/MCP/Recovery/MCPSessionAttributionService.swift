import Foundation

/// Creates and applies immutable MCP capture attribution on session responses.
///
/// Concurrency: stateless helpers safe to call from the proxy capture path on any executor.
enum MCPSessionAttributionService {
    /// Returns attribution when an MCP-owned effect is active for the response path.
    ///
    /// - Parameter scenarioID: set when the matched target's fault is currently owned by a
    ///   running scenario (AI-2's `MCPScenarioExecutor.activeScenarioID(forTargetLockKey:)`).
    ///   Callers that don't yet look this up may omit it — defaults to `nil`, matching the prior
    ///   behavior exactly, so this is purely additive.
    static func attributionForActiveEffects(
        effectKinds: [MCPEffectKind],
        provenance: MCPProvenance,
        scenarioID: String? = nil,
        measurementContext: MCPMeasurementContext? = nil,
        openAPIMockPackID: String? = nil,
        openAPIMockOperation: String? = nil,
        openAPIMockVariantID: String? = nil
    ) -> MCPCaptureAttribution? {
        let resolvedMeasurementContext = measurementContext ?? (MCPMeasurementSuspensionGate.isActive ? .effectsSuspended : nil)
        guard !effectKinds.isEmpty || resolvedMeasurementContext != nil else {
            return nil
        }
        return MCPCaptureAttribution(
            provenance: provenance,
            effectKinds: effectKinds,
            scenarioID: scenarioID,
            measurementContext: resolvedMeasurementContext,
            openAPIMockPackID: openAPIMockPackID,
            openAPIMockOperation: openAPIMockOperation,
            openAPIMockVariantID: openAPIMockVariantID
        )
    }

    /// Stamps measurement-only attribution when interlock suspended effects but no MCP effect applied.
    static func measurementSuspensionAttributionIfNeeded(on response: CapturedResponse) -> CapturedResponse {
        guard MCPMeasurementSuspensionGate.isActive else {
            return response
        }
        if var existing = response.mcpAttribution {
            existing.measurementContext = .effectsSuspended
            return stampedResponse(response, attribution: existing)
        }
        let attribution = MCPCaptureAttribution(
            provenance: MCPProvenance(
                clientID: "diagnostic-interlock",
                operationID: "measurement-suspension",
                capability: .sessionSummary,
                createdAt: Date()
            ),
            effectKinds: [],
            scenarioID: nil,
            measurementContext: .effectsSuspended
        )
        return stampedResponse(response, attribution: attribution)
    }

    /// Stamps immutable attribution on a captured response when not already present.
    static func stampedResponse(
        _ response: CapturedResponse,
        attribution: MCPCaptureAttribution
    ) -> CapturedResponse {
        guard response.mcpAttribution == nil else {
            return response
        }
        return CapturedResponse(
            statusCode: response.statusCode,
            headers: response.headers,
            bodyData: response.bodyData,
            bodySize: response.bodySize,
            source: response.source,
            sourceDescription: response.sourceDescription,
            bodyTruncated: response.bodyTruncated,
            recordingBodyOmissionReason: response.recordingBodyOmissionReason,
            bodyDeferred: response.bodyDeferred,
            mcpAttribution: attribution
        )
    }

    /// Applies attribution to a session record's response when present.
    static func stampedSession(
        _ session: SessionRecord,
        attribution: MCPCaptureAttribution
    ) -> SessionRecord {
        guard let response = session.response else {
            return session
        }
        var updated = session
        updated.response = stampedResponse(response, attribution: attribution)
        return updated
    }
}

/// Response override persistence helpers for MCP provenance and semantic revision tracking.
enum MCPResponseOverrideStoreSupport {
    static func normalizedRules(
        _ rules: [ResponseOverrideRule],
        applyingRevisionToUpdated updated: ResponseOverrideRule? = nil,
        provenance: MCPProvenance? = nil,
        origin: MCPObjectOrigin? = nil
    ) -> [ResponseOverrideRule] {
        rules.map { rule in
            var copy = rule
            if let updated, updated.id == rule.id {
                copy = updated
            }
            if let provenance, copy.id == updated?.id {
                copy.mcpProvenance = provenance
                copy.mcpOrigin = origin ?? .mcp
            }
            return MCPTargetRevisionFingerprint.ruleByApplyingRevision(copy)
        }
    }
}

/// Throttle configuration helpers for MCP provenance and semantic revision tracking.
enum MCPThrottleStoreSupport {
    static func normalizedConfiguration(
        _ configuration: NetworkThrottleConfiguration,
        provenance: MCPProvenance? = nil,
        origin: MCPObjectOrigin? = nil
    ) -> NetworkThrottleConfiguration {
        var copy = configuration
        if let provenance {
            copy.mcpProvenance = provenance
            copy.mcpOrigin = origin ?? .mcp
        }
        return MCPTargetRevisionFingerprint.throttleByApplyingRevision(copy)
    }
}

/// Recording round-trip helpers for MCP capture attribution.
enum MCPRecordingAttributionSupport {
    static func encodeSessions(_ sessions: [SessionRecord]) throws -> Data {
        try JSONEncoder().encode(sessions)
    }

    static func decodeSessions(from data: Data) throws -> [SessionRecord] {
        try JSONDecoder().decode([SessionRecord].self, from: data)
    }

    static func wrappedRecordingPayload(_ sessions: [SessionRecord]) throws -> Data {
        let json = try encodeSessions(sessions)
        return try RecordingContainer.wrap(json)
    }

    static func unwrappedRecordingPayload(_ data: Data) throws -> Data {
        try RecordingContainer.unwrap(data)
    }
}
