import XCTest
@testable import JoesProxy

final class HTTPChunkedFramingValidatorTests: XCTestCase {
    func testEveryFragmentBoundaryAndTrailers() {
        let wire = Array("4;name=value\r\ntest\r\n2\r\n!!\r\n0\r\nChecksum: synthetic\r\n\r\n".utf8)
        for split in 0...wire.count {
            var validator = HTTPChunkedFramingValidator()
            validator.consume(wire.prefix(split))
            validator.consume(wire.dropFirst(split))
            XCTAssertTrue(validator.isComplete, "split \(split)")
            XCTAssertFalse(validator.isInvalid)
        }
        var fragmented = HTTPChunkedFramingValidator()
        for byte in wire { fragmented.consume([byte]) }
        XCTAssertTrue(fragmented.isComplete)
        var whitespace = HTTPChunkedFramingValidator()
        whitespace.consume(Array("1 \t;name=value\r\na\r\n0\r\n\r\n".utf8))
        XCTAssertTrue(whitespace.isComplete)
    }

    func testTruncationNeverBecomesComplete() {
        let wire = Array("4\r\ntest\r\n0\r\n\r\n".utf8)
        for length in 0..<wire.count {
            var validator = HTTPChunkedFramingValidator()
            validator.consume(wire.prefix(length))
            XCTAssertFalse(validator.isComplete, "prefix \(length)")
        }
    }

    func testMalformedFramingAndOverflowRejectWithoutAllocation() {
        for wire in ["Z\r\n", "-1\r\n", "FFFFFFFFFFFFFFFFFFFFFFFF\r\n", "1\r\naX\n",
                     "1\ntest", "0\r\nBad Trailer\r\n\r\n", "0\r\n: value\r\n\r\n", "0\r\n\r\nextra"] {
            var validator = HTTPChunkedFramingValidator()
            validator.consume(Array(wire.utf8))
            XCTAssertTrue(validator.isInvalid, wire)
            XCTAssertFalse(validator.isComplete)
        }
    }

    func testLargePayloadIsSkippedWithoutRetainingIt() {
        var validator = HTTPChunkedFramingValidator()
        validator.consume(Array("1000000\r\n".utf8))
        let block = [UInt8](repeating: 42, count: 16_384)
        for _ in 0..<1024 { validator.consume(block) }
        XCTAssertFalse(validator.isComplete)
        validator.consume(Array("\r\n0\r\n\r\n".utf8))
        XCTAssertTrue(validator.isComplete)
        XCTAssertLessThan(MemoryLayout<HTTPChunkedFramingValidator>.size, 128)
    }

    func testParserRejectsImpossibleLengthsWithoutOverflow() throws {
        let parser = HTTPResponseParser()
        for value in ["-1", String(Int.max), "not-a-number"] {
            let wire = Data("HTTP/1.1 200 OK\r\nContent-Length: \(value)\r\n\r\n".utf8)
            XCTAssertNil(parser.parseFrameState(from: wire, requestMethod: "GET"))
        }
        for value in ["-1", "7fffffffffffffff"] {
            let wire = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\(value)\r\n".utf8)
            XCTAssertFalse(parser.isCompleteResponse(wire, requestMethod: "GET"))
            XCTAssertNoThrow(try parser.parse(wire), "Malformed capture decoding must not overflow")
        }
    }
}
