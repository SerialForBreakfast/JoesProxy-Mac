import Foundation

enum MCPScenarioCompilerError: Error, Equatable, Sendable {
    case unsupportedFaultCombination(String)
    case ambiguousTarget(String)
    case unsafeDestination(String)
    case missingCleanup(String)
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case malformed(String)
    case policyDenied(String)
}

/// Raw staging input for a scenario draft. Real field population is AI-4's job (a `draft_test_scenario`
/// tool); this shape exists now so `MCPScenarioCompiler.compile` has a stable, testable input type.
struct MCPScenarioDraftInput: Equatable, Sendable, Codable {
    var id: MCPScenarioID
    var schemaVersion: Int
    var name: String
    var purpose: String
    var originatingClientID: String
    var target: MCPScenarioTarget
    var preconditions: [MCPScenarioPrecondition]
    var captureScope: MCPScenarioCaptureScope
    var disclosureProfileID: MCPDisclosureProfileID
    var faults: [MCPScenarioFault]
    var duration: TimeInterval?
    var expiresAt: Date?
    var observationWindow: MCPScenarioObservationWindow
    var assertions: [MCPScenarioAssertion]
    var assertionSeverity: MCPScenarioAssertionSeverity
    var evidenceRetentionSpec: MCPScenarioEvidenceRetentionSpec
    var cleanupActions: [MCPScenarioCleanupAction]
}

extension MCPScenarioDraftInput {
    /// Reconstructs draft input from a stored definition so validation can re-run compile checks.
    static func fromDefinition(_ definition: MCPScenarioDefinition) -> MCPScenarioDraftInput {
        MCPScenarioDraftInput(
            id: definition.id,
            schemaVersion: definition.schemaVersion,
            name: definition.name,
            purpose: definition.purpose,
            originatingClientID: definition.originatingClientID,
            target: definition.target,
            preconditions: definition.preconditions,
            captureScope: definition.captureScope,
            disclosureProfileID: definition.disclosureProfileID,
            faults: definition.faults,
            duration: definition.duration,
            expiresAt: definition.expiresAt,
            observationWindow: definition.observationWindow,
            assertions: definition.assertions,
            assertionSeverity: definition.assertionSeverity,
            evidenceRetentionSpec: definition.evidenceRetentionSpec,
            cleanupActions: definition.cleanupActions
        )
    }
}

struct MCPScenarioApprovalDisclosureDTO: Equatable, Sendable, Codable {
    var riskTier: String
    var affectedTargetKeys: [String]
    var faultSummaries: [String]
    /// Empty unless a composed fault is open-world tier (parent ADR: destination/method/credential
    /// policy must be computed and disclosed at validate/approval time, not discovered later).
    var openWorldDisclosures: [MCPOpenWorldDisclosureDTO]
    var cleanupSummary: [String]
}

/// JSON decode/encode helpers for agent-authored scenario drafts (AI-0).
enum MCPScenarioJSONCodec {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decodeDraft(from data: Data) throws -> MCPScenarioDraftInput {
        try makeDecoder().decode(MCPScenarioDraftInput.self, from: data)
    }

    static func encodeDraft(_ draft: MCPScenarioDraftInput) throws -> Data {
        try makeEncoder().encode(draft)
    }
}

/// Normalizes and validates a scenario draft, computes its highest composed risk tier and affected
/// target set, and produces the exact approval disclosure payload before arming (AI-0).
///
/// Deliberately reuses `MCPMutationValidator`'s existing static per-fault checks rather than
/// reimplementing scope/safety logic — that is the concrete mechanism guaranteeing a scenario
/// fault can never expand scope beyond what the standalone propose/apply tool would already reject.
enum MCPScenarioCompiler {
    /// Copies draft fields into a definition without compile-time validation — used when persisting
    /// a new `.draft` record before `validate` runs the full compiler (AI-1).
    static func materializeDraft(
        _ draft: MCPScenarioDraftInput,
        createdAt: Date = Date()
    ) -> MCPScenarioDefinition {
        MCPScenarioDefinition(
            id: draft.id,
            schemaVersion: draft.schemaVersion,
            name: draft.name,
            purpose: draft.purpose,
            originatingClientID: draft.originatingClientID,
            target: draft.target,
            preconditions: draft.preconditions,
            captureScope: draft.captureScope,
            disclosureProfileID: draft.disclosureProfileID,
            faults: draft.faults,
            duration: draft.duration,
            expiresAt: draft.expiresAt,
            observationWindow: draft.observationWindow,
            assertions: draft.assertions,
            assertionSeverity: draft.assertionSeverity,
            evidenceRetentionSpec: draft.evidenceRetentionSpec,
            cleanupActions: draft.cleanupActions,
            createdAt: createdAt
        )
    }

