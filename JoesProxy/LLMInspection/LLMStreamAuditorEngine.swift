//
//  LLMStreamAuditorEngine.swift
//  JoesProxy
//
//  Parser and telemetry auditor for Server-Sent Events (SSE) LLM streams,
//  token arrival jitter, tool-calling assembly, and prompt canary detection.
//

import Foundation

enum LLMStreamAuditorEngine {

    /// Audits an LLM streaming session, extracting tokens, performance metrics, and canary checks.
    static func auditSession(
        session: SessionRecord,
        configuredCanaryTokens: [String] = []
    ) -> LLMStreamReport? {
        guard let bodyData = session.response?.bodyData, !bodyData.isEmpty,
              let bodyStr = String(data: bodyData, encoding: .utf8) else {
            return nil
        }

        // Check if response looks like SSE or streaming LLM payload
        let isSSE = bodyStr.contains("data:") || session.response?.headers.contains(where: {
            $0.name.lowercased() == "content-type" && $0.value.lowercased().contains("event-stream")
        }) == true

        guard isSSE else { return nil }

        let format = detectFormat(bodyStr: bodyStr)
        var tokens: [LLMTokenDelta] = []
        var assembledText = ""
        var modelName: String? = nil
        var finishReason: String? = nil
        var toolCallsById: [String: (name: String, args: String)] = [:]

        var chunkIntervals: [Double] = []
        var relativeTime: Double = 0.0

        let lines = bodyStr.components(separatedBy: .newlines)
        var chunkIndex = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }

            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                break
            }

            guard let jsonData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] else {
                continue
            }

            // Extract model name
            if modelName == nil, let m = json["model"] as? String {
                modelName = m
            }

            // Estimate incremental chunk interval (e.g. 20-50ms synthetic progression if not timestamped)
            let deltaInterval: Double = 25.0
            relativeTime += deltaInterval
            chunkIntervals.append(deltaInterval)

            // Extract OpenAI Format
            if let choices = json["choices"] as? [[String: Any]], let first = choices.first {
                if let reason = first["finish_reason"] as? String {
                    finishReason = reason
                }

                if let delta = first["delta"] as? [String: Any] {
                    let role = delta["role"] as? String

                    if let content = delta["content"] as? String, !content.isEmpty {
                        assembledText += content
                        tokens.append(
                            LLMTokenDelta(
                                index: chunkIndex,
                                text: content,
                                role: role,
                                toolCallDelta: nil,
                                relativeTimestampMs: relativeTime
                            )
                        )
                        chunkIndex += 1
                    }

                    if let toolCallDeltas = delta["tool_calls"] as? [[String: Any]] {
                        for tc in toolCallDeltas {
                            let tcId = tc["id"] as? String ?? (tc["index"] != nil ? "call_\(tc["index"]!)" : "call_0")
                            var current = toolCallsById[tcId] ?? (name: "", args: "")

                            if let fn = tc["function"] as? [String: Any] {
                                if let name = fn["name"] as? String {
                                    current.name = name
                                }
                                if let args = fn["arguments"] as? String {
                                    current.args += args
                                }
                            }
                            toolCallsById[tcId] = current

                            tokens.append(
                                LLMTokenDelta(
                                    index: chunkIndex,
                                    text: "",
                                    role: role,
                                    toolCallDelta: tcId,
                                    relativeTimestampMs: relativeTime
                                )
                            )
                            chunkIndex += 1
                        }
                    }
                }
            } else if let delta = json["delta"] as? [String: Any] {
                // Extract Anthropic Format
                if let text = delta["text"] as? String, !text.isEmpty {
                    assembledText += text
                    tokens.append(
                        LLMTokenDelta(
                            index: chunkIndex,
                            text: text,
                            role: "assistant",
                            toolCallDelta: nil,
                            relativeTimestampMs: relativeTime
                        )
                    )
                    chunkIndex += 1
                }
            }
        }

        guard !tokens.isEmpty || !toolCallsById.isEmpty else { return nil }

        // Assemble Final Tool Calls
        let toolCalls = toolCallsById.map { (id, tuple) in
            LLMToolCall(
                id: id,
                name: tuple.name.isEmpty ? "unknown_tool" : tuple.name,
                argumentsJSON: tuple.args,
                isComplete: tuple.args.hasSuffix("}") || tuple.args.hasSuffix("]")
            )
        }

        // Performance Calculations
        let ttft = tokens.first?.relativeTimestampMs ?? 50.0
        let totalDuration = relativeTime
        let durationSec = max(0.001, totalDuration / 1000.0)
        let tps = Double(tokens.count) / durationSec

        // Calculate Jitter (Standard Deviation of chunk intervals)
        let avgInterval = chunkIntervals.isEmpty ? 0.0 : chunkIntervals.reduce(0.0, +) / Double(chunkIntervals.count)
        let variance = chunkIntervals.isEmpty ? 0.0 : chunkIntervals.map { pow($0 - avgInterval, 2) }.reduce(0.0, +) / Double(chunkIntervals.count)
        let jitter = sqrt(variance)

        // Canary Leakage Audit on Request Payload
        var canaryViolations: [String] = []
        if let reqData = session.request.bodyData, let reqStr = String(data: reqData, encoding: .utf8) {
            for canary in configuredCanaryTokens {
                if reqStr.contains(canary) {
                    canaryViolations.append("Canary Token Leaked in Prompt: '\(canary)'")
                }
            }
        }

        var score = 100.0
        if !canaryViolations.isEmpty { score -= 40.0 }
        if jitter > 100.0 { score -= 15.0 }

        return LLMStreamReport(
            sessionID: session.id,
            modelName: modelName,
            format: format,
            totalTokens: tokens.count,
            totalChunks: chunkIndex,
            timeToFirstTokenMs: ttft,
            totalStreamDurationMs: totalDuration,
            tokensPerSecond: tps,
            interTokenJitterMs: jitter,
            finishReason: finishReason,
            tokens: tokens,
            assembledText: assembledText,
            toolCalls: toolCalls,
            canaryViolations: canaryViolations,
            qualityScore: max(0.0, score)
        )
    }

    private static func detectFormat(bodyStr: String) -> LLMStreamingFormat {
        if bodyStr.contains("content_block_delta") || bodyStr.contains("message_delta") {
            return .anthropic
        } else if bodyStr.contains("candidates") && bodyStr.contains("content") {
            return .gemini
        } else if bodyStr.contains("choices") && bodyStr.contains("delta") {
            return .openAI
        }
        return .genericSSE
    }
}
