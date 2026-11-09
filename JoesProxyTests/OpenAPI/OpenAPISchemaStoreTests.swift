import XCTest
@testable import JoesProxy

final class OpenAPISchemaStoreTests: XCTestCase {

    let sampleSpecJSON = """
    {
      "openapi": "3.0.0",
      "info": {
        "title": "User Service API",
        "version": "1.2.0"
      },
      "paths": {
        "/users": {
          "get": {
            "summary": "List all users",
            "operationId": "listUsers",
            "responses": {
              "200": {
                "description": "A list of users",
                "content": {
                  "application/json": {
                    "schema": {
                      "type": "array",
                      "items": {
                        "$ref": "#/components/schemas/User"
                      }
                    }
                  }
                }
              }
            }
          }
        },
        "/users/{userId}": {
          "get": {
            "summary": "Get user by ID",
            "operationId": "getUserById",
            "parameters": [
              {
                "name": "userId",
                "in": "path",
                "required": true,
                "schema": {
                  "type": "string",
                  "format": "uuid"
                }
              }
            ],
            "responses": {
              "200": {
                "description": "User found",
                "content": {
                  "application/json": {
                    "schema": {
                      "$ref": "#/components/schemas/User"
                    }
                  }
                }
              },
              "404": {
                "description": "User not found"
              }
            }
          }
        }
      },
      "components": {
        "schemas": {
          "User": {
            "type": "object",
            "required": ["id", "username", "email"],
            "properties": {
              "id": {
                "type": "string",
                "format": "uuid"
              },
              "username": {
                "type": "string"
              },
              "email": {
                "type": "string",
                "format": "email"
              },
              "age": {
                "type": "integer"
              }
            }
          }
        }
      }
    }
    """.data(using: .utf8)!

    func testImportingAndParsingSpec() async throws {
        let store = OpenAPISchemaStore()
        let doc = try await store.importDocument(data: sampleSpecJSON)

        XCTAssertEqual(doc.title, "User Service API")
        XCTAssertEqual(doc.version, "1.2.0")
        XCTAssertEqual(doc.operations.count, 2)

        let listOp = doc.operations.first { $0.id == "listUsers" }
        XCTAssertNotNil(listOp)
        XCTAssertEqual(listOp?.method, "GET")
        XCTAssertEqual(listOp?.pathTemplate, "/users")

        let getOp = doc.operations.first { $0.id == "getUserById" }
        XCTAssertNotNil(getOp)
        XCTAssertEqual(getOp?.parameters.count, 1)
        XCTAssertEqual(getOp?.parameters.first?.name, "userId")
        XCTAssertEqual(getOp?.parameters.first?.location, .path)
    }

    func testRouteMatching() async throws {
        let store = OpenAPISchemaStore()
        _ = try await store.importDocument(data: sampleSpecJSON)

        // Exact match
        let match1 = await store.match(method: "GET", path: "/users")
        XCTAssertNotNil(match1)
        XCTAssertEqual(match1?.operation.id, "listUsers")

        // Parameterized match
        let match2 = await store.match(method: "GET", path: "/users/12345")
        XCTAssertNotNil(match2)
        XCTAssertEqual(match2?.operation.id, "getUserById")

        // Method mismatch
        let match3 = await store.match(method: "POST", path: "/users")
        XCTAssertNil(match3)

        // Path mismatch
        let match4 = await store.match(method: "GET", path: "/posts/123")
        XCTAssertNil(match4)
    }
}
