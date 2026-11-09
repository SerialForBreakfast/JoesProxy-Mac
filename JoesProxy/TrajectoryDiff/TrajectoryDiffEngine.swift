//
//  TrajectoryDiffEngine.swift
//  JoesProxy
//
//  Sequence alignment, payload diffing, and behavioral divergence isolation
//  across multi-session capture trajectories.
//

import Foundation

enum TrajectoryDiffEngine {

    /// Compares two chronological session recordings to detect the exact divergence point.
    static func diffTrajectories(
        baseline: [SessionRecord],
        candidate: [SessionRecord],
        baselineName: String = "Baseline Run",
        candidateName: String = "Candidate Run",
        comparePayloadValues: Bool = true,
        includeOriginInSignature: Bool = false
    ) -> TrajectoryDiffReport {
        let startTime = Date()

        func chronological(_ lhs: SessionRecord, _ rhs: SessionRecord) -> Bool {
            if lhs.timing.startedAt == rhs.timing.startedAt { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.timing.startedAt < rhs.timing.startedAt
        }
        let sortedBaseline = baseline.sorted(by: chronological)
        let sortedCandidate = candidate.sorted(by: chronological)

        let baselineSigs = sortedBaseline.map { makeSignature($0.request, includeOrigin: includeOriginInSignature) }
        let candidateSigs = sortedCandidate.map { makeSignature($0.request, includeOrigin: includeOriginInSignature) }

        // Perform Sequence Alignment
        var alignedSteps: [TrajectoryAlignedStep] = []
        var bIdx = 0
        var cIdx = 0
        var stepCounter = 1

        while bIdx < sortedBaseline.count || cIdx < sortedCandidate.count {
            if bIdx < sortedBaseline.count && cIdx < sortedCandidate.count {
                let bSig = baselineSigs[bIdx]
                let cSig = candidateSigs[cIdx]

                if bSig == cSig {
                    let bSession = sortedBaseline[bIdx]
                    let cSession = sortedCandidate[cIdx]

                    let bStatus = bSession.response?.statusCode
                    let cStatus = cSession.response?.statusCode

                    let timeDelta = cSession.timing.startedAt.timeIntervalSince(bSession.timing.startedAt) * 1000.0

                    if bStatus != cStatus {
                        alignedSteps.append(
                            TrajectoryAlignedStep(
                                id: stepCounter,
                                stepType: .statusCodeMismatch,
                                baselineSessionID: bSession.id,
                                candidateSessionID: cSession.id,
                                requestSignature: bSig,
                                baselineStatusCode: bStatus,
                                candidateStatusCode: cStatus,
                                relativeTimestampDeltaMs: timeDelta,
                                divergenceSummary: "HTTP Status Code mismatch: \(bStatus ?? 0) vs \(cStatus ?? 0)"
                            )
                        )
                    } else {
                        // Compare Payloads
                        let payloadDiff = comparePayloadValues ? diffPayloads(bSession: bSession, cSession: cSession) : nil
                        if let diff = payloadDiff {
                            alignedSteps.append(
                                TrajectoryAlignedStep(
                                    id: stepCounter,
                                    stepType: .payloadDiverged,
                                    baselineSessionID: bSession.id,
                                    candidateSessionID: cSession.id,
                                    requestSignature: bSig,
                                    baselineStatusCode: bStatus,
                                    candidateStatusCode: cStatus,
                                    relativeTimestampDeltaMs: timeDelta,
                                    divergenceSummary: diff
                                )
                            )
                        } else {
                            alignedSteps.append(
                                TrajectoryAlignedStep(
                                    id: stepCounter,
                                    stepType: .matched,
                                    baselineSessionID: bSession.id,
                                    candidateSessionID: cSession.id,
                                    requestSignature: bSig,
                                    baselineStatusCode: bStatus,
                                    candidateStatusCode: cStatus,
                                    relativeTimestampDeltaMs: timeDelta,
                                    divergenceSummary: nil
                                )
                            )
                        }
                    }
                    bIdx += 1
                    cIdx += 1
                } else {
                    // Check if candidate matches a future baseline or vice-versa
                    if let nextBMatch = baselineSigs[bIdx...].firstIndex(of: cSig) {
                        // Candidate skipped to a future step -> baseline requests were missing in candidate
                        for i in bIdx..<nextBMatch {
                            let bSession = sortedBaseline[i]
                            alignedSteps.append(
                                TrajectoryAlignedStep(
                                    id: stepCounter,
                                    stepType: .missingInCandidate,
                                    baselineSessionID: bSession.id,
                                    candidateSessionID: nil,
                                    requestSignature: baselineSigs[i],
                                    baselineStatusCode: bSession.response?.statusCode,
                                    candidateStatusCode: nil,
                                    relativeTimestampDeltaMs: 0,
                                    divergenceSummary: "Request skipped in candidate run"
                                )
                            )
                            stepCounter += 1
                        }
                        bIdx = nextBMatch
                    } else {
                        // Candidate has an unexpected request
                        let cSession = sortedCandidate[cIdx]
                        alignedSteps.append(
                            TrajectoryAlignedStep(
                                id: stepCounter,
                                stepType: .unexpectedInCandidate,
                                baselineSessionID: nil,
                                candidateSessionID: cSession.id,
                                requestSignature: cSig,
                                baselineStatusCode: nil,
                                candidateStatusCode: cSession.response?.statusCode,
                                relativeTimestampDeltaMs: 0,
                                divergenceSummary: "Unexpected extra request emitted by candidate"
                            )
                        )
                        cIdx += 1
                    }
                }
            } else if bIdx < sortedBaseline.count {
                let bSession = sortedBaseline[bIdx]
                alignedSteps.append(
                    TrajectoryAlignedStep(
                        id: stepCounter,
                        stepType: .missingInCandidate,
                        baselineSessionID: bSession.id,
                        candidateSessionID: nil,
                        requestSignature: baselineSigs[bIdx],
                        baselineStatusCode: bSession.response?.statusCode,
                        candidateStatusCode: nil,
                        relativeTimestampDeltaMs: 0,
                        divergenceSummary: "Follow-up request not reached in candidate"
                    )
                )
                bIdx += 1
            } else if cIdx < sortedCandidate.count {
                let cSession = sortedCandidate[cIdx]
                alignedSteps.append(
                    TrajectoryAlignedStep(
                        id: stepCounter,
                        stepType: .unexpectedInCandidate,
                        baselineSessionID: nil,
                        candidateSessionID: cSession.id,
                        requestSignature: candidateSigs[cIdx],
                        baselineStatusCode: nil,
                        candidateStatusCode: cSession.response?.statusCode,
                        relativeTimestampDeltaMs: 0,
                        divergenceSummary: "Unexpected extra request emitted in candidate"
                    )
                )
                cIdx += 1
            }
            stepCounter += 1
        }

        // Find First Divergence Point
        var divIndex: Int? = nil
        var divSummary: String? = nil
        var divKind: TrajectoryDivergenceKind? = nil

        if let firstDiv = alignedSteps.first(where: { $0.stepType != .matched }) {
            divIndex = firstDiv.id
            divSummary = "Divergence at Step #\(firstDiv.id) [\(firstDiv.requestSignature)]: \(firstDiv.divergenceSummary ?? firstDiv.stepType.rawValue)"

            switch firstDiv.stepType {
            case .statusCodeMismatch:
                divKind = .statusCodeChange(baseline: firstDiv.baselineStatusCode ?? 0, candidate: firstDiv.candidateStatusCode ?? 0)
            case .payloadDiverged:
                divKind = .payloadFieldDelta(keyPath: "payload", baseline: "ok", candidate: "error")
            case .missingInCandidate:
                divKind = .missingFollowup(url: firstDiv.requestSignature)
            case .unexpectedInCandidate:
                divKind = .unexpectedRequest(url: firstDiv.requestSignature)
            case .matched:
                break
            }
        }

        let matchedCount = alignedSteps.filter { $0.stepType == .matched }.count
        let similarity = alignedSteps.isEmpty ? 100.0 : (Double(matchedCount) / Double(alignedSteps.count)) * 100.0
        let duration = max(1.0, Date().timeIntervalSince(startTime) * 1000.0)

        return TrajectoryDiffReport(
            baselineRunName: baselineName,
            candidateRunName: candidateName,
            totalBaselineRequests: sortedBaseline.count,
            totalCandidateRequests: sortedCandidate.count,
            alignedSteps: alignedSteps,
            divergencePointIndex: divIndex,
            divergencePointSummary: divSummary,
            divergenceKind: divKind,
            similarityScore: similarity,
            executionDurationMs: duration
        )
    }

    // MARK: - Helpers

    private static func makeSignature(_ req: CapturedRequest, includeOrigin: Bool) -> String {
        let cleanPath = normalizePath(req.path)
        let origin = includeOrigin ? "\(req.scheme)://\(req.host.lowercased()):\(req.port)" : ""
        return "\(req.method) \(origin)\(cleanPath)"
    }

    static func normalizePath(_ path: String) -> String {
        guard let url = URL(string: "http://dummy\(path)") else { return path }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return path }

        // Strip volatile dynamic query parameters
        let volatileParams: Set<String> = ["ts", "timestamp", "nonce", "trace_id", "cb", "session_id", "_", "t", "v"]
        if let queryItems = components.queryItems {
            components.queryItems = queryItems.filter { !volatileParams.contains($0.name.lowercased()) }
            if components.queryItems?.isEmpty == true {
                components.queryItems = nil
            }
        }

        let normalized = components.path + (components.query != nil ? "?\(components.query!)" : "")
        return normalized
    }

    private static func diffPayloads(bSession: SessionRecord, cSession: SessionRecord) -> String? {
        guard let bData = bSession.response?.bodyData, let cData = cSession.response?.bodyData else {
            return nil
        }
        guard let bJSON = try? JSONSerialization.jsonObject(with: bData, options: []) as? [String: Any],
              let cJSON = try? JSONSerialization.jsonObject(with: cData, options: []) as? [String: Any] else {
            return nil
        }

        for (k, bVal) in bJSON {
            let cVal = cJSON[k]
            if cVal == nil {
                return "Key '$.\(k)' present in baseline but missing in candidate"
            }
            if String(describing: bVal) != String(describing: cVal!) {
                return "Key '$.\(k)' changed from '\(bVal)' to '\(cVal!)'"
            }
        }
        return nil
    }
}
