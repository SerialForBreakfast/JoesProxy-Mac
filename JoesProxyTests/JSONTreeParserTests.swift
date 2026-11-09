import Foundation
import XCTest
@testable import JoesProxy

final class JSONTreeParserTests: XCTestCase {
    /// Adobe Edge Konductor streaming responses prefix records with `\0` separators.
    func testParseNullDelimitedAdobeKonductorStream() throws {
        let gzipBase64 = """
        H4sIAAAAAAAAALWQMU/DMBCFO/MzPDdSYscpyeZiIhiAATZURca+hiomLvYFiKr8d0wGMoDExHb39L53erc6EQ+\
        vAwS8NqQiRbEVPJV5wqm8SHIuy2QrmUwKWdcpK0RGJU9USfeMbfiea8g142RNnlVvLJDq8USOarROmXkO2h2jSh6U\
        bwG/fIce4z4ziPYetOtNIFV2nqbTegGEuFnc5R/mS9PCLeC7890COU9/w3ZRG2fKOq3w4Pqr6K88hMEimXbT2epf\
        P9LBGEO73mj0TZZKllHKOeV1zTdlKvIynpKNMO4J7nzbaDsEBB/z3pQd4LvXi/oQLfzoFFAhVAGdh7nLJ05GUqveA\
        QAA
        """
        guard let compressed = Data(base64Encoded: gzipBase64.replacingOccurrences(of: "\n", with: "")) else {
            XCTFail("Expected valid base64 fixture")
            return
        }

        let decode = try XCTUnwrap(
            CapturedBodyDecoder.decode(
                bodyData: compressed,
                headers: [HTTPHeaderField(name: "Content-Encoding", value: "gzip")]
            )
        )

        XCTAssertTrue(JSONTreeParser.canParseJSONObject(from: decode.analysisData))

        let root = try JSONTreeParser.parse(decode.analysisData)
        guard case .array(_, let children) = root else {
            XCTFail("Expected array root for multi-record stream")
            return
        }
        XCTAssertEqual(children.count, 2)
    }

    func testParseSingleJSONObjectStillWorks() throws {
        let data = Data(#"{"alpha":1,"beta":"two"}"#.utf8)
        let root = try JSONTreeParser.parse(data)
        guard case .object(_, let children) = root else {
            XCTFail("Expected object root")
            return
        }
        XCTAssertEqual(children.count, 2)
    }
}
