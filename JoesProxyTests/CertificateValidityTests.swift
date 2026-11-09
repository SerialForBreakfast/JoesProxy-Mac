import XCTest
@testable import JoesProxy

final class CertificateValidityTests: XCTestCase {
    // A self-signed test certificate, notBefore Jun 10 2026, notAfter Jun 9 2031 (5-year validity).
    private static let testCertificateDERBase64 = "MIIDEzCCAfugAwIBAgIUZ/nWZD6QBH59Cb+DFfpKSR3HFLUwDQYJKoZIhvcNAQELBQAwGTEXMBUGA1UEAwwOSm9lc1Byb3h5IFRlc3QwHhcNMjYwNjEwMTU1NDIxWhcNMzEwNjA5MTU1NDIxWjAZMRcwFQYDVQQDDA5Kb2VzUHJveHkgVGVzdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAKmljhg6KGVogS38xnnxMRMLg9nb78IcklDC7OKgrAUAa3EBWG130CCXxD1Rr+eoJmqccJnEfXuTe/cmIHYpIPKmS8ly/8xRLRy30dCAqIlFbbduUrC7G6q2IHrzEZp+nI1oqAv3TlOZ5/e6SsjtyoLB3jM/YwrtIVJAXyfoP5bsyH9g69CMXtbICl0BLG7lt9Ufy5HibIlqBvjBIiGqB/KfJX26opoEjmY4eyzWE2wwAKZdoAV2jHX+jB/jQZLDXGSFAw+CJhxaRrVFOvPUIWjCnZYwSbZd2ZPjNcIF9JpG/0PaqsGJFGLNBUnxJOO4uFR+HArhw4y9TMfwDFMHXlUCAwEAAaNTMFEwHQYDVR0OBBYEFLwEHshGlWmyigrn4+1cqQaV7myQMB8GA1UdIwQYMBaAFLwEHshGlWmyigrn4+1cqQaV7myQMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAHS392tjhl0UxA1bWLqDr1kUqJ6XijD/wQkaKHL7y5gwzLeHM0eWyWeaFWqPLqHnY4/IjGgAYaDutGOcali5YoiNMOeKoWn/wOymYAkDz9gmcp0AYsPt6v3wqdvPOE6jq/mV7xxo+EFo94YeI5cQgADbq/tUdG4zSiL82+D+S7fs3vywOPymMDoJ7yAzbaCSbJg/Vg+Tn5yqlSET6/nVUbxEJw/rQTJ5tMJNhzYIQ/DQ8bCnh012du4AGpaLd17xr6IOM5MXhUJafcVjcbazVHy/p5mCRwmlBE3q+LW7lEYQHrQNGGeXGB6nf8KjEevvWlqP7NfgMAWVQIEqJTSsJDk="

    func testParsesValidityFromRealCertificate() throws {
        let der = try XCTUnwrap(Data(base64Encoded: Self.testCertificateDERBase64))
        let dates = try XCTUnwrap(CertificateValidity.dates(fromDER: der))

        XCTAssertGreaterThan(dates.notAfter, dates.notBefore)

        let calendar = Calendar(identifier: .gregorian)
        XCTAssertEqual(calendar.component(.year, from: dates.notBefore), 2026)
        XCTAssertEqual(calendar.component(.year, from: dates.notAfter), 2031)

        // Roughly a 5-year window.
        let years = dates.notAfter.timeIntervalSince(dates.notBefore) / (365.0 * 24 * 60 * 60)
        XCTAssertEqual(years, 5, accuracy: 0.1)
    }

    func testReturnsNilForGarbageData() {
        XCTAssertNil(CertificateValidity.dates(fromDER: Data("not a certificate".utf8)))
    }
}
