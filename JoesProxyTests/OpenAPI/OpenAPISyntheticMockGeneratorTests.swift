import XCTest
@testable import JoesProxy

final class OpenAPISyntheticMockGeneratorTests: XCTestCase {

    let userSchema = OpenAPIJSONSchema(
        type: .object,
        required: ["id", "username", "email"],
        properties: [
            "id": OpenAPIJSONSchema(type: .string, format: "uuid"),
            "username": OpenAPIJSONSchema(type: .string, exampleValue: "johndoe"),
            "email": OpenAPIJSONSchema(type: .string, format: "email"),
            "age": OpenAPIJSONSchema(type: .integer, defaultValue: "25"),
            "tags": OpenAPIJSONSchema(type: .array, items: OpenAPIJSONSchema(type: .string))
        ]
    )

    func testValidDefaultMockGeneration() throws {
        let data = try OpenAPISyntheticMockGenerator.generateMockData(for: userSchema, mode: .validDefault)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["username"] as? String, "johndoe")
        XCTAssertEqual(json?["email"] as? String, "user@example.com")
        XCTAssertEqual(json?["age"] as? String, "25")
    }

    func testBoundaryEdgeMockGeneration() throws {
        let data = try OpenAPISyntheticMockGenerator.generateMockData(for: userSchema, mode: .boundaryEdge)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["id"] as? String, "12345678-1234-1234-1234-123456789abc")
        XCTAssertEqual(json?["age"] as? Int, 0)
    }

    func testEmptyCollectionsMockGeneration() throws {
        let data = try OpenAPISyntheticMockGenerator.generateMockData(for: userSchema, mode: .emptyCollections)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["tags"] as? [String], [])
    }
}
