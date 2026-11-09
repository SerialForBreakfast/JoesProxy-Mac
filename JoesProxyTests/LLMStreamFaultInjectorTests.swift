//
//  LLMStreamFaultInjectorTests.swift
//  JoesProxyTests
//
//  Unit tests for in-flight SSE stream fault injection,
//  token stalls, stream truncation, and tool-call argument corruptions.
//

import XCTest
@testable import JoesProxy

@MainActor
final class LLMStreamFaultInjectorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LLMStreamFaultInjector.shared.clearAllRules()
    }

    func testTruncatedStreamFault() {
        let injector = LLMStreamFaultInjector.shared
        let rule = LLMStreamFaultRule(
            name: "Truncate at Token 1",
            urlPattern: "*/v1/chat/completions*",
            faultKind: .truncatedStream(atTokenIndex: 1),
            isEnabled: true
        )
        injector.registerRule(rule)

        let originalSSE = """
        data: {"choices": [{"delta": {"content": "First"}}]}
        data: {"choices": [{"delta": {"content": "Second"}}]}
        data: {"choices": [{"delta": {"content": "Third"}}]}
        data: [DONE]
        """
        let data = originalSSE.data(using: .utf8)!

        let result = injector.processStreamData(
            data: data,
            requestURL: "https://api.openai.com/v1/chat/completions"
        )

        XCTAssertNotNil(result)
        let outputStr = String(data: result!.modifiedData, encoding: .utf8)!
        XCTAssertTrue(outputStr.contains("First"))
        XCTAssertFalse(outputStr.contains("Second"))
        XCTAssertTrue(outputStr.contains("data: [DONE]"))
    }

    func testCorruptToolCallArgumentsFault() {
        let injector = LLMStreamFaultInjector.shared
        let rule = LLMStreamFaultRule(
            name: "Corrupt Tools",
            urlPattern: "*/v1/chat/completions*",
            faultKind: .corruptToolCallArguments(toolName: "any"),
            isEnabled: true
        )
        injector.registerRule(rule)

        let originalSSE = """
        data: {"choices": [{"delta": {"tool_calls": [{"function": {"name": "test", "arguments": "{\"key\": \"value\"}"}}]}}]}
        data: [DONE]
        """
        let data = originalSSE.data(using: .utf8)!

        let result = injector.processStreamData(
            data: data,
            requestURL: "https://api.openai.com/v1/chat/completions"
        )

        XCTAssertNotNil(result)
        let outputStr = String(data: result!.modifiedData, encoding: .utf8)!
        XCTAssertTrue(outputStr.contains("INVALID_JSON_CORRUPTED"))
    }
}
