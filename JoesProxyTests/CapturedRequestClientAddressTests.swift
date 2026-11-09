import XCTest
@testable import JoesProxy

final class CapturedRequestClientAddressTests: XCTestCase {
    private func makeRequest(clientAddress: String?) -> CapturedRequest {
        CapturedRequest(
            method: "GET",
            scheme: .http,
            host: "example.com",
            port: 80,
            path: "/",
            headers: [HTTPHeaderField(name: "User-Agent", value: "Macintosh")],
            bodyData: nil,
            bodySize: nil,
            clientAddress: clientAddress
        )
    }

    func testRoundTripsClientAddress() throws {
        let original = makeRequest(clientAddress: "127.0.0.1")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CapturedRequest.self, from: data)
        XCTAssertEqual(decoded.clientAddress, "127.0.0.1")
    }

    func testNilClientAddressOmittedFromJSON() throws {
        let original = makeRequest(clientAddress: nil)
        let data = try JSONEncoder().encode(original)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("clientAddress"))
    }

    func testLegacyJSONWithoutClientAddressDecodesToNil() throws {
        // A recording saved before the field existed.
        let legacy = """
        {"method":"GET","scheme":"http","inspectionKind":"plain","host":"example.com","port":80,"path":"/","headers":[]}
        """
        let decoded = try JSONDecoder().decode(CapturedRequest.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.clientAddress)
    }

    func testUserAgentAccessorIsCaseInsensitive() {
        let request = CapturedRequest(
            method: "GET", scheme: .http, host: "h", port: nil, path: "/",
            headers: [HTTPHeaderField(name: "user-agent", value: "iPhone")],
            bodyData: nil, bodySize: nil
        )
        XCTAssertEqual(request.userAgent, "iPhone")
    }
}
