import XCTest
@testable import JoesProxy

final class OpenAPIContractValidatorTests: XCTestCase {

    let sampleSpecJSON = """
    {
      "openapi": "3.0.0",
      "info": {
        "title": "User Service API",
        "version": "1.2.0"
      },
      "paths": {
        "/users/{userId}": {
          "get": {
            "summary": "Get user by ID",
            "operationId": "getUserById",
            "responses": {
              "200": {
                "description": "User found",
                "content": {
                  "application/json": {
                    "schema": {
                      "type": "object",
                      "required": ["id", "username", "email"],
                      "properties": {
                        "id": { "type": "string", "format": "uuid" },
                        "username": { "type": "string" },
                        "email": { "type": "string", "format": "email" },
                        "age": { "type": "integer" }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    """.data(using: .utf8)!

    func testValidResponseBody() async throws {
        let store = OpenAPISchemaStore()
        _ = try await store.importDocument(data: sampleSpecJSON)

        let validUserJSON = """
        {
          "id": "123e4567-e89b-12d3-a456-426614174000",
          "username": "johndoe",
          "email": "john@example.com",
          "age": 30
        }
        """.data(using: .utf8)!

        let req = CapturedRequest(method: "GET", scheme: .https, host: "api.example.com", port: 443, path: "/users/123", headers: [], bodyData: nil, bodySize: nil)
        let resp = CapturedResponse(statusCode: 200, headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")], bodyData: validUserJSON, bodySize: validUserJSON.count, source: .upstream, sourceDescription: nil)
        let session = SessionRecord(request: req, response: resp, state: .completed, timing: SessionTiming(startedAt: Date()))

        let report = await OpenAPIContractValidator.validate(session: session, schemaStore: store)
        XCTAssertEqual(report.status, .valid)
        XCTAssertTrue(report.violations.isEmpty)
        XCTAssertEqual(report.badgeText, "Contract Valid")
    }

    func testMissingRequiredField() async throws {
        let store = OpenAPISchemaStore()
        _ = try await store.importDocument(data: sampleSpecJSON)

        let missingEmailJSON = """
        {
          "id": "123e4567-e89b-12d3-a456-426614174000",
          "username": "johndoe"
        }
        """.data(using: .utf8)!

        let req = CapturedRequest(method: "GET", scheme: .https, host: "api.example.com", port: 443, path: "/users/123", headers: [], bodyData: nil, bodySize: nil)
        let resp = CapturedResponse(statusCode: 200, headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")], bodyData: missingEmailJSON, bodySize: missingEmailJSON.count, source: .upstream, sourceDescription: nil)
        let session = SessionRecord(request: req, response: resp, state: .completed, timing: SessionTiming(startedAt: Date()))

        let report = await OpenAPIContractValidator.validate(session: session, schemaStore: store)
        XCTAssertEqual(report.status, .drift)
        XCTAssertEqual(report.violations.count, 1)
        XCTAssertEqual(report.violations.first?.keyPath, "root.email")
        XCTAssertTrue(report.violations.first?.reason.contains("Required property is missing") == true)
    }

    func testTypeMismatch() async throws {
        let store = OpenAPISchemaStore()
        _ = try await store.importDocument(data: sampleSpecJSON)

        let invalidAgeTypeJSON = """
        {
          "id": "123e4567-e89b-12d3-a456-426614174000",
          "username": "johndoe",
          "email": "john@example.com",
          "age": "thirty"
        }
        """.data(using: .utf8)!

        let req = CapturedRequest(method: "GET", scheme: .https, host: "api.example.com", port: 443, path: "/users/123", headers: [], bodyData: nil, bodySize: nil)
        let resp = CapturedResponse(statusCode: 200, headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")], bodyData: invalidAgeTypeJSON, bodySize: invalidAgeTypeJSON.count, source: .upstream, sourceDescription: nil)
        let session = SessionRecord(request: req, response: resp, state: .completed, timing: SessionTiming(startedAt: Date()))

        let report = await OpenAPIContractValidator.validate(session: session, schemaStore: store)
        XCTAssertEqual(report.status, .drift)
        XCTAssertEqual(report.violations.count, 1)
        XCTAssertEqual(report.violations.first?.keyPath, "root.age")
        XCTAssertEqual(report.violations.first?.expected, "integer")
    }

    func testFormatViolation() async throws {
        let store = OpenAPISchemaStore()
        _ = try await store.importDocument(data: sampleSpecJSON)

        let invalidUUIDJSON = """
        {
          "id": "not-a-uuid",
          "username": "johndoe",
          "email": "john@example.com"
        }
        """.data(using: .utf8)!

        let req = CapturedRequest(method: "GET", scheme: .https, host: "api.example.com", port: 443, path: "/users/123", headers: [], bodyData: nil, bodySize: nil)
        let resp = CapturedResponse(statusCode: 200, headers: [HTTPHeaderField(name: "Content-Type", value: "application/json")], bodyData: invalidUUIDJSON, bodySize: invalidUUIDJSON.count, source: .upstream, sourceDescription: nil)
        let session = SessionRecord(request: req, response: resp, state: .completed, timing: SessionTiming(startedAt: Date()))

        let report = await OpenAPIContractValidator.validate(session: session, schemaStore: store)
        XCTAssertEqual(report.status, .drift)
        XCTAssertEqual(report.violations.count, 1)
        XCTAssertEqual(report.violations.first?.keyPath, "root.id")
        XCTAssertEqual(report.violations.first?.expected, "UUID format")
    }
}
