import Foundation
import XCTest
@testable import JoesProxy

final class JSONStructuralProfilerTests: XCTestCase {
    private let epgFixture = Data(
        """
        {
          "channels": [
            {
              "id": "channel-1",
              "programs": [
                { "id": "program-1", "title": "Morning News" },
                { "id": "program-2", "title": "The Longest Weekend" }
              ]
            }
          ]
        }
        """.utf8
    )

    func testRepeatedSiblingObjectShapesMergeIntoOneShape() {
        let profile = JSONStructuralProfiler.profile(bodyData: epgFixture)
        XCTAssertEqual(profile.status, .complete)
        guard case .object(let root)? = profile.shape,
              case .array(let channelElement, _, _)? = root["channels"],
              case .object(let channelProps)? = channelElement,
              case .array(let programElement, _, _)? = channelProps["programs"],
              case .object(let programProps)? = programElement
        else {
            return XCTFail("Expected merged nested object/array shape, got \(String(describing: profile.shape))")
        }
        XCTAssertEqual(programProps["title"], .string)
        XCTAssertEqual(programProps["id"], .string)
        // Exactly one merged program shape, not two separate ones.
        XCTAssertEqual(programProps.count, 2)
    }

    func testScalarTypeInference() {
        let body = Data(#"{"name":"x","count":1,"active":true,"missing":null}"#.utf8)
        let profile = JSONStructuralProfiler.profile(bodyData: body)
        guard case .object(let props)? = profile.shape else {
            return XCTFail("Expected object shape")
        }
        XCTAssertEqual(props["name"], .string)
        XCTAssertEqual(props["count"], .number)
        XCTAssertEqual(props["active"], .bool)
        XCTAssertEqual(props["missing"], .null)
    }

    func testArrayCardinalityRangeAcrossMultipleSamples() {
        let short = Data(#"{"items":["a"]}"#.utf8)
        let long = Data(#"{"items":["a","b","c"]}"#.utf8)
        let profile = JSONStructuralProfiler.profile(bodies: [short, long])
        guard case .object(let props)? = profile.shape,
              case .array(_, let minCount, let maxCount)? = props["items"] else {
            return XCTFail("Expected array shape")
        }
        XCTAssertEqual(minCount, 1)
        XCTAssertEqual(maxCount, 3)
        XCTAssertEqual(profile.sampleCount, 2)
    }

    func testStructurallyIdenticalButValueDifferentBodiesProduceSameFingerprint() {
        let a = Data(#"{"title":"Morning News"}"#.utf8)
        let b = Data(#"{"title":"Evening Report"}"#.utf8)
        let profileA = JSONStructuralProfiler.profile(bodyData: a)
        let profileB = JSONStructuralProfiler.profile(bodyData: b)
        XCTAssertEqual(profileA.schemaFingerprint, profileB.schemaFingerprint)
    }

    func testAddedPropertyProducesDifferentFingerprint() {
        let a = Data(#"{"title":"x"}"#.utf8)
        let b = Data(#"{"title":"x","subtitle":"y"}"#.utf8)
        let profileA = JSONStructuralProfiler.profile(bodyData: a)
        let profileB = JSONStructuralProfiler.profile(bodyData: b)
        XCTAssertNotEqual(profileA.schemaFingerprint, profileB.schemaFingerprint)
    }

    func testRenamedPropertyProducesDifferentFingerprint() {
        let a = Data(#"{"title":"x"}"#.utf8)
        let b = Data(#"{"name":"x"}"#.utf8)
        let profileA = JSONStructuralProfiler.profile(bodyData: a)
        let profileB = JSONStructuralProfiler.profile(bodyData: b)
        XCTAssertNotEqual(profileA.schemaFingerprint, profileB.schemaFingerprint)
    }

    func testKeyOrderAndWhitespaceDoNotChangeFingerprint() {
        let a = Data(#"{"title":"x","id":"1"}"#.utf8)
        let b = Data("{  \"id\"  :  \"2\" ,  \"title\"  :  \"y\"  }".utf8)
        let profileA = JSONStructuralProfiler.profile(bodyData: a)
        let profileB = JSONStructuralProfiler.profile(bodyData: b)
        XCTAssertEqual(profileA.schemaFingerprint, profileB.schemaFingerprint)
    }

    func testMalformedInputReportsMalformedStatusNotACrash() {
        let profile = JSONStructuralProfiler.profile(bodyData: Data("not json".utf8))
        XCTAssertEqual(profile.status, .malformed)
        XCTAssertNil(profile.shape)
        XCTAssertNil(profile.schemaFingerprint)
    }

    func testEmptyInputReportsEmptyStatus() {
        let profile = JSONStructuralProfiler.profile(bodies: [])
        XCTAssertEqual(profile.status, .empty)
    }

    func testIncompatibleShapesAtSamePositionReportMixedRatherThanPickingOne() {
        let a = Data(#"{"value":"a string"}"#.utf8)
        let b = Data(#"{"value":42}"#.utf8)
        let profile = JSONStructuralProfiler.profile(bodies: [a, b])
        guard case .object(let props)? = profile.shape, case .mixed(let alternatives)? = props["value"] else {
            return XCTFail("Expected mixed shape for a position observed as both string and number")
        }
        XCTAssertEqual(Set(alternatives), Set([.string, .number]))
    }
}
