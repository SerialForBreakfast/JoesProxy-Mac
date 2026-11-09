//
//  SemanticMockEngine.swift
//  JoesProxy
//
//  Zero-dependency local vector cosine similarity matcher and
//  in-flight semantic wire mocking engine.
//

import Foundation

@MainActor
final class SemanticMockEngine {
    static let shared = SemanticMockEngine()

    private var activeRules: [UUID: SemanticMockRule] = [:]

    // MARK: - Rule Management

    func registerRule(_ rule: SemanticMockRule) {
        activeRules[rule.id] = rule
    }

    func removeRule(id: UUID) {
        activeRules.removeValue(forKey: id)
    }

    func clearAllRules() {
        activeRules.removeAll()
    }

    func allRules() -> [SemanticMockRule] {
        Array(activeRules.values)
    }

    // MARK: - Query Evaluation

    func evaluateQuery(
        query: String,
        targetURL: String? = nil
    ) -> SemanticMatchResult {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else {
            return SemanticMatchResult(
                isMatch: false,
                matchedRuleID: nil,
                matchedRuleName: nil,
                matchedIntent: nil,
                queryText: query,
                similarityScore: 0.0,
                bestMatchingExample: nil
            )
        }

        var bestRule: SemanticMockRule? = nil
        var bestScore: Double = 0.0
        var bestExample: String? = nil

        let queryVector = vectorize(cleanQuery)

        for rule in activeRules.values where rule.isEnabled {
            if let target = targetURL, !urlMatchesPattern(url: target, pattern: rule.urlPattern) {
                continue
            }

            for example in rule.exampleQueries {
                let exampleVector = vectorize(example)
                let similarity = cosineSimilarity(vectorA: queryVector, vectorB: exampleVector)

                if similarity > bestScore {
                    bestScore = similarity
                    bestRule = rule
                    bestExample = example
                }
            }
        }

        if let rule = bestRule, bestScore >= rule.confidenceThreshold {
            return SemanticMatchResult(
                isMatch: true,
                matchedRuleID: rule.id,
                matchedRuleName: rule.name,
                matchedIntent: rule.intentLabel,
                queryText: query,
                similarityScore: bestScore,
                bestMatchingExample: bestExample
            )
        }

        return SemanticMatchResult(
            isMatch: false,
            matchedRuleID: nil,
            matchedRuleName: nil,
            matchedIntent: nil,
            queryText: query,
            similarityScore: bestScore,
            bestMatchingExample: bestExample
        )
    }

    // MARK: - In-Flight Request Evaluation

    func evaluateRequest(
        url: String,
        bodyData: Data?
    ) -> (rule: SemanticMockRule, match: SemanticMatchResult)? {
        let extractedQuery = extractQueryText(url: url, bodyData: bodyData)
        guard let query = extractedQuery, !query.isEmpty else { return nil }

        let match = evaluateQuery(query: query, targetURL: url)
        guard match.isMatch, let ruleID = match.matchedRuleID, var rule = activeRules[ruleID] else {
            return nil
        }

        rule.matchCount += 1
        activeRules[ruleID] = rule

        return (rule, match)
    }

    // MARK: - Query Extraction

    func extractQueryText(url: String, bodyData: Data?) -> String? {
        // 1. Try URL Query Parameters
        if let components = URLComponents(string: url) ?? URLComponents(string: "http://dummy\(url)"),
           let queryItems = components.queryItems {
            let searchKeys: Set<String> = ["q", "query", "search", "prompt", "text", "message", "input"]
            for item in queryItems {
                if searchKeys.contains(item.name.lowercased()), let val = item.value, !val.isEmpty {
                    return val
                }
            }
        }

        // 2. Try JSON POST Body
        if let data = bodyData,
           let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            let bodyKeys = ["prompt", "query", "message", "input", "text", "search"]
            for k in bodyKeys {
                if let val = json[k] as? String, !val.isEmpty {
                    return val
                }
            }
        }

        return nil
    }

    // MARK: - Vectorization & Cosine Similarity

    func vectorize(_ text: String) -> [String: Double] {
        let lower = text.lowercased()
        var counts: [String: Double] = [:]

        // 1. Word tokens
        let words = lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        for w in words {
            counts["W_\(w)", default: 0.0] += 2.0
        }

        // 2. Character Trigrams (for robust typo & substring matching)
        if lower.count >= 3 {
            let chars = Array(lower)
            for i in 0...(chars.count - 3) {
                let trigram = String(chars[i..<(i + 3)])
                counts["T_\(trigram)", default: 0.0] += 1.0
            }
        }

        return counts
    }

    func cosineSimilarity(vectorA: [String: Double], vectorB: [String: Double]) -> Double {
        var dotProduct: Double = 0.0
        var normA: Double = 0.0
        var normB: Double = 0.0

        for (_, val) in vectorA {
            normA += val * val
        }
        for (_, val) in vectorB {
            normB += val * val
        }

        guard normA > 0.0, normB > 0.0 else { return 0.0 }

        for (key, valA) in vectorA {
            if let valB = vectorB[key] {
                dotProduct += valA * valB
            }
        }

        return min(1.0, max(0.0, dotProduct / (sqrt(normA) * sqrt(normB))))
    }

    // MARK: - URL Pattern Matching

    private func urlMatchesPattern(url: String, pattern: String) -> Bool {
        if pattern == "*" || pattern.isEmpty { return true }
        if url.contains(pattern) { return true }

        let clean = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("*") && clean.hasSuffix("*") {
            let sub = clean.dropFirst().dropLast()
            return url.contains(sub)
        } else if clean.hasPrefix("*") {
            let sub = clean.dropFirst()
            return url.hasSuffix(String(sub))
        } else if clean.hasSuffix("*") {
            let sub = clean.dropLast()
            return url.hasPrefix(String(sub))
        }
        return url == clean
    }
}
