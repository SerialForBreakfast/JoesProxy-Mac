//
//  FaultBisectionEngine.swift
//  JoesProxy
//
//  Deterministic state machine and binary search algorithm for AI Fault Bisection.
//

import Foundation

enum FaultBisectionEngine {

    // MARK: - Scope Discovery

    /// Analyzes the capture history around an anchor session to build the bisection candidate scope.
    static func buildCandidateScope(
        anchorSession: SessionRecord,
        allSessions: [SessionRecord],
        windowSeconds: TimeInterval = 30.0
    ) -> FaultBisectionCandidateScope {
        let anchorTime = anchorSession.timing.startedAt
        let windowStart = anchorTime.addingTimeInterval(-windowSeconds)
        let windowEnd = anchorTime.addingTimeInterval(5.0)

        let windowSessions = allSessions.filter { session in
            let startedAt = session.timing.startedAt
            guard startedAt >= windowStart && startedAt <= windowEnd else { return false }

            // Filter out static media assets
            let path = session.request.path.lowercased()
            let mediaType = MediaDetector.mediaType(for: session)
            if mediaType.isImage || path.contains(".ts") || path.contains(".m4s") || path.contains(".mp4") || path.contains(".png") || path.contains(".jpg") || path.contains(".woff") {
                return false
            }
            return true
        }.sorted(by: { $0.timing.startedAt < $1.timing.startedAt })

        var endpointMap: [String: (method: String, host: String, path: String, ids: [UUID], status: Int?, contentType: String?, isJSON: Bool)] = [:]

        for session in windowSessions {
            let method = session.request.method.uppercased()
            let host = session.request.host.lowercased()
            let path = session.request.path
            let key = "\(method) \(host)\(path)"

            let contentType = session.response?.headers.first(where: { $0.name.caseInsensitiveCompare("content-type") == .orderedSame })?.value
            let isJSON = contentType?.lowercased().contains("json") == true || (session.response?.bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) } != nil)

