//
//  LLMStreamFaultInjector.swift
//  JoesProxy
//
//  In-flight SSE stream buffer mutator and fault injection sandbox
//  for testing client-side LLM streaming resilience.
//

import Foundation

@MainActor
final class LLMStreamFaultInjector {
    static let shared = LLMStreamFaultInjector()

    private var activeRules: [UUID: LLMStreamFaultRule] = [:]

    func registerRule(_ rule: LLMStreamFaultRule) {
        activeRules[rule.id] = rule
    }

    func removeRule(id: UUID) {
        activeRules.removeValue(forKey: id)
    }

    func clearAllRules() {
        activeRules.removeAll()
    }

    func allRules() -> [LLMStreamFaultRule] {
        Array(activeRules.values)
    }

    /// Mutates an outgoing SSE stream according to active fault rules.
    func processStreamData(
        data: Data,
        requestURL: String
    ) -> (modifiedData: Data, ruleApplied: LLMStreamFaultRule)? {
        guard let bodyStr = String(data: data, encoding: .utf8) else { return nil }

        for rule in activeRules.values where rule.isEnabled {
            if urlMatchesPattern(url: requestURL, pattern: rule.urlPattern) {
                let modifiedStr = applyFault(rule: rule, bodyStr: bodyStr)
                if let outData = modifiedStr.data(using: .utf8) {
                    return (outData, rule)
                }
            }
        }
        return nil
    }

    // MARK: - Fault Transformation

    private func applyFault(rule: LLMStreamFaultRule, bodyStr: String) -> String {
        var lines = bodyStr.components(separatedBy: .newlines)

        switch rule.faultKind {
        case .tokenStall:
            // Insert artificial comment lines / pacing
            var newLines: [String] = []
            var chunkCount = 0
            for line in lines {
                newLines.append(line)
                if line.hasPrefix("data:") && !line.contains("[DONE]") {
                    chunkCount += 1
                    newLines.append(": joesproxy-injected-token-delay")
                }
            }
            return newLines.joined(separator: "\n")

        case .corruptToolCallArguments:
            // Find arguments in tool_calls and corrupt JSON
            var newLines: [String] = []
            for line in lines {
                if line.contains("\"arguments\"") {
                    let corrupted = line.replacingOccurrences(of: "\"arguments\": \"{", with: "\"arguments\": \"{INVALID_JSON_CORRUPTED:")
                    newLines.append(corrupted)
                } else {
                    newLines.append(line)
                }
            }
            return newLines.joined(separator: "\n")

        case .truncatedStream(let atTokenIndex):
            var newLines: [String] = []
            var count = 0
            for line in lines {
                if line.hasPrefix("data:") {
                    count += 1
                    if count > atTokenIndex {
                        newLines.append("data: [DONE]")
                        break
                    }
                }
                newLines.append(line)
            }
            return newLines.joined(separator: "\n")

        case .injectedErrorEnvelope(let code, let msg):
            let errChunk = "data: {\"error\": {\"code\": \"\(code)\", \"message\": \"\(msg)\"}}\n\n"
            return errChunk + bodyStr
        }
    }

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