    static func compile(
        draft: MCPScenarioDraftInput,
        now: Date = Date(),
        loopbackPolicy: LoopbackDestinationPolicy = .disabled
    ) throws -> MCPScenarioDefinition {
        guard draft.schemaVersion == MCPScenarioSchemaVersion.current else {
            throw MCPScenarioCompilerError.unsupportedSchemaVersion(
                found: draft.schemaVersion,
                supported: MCPScenarioSchemaVersion.current
            )
        }
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPScenarioCompilerError.malformed("Scenario name is required.")
        }
        guard !draft.faults.isEmpty else {
            throw MCPScenarioCompilerError.malformed("A scenario must compose at least one fault.")
        }
        guard draft.faults.count <= MCPScenarioResourceBudget.maxFaults else {
            throw MCPScenarioCompilerError.malformed(
                "A scenario may compose at most \(MCPScenarioResourceBudget.maxFaults) faults."
            )
        }
        guard draft.assertions.count <= MCPScenarioResourceBudget.maxAssertions else {
            throw MCPScenarioCompilerError.malformed(
                "A scenario may declare at most \(MCPScenarioResourceBudget.maxAssertions) assertions."
            )
        }
        guard draft.disclosureProfileID.isSelectableInPhase1 else {
            throw MCPScenarioCompilerError.policyDenied(
                "Disclosure profile '\(draft.disclosureProfileID.rawValue)' is not selectable in Phase 1."
            )
        }

        try validateTiming(draft, now: now)
        try validateEvidenceRetention(draft.evidenceRetentionSpec)
        try validateTarget(draft.target)
        try validateCaptureScope(draft.captureScope, target: draft.target)
        try validatePreconditions(draft.preconditions)
        try validateAssertions(draft.assertions)
        try validateFaults(draft.faults, target: draft.target, loopbackPolicy: loopbackPolicy)
        try validateCleanupCoverage(faults: draft.faults, cleanupActions: draft.cleanupActions)