            if var existing = endpointMap[key] {
                existing.ids.append(session.id)
                endpointMap[key] = existing
            } else {
                endpointMap[key] = (method, host, path, [session.id], session.response?.statusCode, contentType, isJSON)
            }
        }

        let candidates = endpointMap.values.map { entry in
            BisectionEndpointCandidate(
                method: entry.method,
                host: entry.host,
                path: entry.path,
                sessionIDs: entry.ids,
                statusCode: entry.status,
                contentType: entry.contentType,
                isJSON: entry.isJSON
            )
        }.sorted(by: { $0.path < $1.path })

        return FaultBisectionCandidateScope(
            anchorSessionID: anchorSession.id,
            windowDuration: windowSeconds,
            candidateSessionIDs: windowSessions.map { $0.id },
            distinctEndpoints: candidates
        )
    }

    // MARK: - Next Action Planning

    /// Computes the next actionable bisection step given the candidate scope and previous step results.
    static func nextAction(
        scope: FaultBisectionCandidateScope,
        priorSteps: [BisectionStepResult]
    ) -> BisectionNextAction {
        let stepNumber = priorSteps.count + 1
        let candidates = scope.distinctEndpoints

        guard !candidates.isEmpty else {
            return BisectionNextAction(
                stepNumber: stepNumber,
                kind: .candidateWindow,
                targetEndpoints: [],
                fieldMutation: nil,
                actionDescription: "No candidate endpoints found in the sliding window.",
                isTerminal: true
            )
        }

        // Tier 1 & 2: Binary Partition of Endpoints
        var activeCandidates = candidates
        for step in priorSteps {
            if step.kind == .binaryPartition {
                if step.clientOutcome == .crashed || step.clientOutcome == .failedAssertion {
                    // Culprit is in the tested partition
                    activeCandidates = activeCandidates.filter { step.testedEndpoints.contains($0.id) }
                } else if step.clientOutcome == .succeeded {
                    // Culprit is in the other partition
                    activeCandidates = activeCandidates.filter { !step.testedEndpoints.contains($0.id) }
                }
            }
        }

        if activeCandidates.count > 1 {
            let half = max(1, activeCandidates.count / 2)
            let partition = Array(activeCandidates.prefix(half))
            return BisectionNextAction(
                stepNumber: stepNumber,
                kind: .binaryPartition,
                targetEndpoints: partition,
                fieldMutation: nil,
                actionDescription: "Testing partition of \(partition.count) candidate endpoints (\(partition.map { $0.path }.joined(separator: ", "))).",
                isTerminal: false
            )
        }

        guard let culprit = activeCandidates.first else {
            return BisectionNextAction(
                stepNumber: stepNumber,
                kind: .verification,
                targetEndpoints: [],
                fieldMutation: nil,
                actionDescription: "Bisection concluded without isolating a consistent culprit.",
                isTerminal: true
            )
        }

        // Tier 3: Field-Level Mutation Bisection
        let fieldSteps = priorSteps.filter { $0.kind == .jsonFieldMutation }
        let completedFieldPaths = Set(fieldSteps.compactMap { $0.testedFieldMutation?.formattedKeyPath })

        // Check for field mutations if candidate is JSON
        if culprit.isJSON {
            // Generate standard candidate field mutations
            let candidateMutations = sampleFieldMutations(for: culprit)
            if let nextMutation = candidateMutations.first(where: { !completedFieldPaths.contains($0.formattedKeyPath) }) {
                return BisectionNextAction(
                    stepNumber: stepNumber,
                    kind: .jsonFieldMutation,
                    targetEndpoints: [culprit],
                    fieldMutation: nextMutation,
                    actionDescription: "Testing field-level mutation on '\(nextMutation.formattedKeyPath)' (\(nextMutation.mutationType.rawValue)).",
                    isTerminal: false
                )
            }
        }

        // Final Terminal Step
        return BisectionNextAction(
            stepNumber: stepNumber,
            kind: .verification,
            targetEndpoints: [culprit],
            fieldMutation: nil,
            actionDescription: "Root cause isolated on \(culprit.displayTitle).",
            isTerminal: true
        )
    }

    // MARK: - JSON Mutation Synthesis

    /// Recursively extracts candidate keys from JSON data to test for client deserialization faults.
    static func generateFieldMutations(jsonData: Data) -> [JSONFieldMutation] {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) else {
            return []
        }

        var mutations: [JSONFieldMutation] = []
        extractMutations(from: jsonObject, currentPath: [], output: &mutations)
        return mutations
    }

    private static func extractMutations(
        from object: Any,
        currentPath: [String],
        output: inout [JSONFieldMutation]
    ) {
        guard currentPath.count <= 3 else { return }

        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                let nextPath = currentPath + [key]
                output.append(
                    JSONFieldMutation(
                        keyPath: nextPath,
                        mutationType: .nullify,
                        originalValueSummary: "\(value)",
                        mutatedValueSummary: "null"
                    )
                )
                output.append(
                    JSONFieldMutation(
                        keyPath: nextPath,
                        mutationType: .omitKey,
                        originalValueSummary: "\(value)",
                        mutatedValueSummary: "<omitted>"
                    )
                )
                extractMutations(from: value, currentPath: nextPath, output: &output)
            }
        } else if let array = object as? [Any], let first = array.first {
            let nextPath = currentPath + ["0"]
            extractMutations(from: first, currentPath: nextPath, output: &output)
        }
    }

    // MARK: - Finding Synthesis

    /// Synthesizes an executive Root Cause Finding from the step results.
    static func synthesizeFinding(
        anchorSession: SessionRecord,
        culprit: BisectionEndpointCandidate,
        steps: [BisectionStepResult]
    ) -> FaultBisectionFinding {
        let fieldStep = steps.first(where: { $0.kind == .jsonFieldMutation && ($0.clientOutcome == .crashed || $0.clientOutcome == .failedAssertion) })
        let culpritKey = fieldStep?.testedFieldMutation?.formattedKeyPath

        let exactFault: String
        if let key = culpritKey {
            exactFault = "Upstream response on '\(key)' failed client expectation (observed crash on mutation)."
        } else {
            exactFault = "Upstream endpoint '\(culprit.displayTitle)' returned unexpected status or response format."
        }

        let observedError = steps.compactMap { $0.logSnippets.first }.first ?? "Client encountered unexpected error or crash."

        let curlCmd = "curl -X \(culprit.method) 'https://\(culprit.host)\(culprit.path)' -H 'Accept: application/json'"

        let proposedMock: String
        if let key = culpritKey {
            proposedMock = "{\n  \"\(key)\": \"default_mock_value\"\n}"
        } else {
            proposedMock = "{\n  \"status\": \"ok\"\n}"
        }

        return FaultBisectionFinding(
            culpritEndpoint: culprit,
            culpritKeyPath: culpritKey,
            exactWireFault: exactFault,
            observedClientError: observedError,
            confidenceScore: 0.95,
            proposedFixTitle: "Mock \(culprit.displayTitle) with valid \(culpritKey ?? "payload")",
            proposedMockJSON: proposedMock,
            curlReproducer: curlCmd
        )
    }

    // MARK: - Helpers

    private static func sampleFieldMutations(for candidate: BisectionEndpointCandidate) -> [JSONFieldMutation] {
        [
            JSONFieldMutation(keyPath: ["data"], mutationType: .nullify, originalValueSummary: "{}", mutatedValueSummary: "null"),
            JSONFieldMutation(keyPath: ["status"], mutationType: .omitKey, originalValueSummary: "ok", mutatedValueSummary: nil),
            JSONFieldMutation(keyPath: ["id"], mutationType: .nullify, originalValueSummary: "123", mutatedValueSummary: "null")
        ]
    }
}
