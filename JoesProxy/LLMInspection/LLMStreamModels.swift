//
//  LLMStreamModels.swift
//  JoesProxy
//
//  Domain models for LLM streaming wire inspection, SSE token deltas,
//  tool-calling telemetry, and streaming jitter profiling.
//

import Foundation

/// Supported LLM streaming protocol format.
enum LLMStreamingFormat: String, Codable, Equatable, Sendable {
    case openAI = "OpenAI Chat Completions / Responses"
    case anthropic = "Anthropic Messages"
    case gemini = "Gemini Stream"
    case genericSSE = "Generic Server-Sent Events"
}

/// A single incremental token or chunk emitted in an SSE stream.
struct LLMTokenDelta: Codable, Equatable, Sendable {
    var index: Int
    var text: String
    var role: String?
    var toolCallDelta: String?
    var relativeTimestampMs: Double
}

/// Assembled tool / function call from streaming chunks.
struct LLMToolCall: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var argumentsJSON: String
    var isComplete: Bool
}

/// Comprehensive inspection report for an LLM streaming session.
struct LLMStreamReport: Codable, Equatable, Sendable {
    var sessionID: UUID
    var modelName: String?
    var format: LLMStreamingFormat
    var totalTokens: Int
    var totalChunks: Int
    var timeToFirstTokenMs: Double
    var totalStreamDurationMs: Double
    var tokensPerSecond: Double
    var interTokenJitterMs: Double // standard deviation of chunk intervals
    var finishReason: String?
    var tokens: [LLMTokenDelta]
    var assembledText: String
    var toolCalls: [LLMToolCall]
    var canaryViolations: [String]
    var qualityScore: Double // 0 to 100
}

/// Type of in-flight fault to inject into an SSE stream.
enum LLMStreamFaultKind: Codable, Equatable, Sendable {
    case tokenStall(delayMs: Int, atTokenIndex: Int)
    case corruptToolCallArguments(toolName: String)
    case truncatedStream(atTokenIndex: Int)
    case injectedErrorEnvelope(code: String, message: String)

    var description: String {
        switch self {
        case .tokenStall(let delay, let idx):
            return "Token Stall: Inject +\(delay)ms delay at token #\(idx)"
        case .corruptToolCallArguments(let name):
            return "Corrupt Tool Call: Invalidate arguments JSON for '\(name)'"
        case .truncatedStream(let idx):
            return "Truncated Stream: Close connection at token #\(idx)"
        case .injectedErrorEnvelope(let code, let msg):
            return "Injected Error: Return error '\(code): \(msg)'"
        }
    }
}

/// A configured rule for in-flight SSE stream fault injection.
struct LLMStreamFaultRule: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var urlPattern: String // e.g. "*/v1/chat/completions*" or "*/v1/messages*"
    var faultKind: LLMStreamFaultKind
    var isEnabled: Bool = true
}
