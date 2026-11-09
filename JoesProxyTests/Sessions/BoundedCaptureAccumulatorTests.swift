//
//  BoundedCaptureAccumulatorTests.swift
//  JoesProxyTests
//
//  Unit tests for in-flight bounded capture retention and memory caps.
//

import XCTest
@testable import JoesProxy

@MainActor
final class BoundedCaptureAccumulatorTests: XCTestCase {

    func testAccumulateUnderLimit() {
        let limiter = CaptureBodyLimiter(limit: 1024)
        let accumulator = limiter.makeAccumulator()

        let chunk1 = "Hello, ".data(using: .utf8)!
        let chunk2 = "World!".data(using: .utf8)!

        accumulator.append(data: chunk1)
        accumulator.append(data: chunk2)

        let body = accumulator.finalize()
        XCTAssertEqual(body.size, 13)
        XCTAssertEqual(body.truncated, false)
        XCTAssertEqual(body.data, "Hello, World!".data(using: .utf8))
    }

    func testAccumulateExceedingLimit() {
        let limiter = CaptureBodyLimiter(limit: 10)
        let accumulator = limiter.makeAccumulator()

        let chunk1 = "12345".data(using: .utf8)!
        let chunk2 = "67890".data(using: .utf8)!
        let chunk3 = "ABCDE".data(using: .utf8)!

        accumulator.append(data: chunk1)
        accumulator.append(data: chunk2)
        accumulator.append(data: chunk3)

        let body = accumulator.finalize()
        XCTAssertEqual(body.size, 15)
        XCTAssertEqual(body.truncated, true)
        XCTAssertEqual(body.data?.count, 10)
        XCTAssertEqual(body.data, "1234567890".data(using: .utf8))
    }

    func testAccumulateEmpty() {
        let limiter = CaptureBodyLimiter(limit: 1024)
        let accumulator = limiter.makeAccumulator()

        let body = accumulator.finalize()
        XCTAssertNil(body.data)
        XCTAssertNil(body.size)
        XCTAssertFalse(body.truncated)
    }

    func testAccumulateMultiGigabyteSimulation() {
        // Limit to 1 MB
        let limiter = CaptureBodyLimiter(limit: 1_048_576)
        let accumulator = limiter.makeAccumulator()

        let chunk = Data(repeating: 0x41, count: 65_536) // 64 KB chunk
        // Append 100 chunks = 6.4 MB total
        for _ in 0..<100 {
            accumulator.append(data: chunk)
        }

        let body = accumulator.finalize()
        XCTAssertEqual(body.size, 6_553_600)
        XCTAssertEqual(body.truncated, true)
        XCTAssertEqual(body.data?.count, 1_048_576) // Exactly 1 MB
    }
}