        return MCPScenarioDefinition(
            id: draft.id,
            schemaVersion: draft.schemaVersion,
            name: draft.name,
            purpose: draft.purpose,
            originatingClientID: draft.originatingClientID,
            target: draft.target,
            preconditions: draft.preconditions,
            captureScope: draft.captureScope,
            disclosureProfileID: draft.disclosureProfileID,
            faults: draft.faults,
            duration: draft.duration,
            expiresAt: draft.expiresAt,
            observationWindow: draft.observationWindow,
            assertions: draft.assertions,
            assertionSeverity: draft.assertionSeverity,
            evidenceRetentionSpec: draft.evidenceRetentionSpec,
            cleanupActions: draft.cleanupActions,
            createdAt: now
        )
    }

    /// Highest-risk capability across all composed faults — NOT a static per-capability mapping.
    static func riskTier(for definition: MCPScenarioDefinition) -> MCPCapabilityRiskTier {
        definition.faults
            .map(\.capabilityID.riskTier)
            .max { $0.severityRank < $1.severityRank }
            ?? .mutatingTool
    }

    static func affectedTargetKeys(for definition: MCPScenarioDefinition) -> Set<String> {
        Set(definition.faults.map(\.targetLockKey))
    }

    static func approvalDisclosure(for definition: MCPScenarioDefinition) -> MCPScenarioApprovalDisclosureDTO {
        let tier = riskTier(for: definition)
        let openWorldDisclosures: [MCPOpenWorldDisclosureDTO] = definition.faults.compactMap { fault in
            switch fault {
            case .mapRemote(let matcher, let remoteHost, let remotePort, let remoteScheme, let remotePath, _, _, let allowLoopbackDestination, let preserveHostHeader):
                let hostNote = (preserveHostHeader ?? false) ? "; preserve original Host" : ""
                let loopbackNote = (allowLoopbackDestination ?? false) ? " [local Mac loopback]" : ""
                return MCPOpenWorldDisclosureDTO(
                    destinationHost: remoteHost,
                    destinationPort: remotePort,
                    destinationScheme: remoteScheme.rawValue,
                    method: matcher.method,
                    includesCredentials: false,
                    expectedSideEffect: "Requests matching \(matcher.method) \(matcher.host)\(matcher.path) are remapped\(loopbackNote) to \(remoteHost)\(remotePath.map { " at \($0)" } ?? ", same path")\(hostNote).",
                    riskTier: MCPCapabilityRiskTier.openWorldTool.rawValue,
                    targetID: fault.targetLockKey
                )
            case .replay(let bookmarkID):
                return MCPOpenWorldDisclosureDTO(
                    destinationHost: "bookmark:\(bookmarkID.uuidString)",
                    destinationPort: nil,
                    destinationScheme: nil,
                    method: "REPLAY",
                    includesCredentials: false,
                    expectedSideEffect: "Replays saved bookmark \(bookmarkID.uuidString) against the live proxy.",
                    riskTier: MCPCapabilityRiskTier.openWorldTool.rawValue,
                    targetID: fault.targetLockKey
                )
            case .jsonRewrite(let matcher, let jsonPath, let overrideValue, let operation):
                let upstreamPort = matcher.port ?? (matcher.scheme == .https ? 443 : 80)
                let rewriteSummary = "\(jsonPath) \(operation.rawValue) \(overrideValue.disclosureDescriptor)"
                return MCPOpenWorldDisclosureDTO(
                    destinationHost: matcher.host,
                    destinationPort: upstreamPort,
                    destinationScheme: matcher.scheme.rawValue,
                    method: matcher.method,
                    includesCredentials: false,
                    expectedSideEffect: "Enable live response rewrite: matching requests reach \(matcher.scheme.rawValue)://\(matcher.host):\(upstreamPort); response JSON may be patched (\(rewriteSummary)).",
                    riskTier: MCPCapabilityRiskTier.openWorldTool.rawValue,
                    targetID: fault.targetLockKey
                )
            case .block, .mapLocal, .bookmarkRewrite, .throttle:
                return nil
            }
        }
        return MCPScenarioApprovalDisclosureDTO(
            riskTier: tier.rawValue,
            affectedTargetKeys: Array(affectedTargetKeys(for: definition)).sorted(),
            faultSummaries: definition.faults.enumerated().map { index, fault in
                "\(index): \(fault.effectKind.rawValue) @ \(fault.targetLockKey)"
            },
            openWorldDisclosures: openWorldDisclosures,
            cleanupSummary: definition.cleanupActions
                .sorted { $0.faultIndex < $1.faultIndex }
                .map { "\($0.faultIndex): \($0.kind.rawValue)" }
        )
    }

    static func structuredError(for error: MCPScenarioCompilerError) -> MCPStructuredError {
        switch error {
        case .unsupportedFaultCombination(let message):
            return MCPStructuredError(code: .malformedRequest, message: message)
        case .ambiguousTarget(let message):
            return MCPStructuredError(code: .malformedRequest, message: message)
        case .unsafeDestination(let message):
            return MCPStructuredError(code: .policyDenied, message: message)
        case .missingCleanup(let message):
            return MCPStructuredError(code: .malformedRequest, message: message)
        case .unsupportedSchemaVersion(let found, let supported):
            return MCPStructuredError(
                code: .malformedRequest,
                message: "Unsupported scenario schema version \(found); supported version is \(supported)."
            )
        case .malformed(let message):
            return MCPStructuredError(code: .malformedRequest, message: message)
        case .policyDenied(let message):
            return MCPStructuredError(code: .policyDenied, message: message)
        }
    }

    // MARK: - Private validation

    private static func validateTiming(_ draft: MCPScenarioDraftInput, now: Date) throws {
        if let expiresAt = draft.expiresAt, expiresAt <= now {
            throw MCPScenarioCompilerError.malformed("Scenario expiration must be in the future.")
        }
        if let duration = draft.duration {
            guard duration > 0, duration <= MCPScenarioResourceBudget.maxDurationSeconds else {
                throw MCPScenarioCompilerError.malformed(
                    "Scenario duration must be positive and at most \(Int(MCPScenarioResourceBudget.maxDurationSeconds)) seconds."
                )
            }
        }
        let windowDuration = draft.observationWindow.duration
        guard windowDuration > 0, windowDuration <= MCPScenarioResourceBudget.maxObservationWindowSeconds else {
            throw MCPScenarioCompilerError.malformed(
                "Observation window duration must be positive and at most \(Int(MCPScenarioResourceBudget.maxObservationWindowSeconds)) seconds."
            )
        }
        guard !draft.observationWindow.startTrigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPScenarioCompilerError.malformed("Observation window startTrigger is required.")
        }
    }

    private static func validateEvidenceRetention(_ spec: MCPScenarioEvidenceRetentionSpec) throws {
        guard spec.maxRecords > 0, spec.maxRecords <= MCPScenarioResourceBudget.maxEvidenceRecords else {
            throw MCPScenarioCompilerError.malformed(
                "Evidence maxRecords must be between 1 and \(MCPScenarioResourceBudget.maxEvidenceRecords)."
            )
        }
        guard spec.retention > 0, spec.retention <= MCPScenarioResourceBudget.maxEvidenceRetentionSeconds else {
            throw MCPScenarioCompilerError.malformed(
                "Evidence retention must be positive and at most \(Int(MCPScenarioResourceBudget.maxEvidenceRetentionSeconds)) seconds."
            )
        }
    }

    private static func validateTarget(_ target: MCPScenarioTarget) throws {
        guard !target.hosts.isEmpty else {
            throw MCPScenarioCompilerError.ambiguousTarget("A scenario target must declare at least one host.")
        }
        for host in target.hosts {
            let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.isEmpty || normalized == "*" || (normalized.hasPrefix("*.") && normalized.count <= 2) {
                throw MCPScenarioCompilerError.ambiguousTarget("Target host matcher '\(host)' is too broad.")
            }
        }
    }

    private static func validateCaptureScope(
        _ captureScope: MCPScenarioCaptureScope,
        target: MCPScenarioTarget
    ) throws {
        let normalizedTargetHosts = Set(
            target.hosts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
        for host in captureScope.hosts {
            let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalizedTargetHosts.contains(normalized) else {
                throw MCPScenarioCompilerError.ambiguousTarget(
                    "Capture scope host '\(host)' is not included in the scenario target hosts."
                )
            }
        }
    }

    private static func validatePreconditions(_ preconditions: [MCPScenarioPrecondition]) throws {
        for precondition in preconditions {
            if precondition.kind == .bookmarkExists {
                let detail = precondition.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !detail.isEmpty else {
                    throw MCPScenarioCompilerError.malformed(
                        "Precondition bookmarkExists requires a bookmark identifier in detail."
                    )
                }
            }
        }
    }

    private static func validateAssertions(_ assertions: [MCPScenarioAssertion]) throws {
        for (index, assertion) in assertions.enumerated() {
            if assertion.evidenceSource == .inferredCorrelation {
                let notes = assertion.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !notes.isEmpty else {
                    throw MCPScenarioCompilerError.malformed(
                        "Assertion \(index) uses inferredCorrelation and requires non-empty notes."
                    )
                }
            }
            switch assertion.kind {
            case .requestOccurred, .requestNotOccurred:
                guard assertion.matcher != nil || hasNonEmpty(assertion.host) else {
                    throw MCPScenarioCompilerError.malformed(
                        "Assertion \(index) (\(assertion.kind.rawValue)) requires a matcher or host."
                    )
                }
            case .retryCount, .retryCadence:
                guard let count = assertion.expectedCount, count >= 0 else {
                    throw MCPScenarioCompilerError.malformed(
                        "Assertion \(index) (\(assertion.kind.rawValue)) requires expectedCount >= 0."
                    )
                }
            case .fallbackHostUsed:
                guard hasNonEmpty(assertion.host) || hasNonEmpty(assertion.detail) else {
                    throw MCPScenarioCompilerError.malformed(
                        "Assertion \(index) (fallbackHostUsed) requires host or detail."
                    )
                }
            case .latencyThreshold:
                guard let threshold = assertion.thresholdSeconds, threshold > 0 else {
                    throw MCPScenarioCompilerError.malformed(
                        "Assertion \(index) (latencyThreshold) requires thresholdSeconds > 0."
                    )
                }
            case .bookmarkMatched, .overrideMatched:
                guard assertion.matcher != nil || (hasNonEmpty(assertion.host) && hasNonEmpty(assertion.path)) else {
                    throw MCPScenarioCompilerError.malformed(
                        "Assertion \(index) (\(assertion.kind.rawValue)) requires a matcher or host+path."
                    )
                }
            case .requestSequenceChanged, .mediaManifestBehaviorChanged, .mediaSegmentBehaviorChanged,
                 .ruleConflictOrBypass, .errorResponseReachedClient:
                guard hasNonEmpty(assertion.detail) || hasNonEmpty(assertion.notes) else {
                    throw MCPScenarioCompilerError.malformed(
                        "Assertion \(index) (\(assertion.kind.rawValue)) requires detail or notes."
                    )
                }
            case .sdkTestStepMarker, .externalTestStepBegin, .externalTestStepEnd:
                guard hasNonEmpty(assertion.markerName) else {
                    throw MCPScenarioCompilerError.malformed(
                        "Assertion \(index) (\(assertion.kind.rawValue)) requires markerName."
                    )
                }
            case .sdkStateTransition, .sdkErrorCategory, .sdkRetryState, .sdkPlaybackState,
                 .sdkBufferingOrStall, .sdkFallbackActivated, .sdkUserVisibleRecovery:
                guard hasNonEmpty(assertion.detail) || hasNonEmpty(assertion.markerName) else {
                    throw MCPScenarioCompilerError.malformed(
                        "Assertion \(index) (\(assertion.kind.rawValue)) requires detail or markerName."
                    )
                }
            }
        }
    }

    private static func hasNonEmpty(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func validateFaults(
        _ faults: [MCPScenarioFault],
        target: MCPScenarioTarget,
        loopbackPolicy: LoopbackDestinationPolicy = .disabled
    ) throws {
        var seenLockKeys = Set<String>()
        for fault in faults {
            guard seenLockKeys.insert(fault.targetLockKey).inserted else {
                throw MCPScenarioCompilerError.unsupportedFaultCombination(
                    "Multiple faults target the same object (\(fault.targetLockKey)); a scenario cannot compose two faults on one target."
                )
            }
        }

        let mapRemoteMatchers: [MCPMutationMatcher] = faults.compactMap {
            if case .mapRemote(let matcher, _, _, _, _, _, _, _, _) = $0 { return matcher }
            return nil
        }
        for fault in faults {
            if case .replay = fault, !mapRemoteMatchers.isEmpty {
                throw MCPScenarioCompilerError.unsupportedFaultCombination(
                    "A scenario cannot combine a replay fault with a Map Remote fault in this version."
                )
            }
        }

        let normalizedTargetHosts = Set(target.hosts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })

        for fault in faults {
            switch fault {
            case .block(let matcher, let statusCode, _):
                try requireHostInTarget(matcher.host, targetHosts: normalizedTargetHosts)
                try MCPMutationValidator.validateBlockStatusCode(statusCode)
            case .mapLocal(let matcher, let inlineBodyText, _, _):
                try requireHostInTarget(matcher.host, targetHosts: normalizedTargetHosts)
                try MCPMutationValidator.validateInlineBody(inlineBodyText)
            case .mapRemote(let matcher, let remoteHost, let remotePort, let remoteScheme, let remotePath, _, let remoteQuery, let allowLoopbackDestination, _):
                try requireHostInTarget(matcher.host, targetHosts: normalizedTargetHosts)
                try validateMapRemoteDestination(
                    host: remoteHost,
                    port: remotePort,
                    scheme: remoteScheme,
                    allowLoopbackDestination: allowLoopbackDestination ?? false,
                    loopbackPolicy: loopbackPolicy
                )
                if let remotePath {
                    try MCPMutationValidator.validateMapRemoteRequestTarget(remotePath)
                }
                if let remoteQuery {
                    try MCPMutationValidator.validateMapRemoteQuery(remoteQuery)
                }
            case .jsonRewrite:
                throw MCPScenarioCompilerError.unsupportedFaultCombination(
                    "Live/JSON response rewrite faults are not yet supported in scenario composition. " +
                    "Rule composition (ResponseOverrideStore.ruleDecision picks only the first matching " +
                    "enabled rule) has no staged pipeline yet, so a scenario cannot safely compose a " +
                    "rewrite with other faults on the same target. Use the standalone activate_live_rewrite " +
                    "tool outside of scenarios instead."
                )
            case .bookmarkRewrite(_, let jsonPath, _):
                try MCPMutationValidator.validateJSONPath(jsonPath)
            case .throttle, .replay:
                break
            }
        }
    }

    private static func requireHostInTarget(_ host: String, targetHosts: Set<String>) throws {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard targetHosts.contains(normalized) else {
            throw MCPScenarioCompilerError.ambiguousTarget(
                "Fault host '\(host)' is not a member of the scenario's declared target hosts."
            )
        }
    }

    private static func validateMapRemoteDestination(
        host: String,
        port: Int?,
        scheme: SessionScheme,
        allowLoopbackDestination: Bool = false,
        loopbackPolicy: LoopbackDestinationPolicy = .disabled
    ) throws {
        do {
            try MCPMutationValidator.validateMapRemoteDestination(
                host: host,
                port: port,
                scheme: scheme,
                allowLoopbackDestination: allowLoopbackDestination,
                policy: loopbackPolicy,
                reservedRegistry: .shared
            )
        } catch let error as MCPMutationValidationError {
            switch error {
            case .policyDenied(let message):
                throw MCPScenarioCompilerError.unsafeDestination(message)
            case .malformedRequest(let message):
                throw MCPScenarioCompilerError.unsafeDestination(message)
            case .busy:
                throw MCPScenarioCompilerError.unsafeDestination("Map Remote destination is invalid.")
            }
        }
    }

    private static func validateCleanupCoverage(
        faults: [MCPScenarioFault],
        cleanupActions: [MCPScenarioCleanupAction]
    ) throws {
        var seenIndices = Set<Int>()
        for action in cleanupActions {
            guard seenIndices.insert(action.faultIndex).inserted else {
                throw MCPScenarioCompilerError.malformed(
                    "Duplicate cleanup action for fault index \(action.faultIndex)."
                )
            }
        }

        let coveredIndices = Set(cleanupActions.map(\.faultIndex))
        let missingIndices = (0..<faults.count).filter { !coveredIndices.contains($0) }
        guard missingIndices.isEmpty else {
            throw MCPScenarioCompilerError.missingCleanup(
                "Fault index(es) \(missingIndices.sorted()) have no corresponding cleanup action."
            )
        }

        for action in cleanupActions {
            guard action.faultIndex >= 0, action.faultIndex < faults.count else {
                throw MCPScenarioCompilerError.malformed(
                    "Cleanup action references invalid fault index \(action.faultIndex)."
                )
            }
            let fault = faults[action.faultIndex]
            guard action.kind == fault.effectKind else {
                throw MCPScenarioCompilerError.missingCleanup(
                    "Cleanup action for fault \(action.faultIndex) must use kind '\(fault.effectKind.rawValue)'."
                )
            }
        }
    }
}
