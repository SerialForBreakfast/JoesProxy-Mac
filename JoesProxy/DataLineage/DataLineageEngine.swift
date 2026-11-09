//
//  DataLineageEngine.swift
//  JoesProxy
//
//  Forward watermark detector and passive reverse lineage search engine
//  for tracking parameters and analytics beacon attribution.
//

import Foundation

enum DataLineageEngine {

    /// Audits an analytics beacon or tracking session against upstream API responses to build a full attribution report.
    static func auditAnalytics(
        sinkSession: SessionRecord,
        upstreamSessions: [SessionRecord]
    ) async -> AnalyticsAttributionReport {
        let sinkURL = MediaDetector.absoluteURL(for: sinkSession.request)?.absoluteString ?? sinkSession.request.path
        let sinkParams = extractAllParameters(from: sinkSession)
        var flows: [DataLineageFlow] = []
        var unattributed: [DataLineageNode] = []

        let registeredTokens = await ProvenanceRegistry.shared.allTokens()

        for param in sinkParams {
            // 1. Try Forward Watermark Token Match
            var matched = false
            for (token, sourceNode) in registeredTokens {
                if param.value.contains(token) {
                    let latency = max(0.0, sinkSession.timing.startedAt.timeIntervalSince(sourceNode.timestamp) * 1000.0)
                    let flow = DataLineageFlow(
                        sourceNode: sourceNode,
                        watermarkToken: token,
                        sinkNode: param,
                        latencyMs: latency,
                        matchConfidence: 1.0,
                        flowType: .watermarkedToken
                    )
                    flows.append(flow)
                    matched = true
                    break
                }
            }

            if matched { continue }

            // 2. Try Passive Reverse Lineage Search across Upstream Sessions
            let reverseMatches = searchReverseLineage(
                targetValue: param.value,
                candidateSessions: upstreamSessions,
                sinkNode: param
            )

            if let bestMatch = reverseMatches.first {
                flows.append(bestMatch)
            } else {
                unattributed.append(param)
            }
        }

        return AnalyticsAttributionReport(
            sinkSessionID: sinkSession.id,
            sinkURL: sinkURL,
            totalTrackingParameters: sinkParams.count,
            attributedCount: flows.count,
            unattributedCount: unattributed.count,
            flows: flows,
            unattributedParameters: unattributed
        )
    }

    /// Performs passive reverse lineage search for a specific value across a collection of candidate sessions.
    static func searchReverseLineage(
        targetValue: String,
        candidateSessions: [SessionRecord],
        sinkNode: DataLineageNode? = nil
    ) -> [DataLineageFlow] {
        let trimmed = targetValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count >= 2 else { return [] }

        var flows: [DataLineageFlow] = []
        let urlDecoded = trimmed.removingPercentEncoding ?? trimmed

        for session in candidateSessions {
            let sessionURL = MediaDetector.absoluteURL(for: session.request)?.absoluteString ?? session.request.path
            let timestamp = session.timing.startedAt

            // 1. Search Response Headers
            for header in session.response?.headers ?? [] {
                if header.value.contains(trimmed) || header.value.contains(urlDecoded) {
                    let sourceNode = DataLineageNode(
                        sessionID: session.id,
                        endpointURL: sessionURL,
                        httpMethod: session.request.method,
                        timestamp: timestamp,
                        keypath: "header.\(header.name)",
                        value: header.value
                    )
                    let sink = sinkNode ?? DataLineageNode(
                        sessionID: UUID(),
                        endpointURL: "Target Query",
                        httpMethod: "GET",
                        timestamp: Date(),
                        keypath: "value",
                        value: targetValue
                    )
                    flows.append(
                        DataLineageFlow(
                            sourceNode: sourceNode,
                            watermarkToken: nil,
                            sinkNode: sink,
                            latencyMs: 0.0,
                            matchConfidence: header.value == trimmed ? 0.95 : 0.8,
                            flowType: header.value == trimmed ? .exactValueMatch : .substringMatch
                        )
                    )
                }
            }

            // 2. Search Response JSON Body
            if let bodyData = session.response?.bodyData, !bodyData.isEmpty {
                if let json = try? JSONSerialization.jsonObject(with: bodyData, options: []) {
                    var matches: [(path: String, val: String, confidence: Double, type: LineageFlowType)] = []
                    findInJSON(
                        json,
                        path: "$",
                        target: trimmed,
                        urlDecodedTarget: urlDecoded,
                        matches: &matches
                    )

                    for match in matches {
                        let sourceNode = DataLineageNode(
                            sessionID: session.id,
                            endpointURL: sessionURL,
                            httpMethod: session.request.method,
                            timestamp: timestamp,
                            keypath: match.path,
                            value: match.val
                        )
                        let sink = sinkNode ?? DataLineageNode(
                            sessionID: UUID(),
                            endpointURL: "Target Query",
                            httpMethod: "GET",
                            timestamp: Date(),
                            keypath: "value",
                            value: targetValue
                        )
                        let latency = sinkNode != nil ? max(0.0, sinkNode!.timestamp.timeIntervalSince(timestamp) * 1000.0) : 0.0
                        flows.append(
                            DataLineageFlow(
                                sourceNode: sourceNode,
                                watermarkToken: nil,
                                sinkNode: sink,
                                latencyMs: latency,
                                matchConfidence: match.confidence,
                                flowType: match.type
                            )
                        )
                    }
                }
            }
        }

        // Sort by highest confidence first
        return flows.sorted { $0.matchConfidence > $1.matchConfidence }
    }

