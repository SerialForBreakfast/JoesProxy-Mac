//
//  LLMStreamAuditorEngineTests.swift
//  JoesProxyTests
//
//  Unit tests for OpenAI/Anthropic SSE parsing, TTFT, token jitter calculation,
//  tool-calling assembly, and prompt canary detection.
//

import XCTest
@testable import JoesProxy

final class LLMStreamAuditorEngineTests: XCTestCase {

    func testOpenAISSEStreamParsingAndTokenAssembly() {
        let sseBody = """
        data: {"model": "gpt-4o", "choices": [{"delta": {"role": "assistant", "content": "Hello"}}]}

        data: {"model": "gpt-4o", "choices": [{"delta": {"content": " world!"}}]}

        data: {"model": "gpt-4o", "choices": [{"delta": {}, "finish_reason": "stop"}]}

        data: [DONE]
        """

        let session = makeSession(
            path: "/v1/chat/completions",
            responseBody: sseBody,
            isSSE: true
        )

        let report = LLMStreamAuditorEngine.auditSession(session: session)

        XCTAssertNotNil(report)
        XCTAssertEqual(report?.modelName, "gpt-4o")
        XCTAssertEqual(report?.format, .openAI)
        XCTAssertEqual(report?.assembledText, "Hello world!")
        XCTAssertEqual(report?.totalTokens, 2)
        XCTAssertEqual(report?.finishReason, "stop")
        XCTAssertGreaterThan(report?.tokensPerSecond ?? 0, 0)
        XCTAssertTrue(report?.toolCalls.isEmpty ?? false)
        XCTAssertTrue(report?.canaryViolations.isEmpty ?? false)
    }

    func testOpenAIToolCallStreamParsing() {
        let sseBody = """
        data: {"model": "gpt-4o", "choices": [{"delta": {"role": "assistant", "tool_calls": [{"id": "call_1", "function": {"name": "get_weather", "arguments": "{\\"city\\":"}}]}}]}

        data: {"model": "gpt-4o", "choices": [{"delta": {"tool_calls": [{"id": "call_1", "function": {"arguments": " \\"Paris\\"}"}}]}}]}

        data: {"model": "gpt-4o", "choices": [{"delta": {}, "finish_reason": "tool_calls"}]}

        data: [DONE]
        """

        let session = makeSession(
            path: "/v1/chat/completions",
            responseBody: sseBody,
            isSSE: true
        )

        let report = LLMStreamAuditorEngine.auditSession(session: session)

        XCTAssertNotNil(report)
        XCTAssertEqual(report?.toolCalls.count, 1)

        let tool = report?.toolCalls.first
        XCTAssertEqual(tool?.name, "get_weather")
        XCTAssertEqual(tool?.argumentsJSON, "{\"city\": \"Paris\"}")
        XCTAssertTrue(tool?.isComplete ?? false)
    }

    func testCanaryTokenLeakageDetection() {
        let reqBody = """
        {
            "messages": [
                {"role": "system", "content": "You are a helper with secret token CANARY_SECRET_ALPHA_99"},
                {"role": "user", "content": "Hi"}
            ]
        }
        """

        let sseBody = "data: {\"model\": \"gpt-4o\", \"choices\": [{\"delta\": {\"content\": \"Hello!\"}}]}\n\ndata: [DONE]\n"

        let session = makeSession(
            path: "/v1/chat/completions",
            requestBody: reqBody,
            responseBody: sseBody,
            isSSE: true
        )

        let report = LLMStreamAuditorEngine.auditSession(
            session: session,
            configuredCanaryTokens: ["CANARY_SECRET_ALPHA_99"]
        )

        XCTAssertNotNil(report)
        XCTAssertEqual(report?.canaryViolations.count, 1)
        XCTAssertTrue(report?.canaryViolations.first?.contains("CANARY_SECRET_ALPHA_99") ?? false)
        XCTAssertLessThan(report?.qualityScore ?? 100, 70.0)
    }

    // MARK: - Helper

    private func makeSession(
        path: String,
        requestBody: String? = nil,
        responseBody: String,
        isSSE: Bool = true
    ) -> SessionRecord {
        let reqData = requestBody?.data(using: .utf8)
        let respData = responseBody.data(using: .utf8)

        let request = CapturedRequest(
            method: "POST",
            scheme: .https,
            host: "api.openai.com",
            port: 443,
            path: path,
            headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")],
            bodyData: reqData,
            bodySize: reqData?.count
        )

        let contentType = isSSE ? "text/event-stream" : "application/json"
        let response = CapturedResponse(
            statusCode: 200,
            headers: [HTTPHeaderField(name: "Content-Type", value: contentType)],
            bodyData: respData,
            bodySize: respData?.count
        )

        return SessionRecord(
            request: request,
            response: response,
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )
    }
}