    // MARK: - Parameter Extraction

    static func extractAllParameters(from session: SessionRecord) -> [DataLineageNode] {
        var nodes: [DataLineageNode] = []
        let urlStr = MediaDetector.absoluteURL(for: session.request)?.absoluteString ?? session.request.path
        let timestamp = session.timing.startedAt

        // 1. Query Parameters
        if let comps = URLComponents(string: urlStr), let items = comps.queryItems {
            for item in items {
                if let val = item.value, !val.isEmpty {
                    nodes.append(
                        DataLineageNode(
                            sessionID: session.id,
                            endpointURL: urlStr,
                            httpMethod: session.request.method,
                            timestamp: timestamp,
                            keypath: "query.\(item.name)",
                            value: val
                        )
                    )
                }
            }
        }

        // 2. Request Body Parameters (JSON)
        if let bodyData = session.request.bodyData, !bodyData.isEmpty {
            if let json = try? JSONSerialization.jsonObject(with: bodyData, options: []) {
                var jsonLeaves: [(path: String, val: String)] = []
                collectJSONLeaves(json, path: "$", leaves: &jsonLeaves)
                for leaf in jsonLeaves {
                    nodes.append(
                        DataLineageNode(
                            sessionID: session.id,
                            endpointURL: urlStr,
                            httpMethod: session.request.method,
                            timestamp: timestamp,
                            keypath: leaf.path,
                            value: leaf.val
                        )
                    )
                }
            }
        }

        return nodes
    }

    // MARK: - Recursive Search Helpers

    private static func findInJSON(
        _ value: Any,
        path: String,
        target: String,
        urlDecodedTarget: String,
        matches: inout [(path: String, val: String, confidence: Double, type: LineageFlowType)]
    ) {
        if let dict = value as? [String: Any] {
            for (k, v) in dict {
                findInJSON(v, path: "\(path).\(k)", target: target, urlDecodedTarget: urlDecodedTarget, matches: &matches)
            }
        } else if let arr = value as? [Any] {
            for (idx, item) in arr.enumerated() {
                findInJSON(item, path: "\(path)[\(idx)]", target: target, urlDecodedTarget: urlDecodedTarget, matches: &matches)
            }
        } else if let str = value as? String {
            if str == target {
                matches.append((path: path, val: str, confidence: 1.0, type: .exactValueMatch))
            } else if str == urlDecodedTarget {
                matches.append((path: path, val: str, confidence: 0.95, type: .urlDecodedMatch))
            } else if str.contains(target) || target.contains(str) {
                matches.append((path: path, val: str, confidence: 0.75, type: .substringMatch))
            }
        } else if let num = value as? NSNumber {
            let numStr = num.stringValue
            if numStr == target {
                matches.append((path: path, val: numStr, confidence: 1.0, type: .exactValueMatch))
            }
        }
    }

    private static func collectJSONLeaves(
        _ value: Any,
        path: String,
        leaves: inout [(path: String, val: String)]
    ) {
        if let dict = value as? [String: Any] {
            for (k, v) in dict {
                collectJSONLeaves(v, path: "\(path).\(k)", leaves: &leaves)
            }
        } else if let arr = value as? [Any] {
            for (idx, item) in arr.enumerated() {
                collectJSONLeaves(item, path: "\(path)[\(idx)]", leaves: &leaves)
            }
        } else if let str = value as? String {
            leaves.append((path: path, val: str))
        } else if let num = value as? NSNumber {
            leaves.append((path: path, val: num.stringValue))
        }
    }
}
