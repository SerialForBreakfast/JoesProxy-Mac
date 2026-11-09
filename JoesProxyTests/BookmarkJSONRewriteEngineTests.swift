import Foundation
import XCTest
@testable import JoesProxy

final class BookmarkJSONRewriteEngineTests: XCTestCase {
    private let sampleConfigFixture = Data(
        """
        {
          "appConfig": {
            "ad_variant_keys_enabled": "true",
            "aa_oauth_flow": "true"
          },
          "serverTime": 123
        }
        """.utf8
    )

    func testApplyNestedDotPathRewrite() throws {
        let rewrite = BookmarkResponseFieldRewrite(
            jsonPath: "appConfig.ad_variant_keys_enabled",
            originalValueSnapshot: "true",
            overrideValue: .string("false")
        )

        let result = try BookmarkJSONRewriteEngine.apply(
            bodyData: sampleConfigFixture,
            rewrites: [rewrite]
        )

        let object = try JSONSerialization.jsonObject(with: result.patchedData) as? [String: Any]
        let appConfig = object?["appConfig"] as? [String: Any]
        XCTAssertEqual(appConfig?["ad_variant_keys_enabled"] as? String, "false")
        XCTAssertEqual(appConfig?["aa_oauth_flow"] as? String, "true")
        XCTAssertEqual(result.appliedRuleIDs, [rewrite.id])
        XCTAssertTrue(result.skippedRuleIDs.isEmpty)
    }

    func testDisabledRewriteIsSkipped() throws {
        let rewrite = BookmarkResponseFieldRewrite(
            jsonPath: "appConfig.ad_variant_keys_enabled",
            originalValueSnapshot: "true",
            overrideValue: .string("false"),
            isRuleEnabled: false
        )

        let result = try BookmarkJSONRewriteEngine.apply(
            bodyData: sampleConfigFixture,
            rewrites: [rewrite]
        )

        let object = try JSONSerialization.jsonObject(with: result.patchedData) as? [String: Any]
        let appConfig = object?["appConfig"] as? [String: Any]
        XCTAssertEqual(appConfig?["ad_variant_keys_enabled"] as? String, "true")
        XCTAssertTrue(result.appliedRuleIDs.isEmpty)
    }

    func testValueLookupAtPath() {
        let value = BookmarkJSONRewriteEngine.value(
            at: "appConfig.ad_variant_keys_enabled",
            in: sampleConfigFixture
        )
        XCTAssertEqual(value, .string("true"))
    }

    func testSimpleTitleRewriteApplicabilityScenario() throws {
        let body = Data(#"{"title":"Original"}"#.utf8)
        let rewrite = BookmarkResponseFieldRewrite(
            jsonPath: "title",
            overrideValue: .string("Updated Title")
        )

        let result = try BookmarkJSONRewriteEngine.apply(bodyData: body, rewrites: [rewrite])
        XCTAssertEqual(result.appliedRuleIDs, [rewrite.id])
    }

    func testArrayOverrideRewrite() throws {
        let fixture = Data(
            """
            {"castNames":["Alice","Bob"]}
            """.utf8
        )
        let rewrite = BookmarkResponseFieldRewrite(
            jsonPath: "castNames",
            overrideValue: .array([.string("Carol"), .string("Dave")])
        )

        let result = try BookmarkJSONRewriteEngine.apply(bodyData: fixture, rewrites: [rewrite])
        let object = try JSONSerialization.jsonObject(with: result.patchedData) as? [String: Any]
        let castNames = object?["castNames"] as? [String]
        XCTAssertEqual(castNames, ["Carol", "Dave"])
    }

    func testJSONFragmentUserInputParsesArray() {
        let value = BookmarkJSONValue.fromUserInput(#"["one","two"]"#, mode: .json)
        guard case .array(let entries) = value else {
            XCTFail("Expected array value")
            return
        }
        XCTAssertEqual(entries, [.string("one"), .string("two")])
    }

    func testBookmarkJSONValueCodableRoundTripForArrayAndObject() throws {
        let original: BookmarkJSONValue = .object([
            "title": .string("Movie"),
            "tags": .array([.string("drama")])
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BookmarkJSONValue.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Neutral JSON mutation model (AL-2)

    func testNeutralApplyReportsAppliedOutcome() throws {
        let mutation = JSONResponseMutation(locator: "appConfig.ad_variant_keys_enabled", value: .string("false"))
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: sampleConfigFixture, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .applied)
        let object = try JSONSerialization.jsonObject(with: result.patchedData) as? [String: Any]
        let appConfig = object?["appConfig"] as? [String: Any]
        XCTAssertEqual(appConfig?["ad_variant_keys_enabled"] as? String, "false")
    }

    func testNeutralApplyReportsInvalidLocatorForMalformedBracketSyntax() throws {
        let mutation = JSONResponseMutation(locator: "appConfig[abc", value: .string("false"))
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: sampleConfigFixture, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .invalidLocator)
    }

    func testNeutralApplyReportsParentMissingForNonExistentPath() throws {
        let mutation = JSONResponseMutation(locator: "doesNotExist.field", value: .string("x"))
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: sampleConfigFixture, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .parentMissing)
    }

    func testNeutralApplySupportsMultipleMutationsWithMixedOutcomes() throws {
        let goodMutation = JSONResponseMutation(locator: "serverTime", value: .number("456"))
        let badMutation = JSONResponseMutation(locator: "missing.field", value: .string("x"))
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: sampleConfigFixture, mutations: [goodMutation, badMutation])
        XCTAssertEqual(result.outcomes[goodMutation.id], .applied)
        XCTAssertEqual(result.outcomes[badMutation.id], .parentMissing)
        let object = try JSONSerialization.jsonObject(with: result.patchedData) as? [String: Any]
        XCTAssertEqual(object?["serverTime"] as? Int, 456)
    }

    func testValidateLocatorSyntaxAcceptsWellFormedLocator() throws {
        try BookmarkJSONRewriteEngine.validateLocatorSyntax("$.data.items[0].name")
    }

    func testValidateLocatorSyntaxRejectsMalformedBracket() {
        XCTAssertThrowsError(try BookmarkJSONRewriteEngine.validateLocatorSyntax("data[abc"))
    }

    /// `MCPMutationValidator.validateJSONPath` must accept/reject using the exact same parser as
    /// the engine — this is the concrete proof there is no drift between the two.
    func testValidatorAndEngineAgreeOnMalformedBracketSyntax() {
        XCTAssertThrowsError(try MCPMutationValidator.validateJSONPath("$.data[abc")) { error in
            guard case MCPMutationValidationError.malformedRequest = error else {
                return XCTFail("expected malformedRequest, got \(error)")
            }
        }
        XCTAssertThrowsError(try BookmarkJSONRewriteEngine.validateLocatorSyntax("$.data[abc"))
    }

    // MARK: - AL-3 insert semantics

    func testInsertAtBeginningMiddleAndAppend() throws {
        let fixture = Data(#"{"tags":["a","b"]}"#.utf8)

        let beginning = JSONResponseMutation(locator: "tags[0]", operation: .insert, value: .string("z"))
        let middle = JSONResponseMutation(locator: "tags[2]", operation: .insert, value: .string("c"))
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: fixture, mutations: [beginning, middle])

        XCTAssertEqual(result.outcomes[beginning.id], .applied)
        XCTAssertEqual(result.outcomes[middle.id], .applied)
        let object = try JSONSerialization.jsonObject(with: result.patchedData) as? [String: Any]
        XCTAssertEqual(object?["tags"] as? [String], ["z", "a", "c", "b"])
    }

    func testInsertRejectsIndexBeyondCountWithoutClamping() throws {
        let fixture = Data(#"{"tags":["a","b"]}"#.utf8)
        let mutation = JSONResponseMutation(locator: "tags[3]", operation: .insert, value: .string("x"))
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: fixture, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .indexOutOfRange)
    }

    func testInsertAppendAtCount() throws {
        let fixture = Data(#"{"tags":["a","b"]}"#.utf8)
        let mutation = JSONResponseMutation(locator: "tags[2]", operation: .insert, value: .string("c"))
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: fixture, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .applied)
        let object = try JSONSerialization.jsonObject(with: result.patchedData) as? [String: Any]
        XCTAssertEqual(object?["tags"] as? [String], ["a", "b", "c"])
    }

    func testInsertReportsParentMissingForMissingArray() throws {
        let fixture = Data(#"{"title":"x"}"#.utf8)
        let mutation = JSONResponseMutation(locator: "tags[0]", operation: .insert, value: .string("a"))
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: fixture, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .parentMissing)
    }

    func testInsertReportsWrongContainerTypeForObjectKeyTerminal() throws {
        let fixture = Data(#"{"tags":["a"]}"#.utf8)
        let mutation = JSONResponseMutation(locator: "tags", operation: .insert, value: .string("a"))
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: fixture, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .wrongContainerType)
    }

    func testInsertReportsWrongContainerTypeWhenParentIsNotArray() throws {
        let fixture = Data(#"{"meta":{"tags":"not-array"}}"#.utf8)
        let mutation = JSONResponseMutation(locator: "meta.tags[0]", operation: .insert, value: .string("a"))
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: fixture, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .wrongContainerType)
    }

    func testMixedSetAndInsertMutations() throws {
        let fixture = Data(#"{"items":[{"name":"a"},{"name":"b"}]}"#.utf8)
        let insert = JSONResponseMutation(locator: "items[1]", operation: .insert, value: .object(["name": .string("mid")]))
        let set = JSONResponseMutation(locator: "items[0].name", operation: .set, value: .string("A"))
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: fixture, mutations: [insert, set])
        XCTAssertEqual(result.outcomes[insert.id], .applied)
        XCTAssertEqual(result.outcomes[set.id], .applied)
        let object = try JSONSerialization.jsonObject(with: result.patchedData) as? [String: Any]
        let items = object?["items"] as? [[String: Any]]
        XCTAssertEqual(items?.count, 3)
        XCTAssertEqual(items?.first?["name"] as? String, "A")
    }

    func testValidateLocatorSyntaxRejectsNegativeIndex() {
        XCTAssertThrowsError(try BookmarkJSONRewriteEngine.validateLocatorSyntax("tags[-1]"))
    }

    func testLocatorIsValidForInsertAcceptsAppendIndex() {
        let fixture = Data(#"{"tags":["a","b"]}"#.utf8)
        XCTAssertTrue(BookmarkJSONRewriteEngine.locatorIsValidForInsert("tags[2]", in: fixture))
        XCTAssertFalse(BookmarkJSONRewriteEngine.locatorIsValidForInsert("tags[3]", in: fixture))
    }

    func testLegacyRewriteWithoutOperationFieldDecodesAsSet() throws {
        let json = """
        {
          "id": "550E8400-E29B-41D4-A716-446655440000",
          "jsonPath": "title",
          "overrideValue": {"type":"string","value":"Updated"},
          "isRuleEnabled": true
        }
        """.data(using: .utf8)!
        let rewrite = try JSONDecoder().decode(BookmarkResponseFieldRewrite.self, from: json)
        XCTAssertEqual(rewrite.operation, .set)
    }

    // MARK: - Wildcard selectors (semantic live-response transformation)

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
            },
            {
              "id": "channel-2",
              "programs": [
                { "id": "program-3", "title": "Evening Report" }
              ]
            }
          ]
        }
        """.utf8
    )

    func testWildcardOnTopLevelArrayAppliesToEveryElement() throws {
        let body = Data(#"{"titles":["One","Two","Three"]}"#.utf8)
        let mutation = JSONResponseMutation(locator: "titles[*]", operation: .appendString, value: .string("!"))
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: body, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .applied)
        let object = try JSONSerialization.jsonObject(with: result.patchedData) as? [String: Any]
        XCTAssertEqual(object?["titles"] as? [String], ["One!", "Two!", "Three!"])
    }

    func testNestedWildcardsFanOutAcrossEPGShape() throws {
        let mutation = JSONResponseMutation(
            locator: "channels[*].programs[*].title",
            operation: .appendString,
            value: .string("!")
        )
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: epgFixture, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .applied)

        let object = try JSONSerialization.jsonObject(with: result.patchedData) as? [String: Any]
        let channels = try XCTUnwrap(object?["channels"] as? [[String: Any]])
        let channel1Programs = try XCTUnwrap(channels[0]["programs"] as? [[String: Any]])
        let channel2Programs = try XCTUnwrap(channels[1]["programs"] as? [[String: Any]])
        XCTAssertEqual(channel1Programs[0]["title"] as? String, "Morning News!")
        XCTAssertEqual(channel1Programs[1]["title"] as? String, "The Longest Weekend!")
        XCTAssertEqual(channel2Programs[0]["title"] as? String, "Evening Report!")
        // Unrelated sibling fields (IDs) must be untouched.
        XCTAssertEqual(channels[0]["id"] as? String, "channel-1")
        XCTAssertEqual(channel1Programs[0]["id"] as? String, "program-1")
    }

    func testWildcardTypeMismatchOnOneElementDoesNotBlockSiblings() throws {
        let body = Data(#"{"items":["a string", 42, "another string"]}"#.utf8)
        let mutation = JSONResponseMutation(locator: "items[*]", operation: .appendString, value: .string("!"))
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: body, mutations: [mutation])
        // At least one string element succeeded, so the aggregate outcome is `.applied` — the
        // shared engine keeps a coarse per-mutation contract; per-selector granularity is a
        // preview-only concern (Phase 7), not a change to this shipped contract.
        XCTAssertEqual(result.outcomes[mutation.id], .applied)
        let object = try JSONSerialization.jsonObject(with: result.patchedData) as? [String: Any]
        let items = try XCTUnwrap(object?["items"] as? [Any])
        XCTAssertEqual(items[0] as? String, "a string!")
        XCTAssertEqual(items[1] as? Int, 42, "non-string element must be left untouched, never coerced")
        XCTAssertEqual(items[2] as? String, "another string!")
    }

    func testWildcardAgainstEmptyArrayReportsDistinctZeroMatchOutcome() throws {
        let body = Data(#"{"items":[]}"#.utf8)
        let mutation = JSONResponseMutation(locator: "items[*]", operation: .appendString, value: .string("!"))
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: body, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .wildcardMatchedNothing)
    }

    func testWildcardCombinedWithInsertIsRejected() throws {
        XCTAssertThrowsError(try BookmarkJSONRewriteEngine.validateInsertLocatorSyntax("items[*][0]")) { error in
            guard case BookmarkJSONRewriteError.wrongContainerType = error else {
                return XCTFail("Expected wrongContainerType, got \(error)")
            }
        }

        let mutation = JSONResponseMutation(locator: "items[*]", operation: .insert, value: .string("x"))
        let result = try BookmarkJSONRewriteEngine.apply(
            bodyData: Data(#"{"items":["a"]}"#.utf8),
            mutations: [mutation]
        )
        XCTAssertEqual(result.outcomes[mutation.id], .wrongContainerType)
    }

    // MARK: - New typed operations (appendString / prependString / removeProperty)

    func testAppendStringAlwaysPolicyMutatesUnconditionally() throws {
        let body = Data(#"{"title":"Morning News"}"#.utf8)
        let mutation = JSONResponseMutation(
            locator: "title",
            operation: .appendString,
            value: .string("!"),
            repeatPolicy: .always
        )
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: body, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .applied)
        let object = try JSONSerialization.jsonObject(with: result.patchedData) as? [String: Any]
        XCTAssertEqual(object?["title"] as? String, "Morning News!")
    }

    func testAppendStringIfMissingSuffixIsIdempotentAcrossRepeatedApplication() throws {
        let mutation = JSONResponseMutation(
            locator: "title",
            operation: .appendString,
            value: .string("!"),
            repeatPolicy: .ifMissingSuffix
        )

        let firstPass = try BookmarkJSONRewriteEngine.apply(
            bodyData: Data(#"{"title":"Morning News"}"#.utf8),
            mutations: [mutation]
        )
        let firstObject = try JSONSerialization.jsonObject(with: firstPass.patchedData) as? [String: Any]
        XCTAssertEqual(firstObject?["title"] as? String, "Morning News!")

        // Same never-mutated-at-origin body, applied a second time — must not accumulate "!!".
        let secondPass = try BookmarkJSONRewriteEngine.apply(
            bodyData: firstPass.patchedData,
            mutations: [mutation]
        )
        let secondObject = try JSONSerialization.jsonObject(with: secondPass.patchedData) as? [String: Any]
        XCTAssertEqual(secondObject?["title"] as? String, "Morning News!")
    }

    func testPrependStringIfMissingSuffixChecksPrefix() throws {
        let mutation = JSONResponseMutation(
            locator: "title",
            operation: .prependString,
            value: .string("LIVE: "),
            repeatPolicy: .ifMissingSuffix
        )
        let firstPass = try BookmarkJSONRewriteEngine.apply(
            bodyData: Data(#"{"title":"Morning News"}"#.utf8),
            mutations: [mutation]
        )
        let firstObject = try JSONSerialization.jsonObject(with: firstPass.patchedData) as? [String: Any]
        XCTAssertEqual(firstObject?["title"] as? String, "LIVE: Morning News")

        let secondPass = try BookmarkJSONRewriteEngine.apply(bodyData: firstPass.patchedData, mutations: [mutation])
        let secondObject = try JSONSerialization.jsonObject(with: secondPass.patchedData) as? [String: Any]
        XCTAssertEqual(secondObject?["title"] as? String, "LIVE: Morning News")
    }

    func testAppendStringOnNonStringValueReportsTypeMismatchNeverCoerces() throws {
        let body = Data(#"{"serverTime":123}"#.utf8)
        let mutation = JSONResponseMutation(locator: "serverTime", operation: .appendString, value: .string("!"))
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: body, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .typeMismatch)
        let object = try JSONSerialization.jsonObject(with: result.patchedData) as? [String: Any]
        XCTAssertEqual(object?["serverTime"] as? Int, 123)
    }

    func testRemovePropertyRemovesObjectKey() throws {
        let body = Data(#"{"title":"Morning News","debugFlag":true}"#.utf8)
        let mutation = JSONResponseMutation(locator: "debugFlag", operation: .removeProperty, value: .null)
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: body, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .applied)
        let object = try JSONSerialization.jsonObject(with: result.patchedData) as? [String: Any]
        XCTAssertNil(object?["debugFlag"])
        XCTAssertEqual(object?["title"] as? String, "Morning News")
    }

    func testRemovePropertyRejectedOnArrayIndexTerminal() throws {
        let body = Data(#"{"items":["a","b"]}"#.utf8)
        let mutation = JSONResponseMutation(locator: "items[0]", operation: .removeProperty, value: .null)
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: body, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .wrongContainerType)
    }

    func testValidatorAndEngineAgreeOnWellFormedLocator() throws {
        try MCPMutationValidator.validateJSONPath("$.data.items[0].name")
        try BookmarkJSONRewriteEngine.validateLocatorSyntax("$.data.items[0].name")
    }

    // MARK: - removeIndex / move semantics

    func testRemoveIndexAtBeginningMiddleAndEnd() throws {
        let beginning = JSONResponseMutation(locator: "tags[0]", operation: .removeIndex, value: .null)
        let beginningResult = try BookmarkJSONRewriteEngine.apply(
            bodyData: Data(#"{"tags":["a","b","c"]}"#.utf8),
            mutations: [beginning]
        )
        XCTAssertEqual(beginningResult.outcomes[beginning.id], .applied)
        let beginningObject = try JSONSerialization.jsonObject(with: beginningResult.patchedData) as? [String: Any]
        XCTAssertEqual(beginningObject?["tags"] as? [String], ["b", "c"])

        let middle = JSONResponseMutation(locator: "tags[1]", operation: .removeIndex, value: .null)
        let middleResult = try BookmarkJSONRewriteEngine.apply(
            bodyData: Data(#"{"tags":["a","b","c"]}"#.utf8),
            mutations: [middle]
        )
        XCTAssertEqual(middleResult.outcomes[middle.id], .applied)
        let middleObject = try JSONSerialization.jsonObject(with: middleResult.patchedData) as? [String: Any]
        XCTAssertEqual(middleObject?["tags"] as? [String], ["a", "c"])

        let end = JSONResponseMutation(locator: "tags[2]", operation: .removeIndex, value: .null)
        let endResult = try BookmarkJSONRewriteEngine.apply(
            bodyData: Data(#"{"tags":["a","b","c"]}"#.utf8),
            mutations: [end]
        )
        XCTAssertEqual(endResult.outcomes[end.id], .applied)
        let endObject = try JSONSerialization.jsonObject(with: endResult.patchedData) as? [String: Any]
        XCTAssertEqual(endObject?["tags"] as? [String], ["a", "b"])
    }

    /// Unlike `.insert`'s `0...count`, `.removeIndex` is strict `0..<count` — index == count
    /// isn't a real element, so it must be rejected, never clamped to "the last element."
    func testRemoveIndexRejectsIndexEqualToCount() throws {
        let fixture = Data(#"{"tags":["a","b"]}"#.utf8)
        let mutation = JSONResponseMutation(locator: "tags[2]", operation: .removeIndex, value: .null)
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: fixture, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .indexOutOfRange)
    }

    func testRemoveIndexReportsParentMissingForMissingArray() throws {
        let fixture = Data(#"{"title":"x"}"#.utf8)
        let mutation = JSONResponseMutation(locator: "tags[0]", operation: .removeIndex, value: .null)
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: fixture, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .parentMissing)
    }

    func testRemoveIndexReportsWrongContainerTypeForObjectKeyTerminal() throws {
        let fixture = Data(#"{"tags":["a"]}"#.utf8)
        let mutation = JSONResponseMutation(locator: "tags", operation: .removeIndex, value: .null)
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: fixture, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .wrongContainerType)
    }

    func testMoveElementFromBeginningToEnd() throws {
        let fixture = Data(#"{"tags":["a","b","c","d"]}"#.utf8)
        let mutation = JSONResponseMutation(locator: "tags[0]", operation: .move, value: .number("3"))
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: fixture, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .applied)
        let object = try JSONSerialization.jsonObject(with: result.patchedData) as? [String: Any]
        XCTAssertEqual(object?["tags"] as? [String], ["b", "c", "d", "a"])
    }

    func testMoveElementFromEndToBeginning() throws {
        let fixture = Data(#"{"tags":["a","b","c","d"]}"#.utf8)
        let mutation = JSONResponseMutation(locator: "tags[3]", operation: .move, value: .number("0"))
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: fixture, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .applied)
        let object = try JSONSerialization.jsonObject(with: result.patchedData) as? [String: Any]
        XCTAssertEqual(object?["tags"] as? [String], ["d", "a", "b", "c"])
    }

    func testMoveFromEqualsToIsNoOp() throws {
        let fixture = Data(#"{"tags":["a","b","c"]}"#.utf8)
        let mutation = JSONResponseMutation(locator: "tags[1]", operation: .move, value: .number("1"))
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: fixture, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .applied)
        let object = try JSONSerialization.jsonObject(with: result.patchedData) as? [String: Any]
        XCTAssertEqual(object?["tags"] as? [String], ["a", "b", "c"])
    }

    func testMoveRejectsFromIndexOutOfRange() throws {
        let fixture = Data(#"{"tags":["a","b"]}"#.utf8)
        let mutation = JSONResponseMutation(locator: "tags[5]", operation: .move, value: .number("0"))
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: fixture, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .indexOutOfRange)
    }

    /// Bounds for `to` are checked against the array's length BEFORE removal (see
    /// `assignMoveValue`'s doc comment) — moving to the last valid position must succeed, and one
    /// past it must be rejected without clamping.
    func testMoveRejectsToIndexOutOfRange() throws {
        let fixture = Data(#"{"tags":["a","b"]}"#.utf8)
        let mutation = JSONResponseMutation(locator: "tags[0]", operation: .move, value: .number("2"))
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: fixture, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .indexOutOfRange)
    }

    func testMoveRequiresNumericValue() throws {
        let fixture = Data(#"{"tags":["a","b"]}"#.utf8)
        let mutation = JSONResponseMutation(locator: "tags[0]", operation: .move, value: .string("not-a-number"))
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: fixture, mutations: [mutation])
        XCTAssertEqual(result.outcomes[mutation.id], .typeMismatch)
    }

    func testWildcardCombinedWithRemoveIndexIsRejected() throws {
        XCTAssertThrowsError(try BookmarkJSONRewriteEngine.validateRemoveIndexLocatorSyntax("items[*][0]")) { error in
            guard case BookmarkJSONRewriteError.wrongContainerType = error else {
                return XCTFail("Expected wrongContainerType, got \(error)")
            }
        }

        let mutation = JSONResponseMutation(locator: "items[*]", operation: .removeIndex, value: .null)
        let result = try BookmarkJSONRewriteEngine.apply(
            bodyData: Data(#"{"items":["a"]}"#.utf8),
            mutations: [mutation]
        )
        XCTAssertEqual(result.outcomes[mutation.id], .wrongContainerType)
    }

    func testWildcardCombinedWithMoveIsRejected() throws {
        XCTAssertThrowsError(try BookmarkJSONRewriteEngine.validateMoveLocatorSyntax("items[*][0]")) { error in
            guard case BookmarkJSONRewriteError.wrongContainerType = error else {
                return XCTFail("Expected wrongContainerType, got \(error)")
            }
        }

        let mutation = JSONResponseMutation(locator: "items[*]", operation: .move, value: .number("0"))
        let result = try BookmarkJSONRewriteEngine.apply(
            bodyData: Data(#"{"items":["a","b"]}"#.utf8),
            mutations: [mutation]
        )
        XCTAssertEqual(result.outcomes[mutation.id], .wrongContainerType)
    }

    func testValidatorAndEngineAgreeOnRemoveIndexAndMoveLocators() throws {
        try MCPMutationValidator.validateJSONPath("$.tags[0]")
        try BookmarkJSONRewriteEngine.validateRemoveIndexLocatorSyntax("$.tags[0]")
        try BookmarkJSONRewriteEngine.validateMoveLocatorSyntax("$.tags[0]")
    }

    /// Proves the existing non-atomic-across-batch contract (`testMixedSetAndInsertMutations`)
    /// still holds correctly with the two new operations mixed in: each mutation applies
    /// independently against the shared, progressively-mutating root.
    func testMixedRemoveIndexAndMoveMutationsInSameBatch() throws {
        let fixture = Data(#"{"tags":["a","b","c","d"]}"#.utf8)
        let remove = JSONResponseMutation(locator: "tags[0]", operation: .removeIndex, value: .null)
        // After the remove above, tags is ["b","c","d"] — move operates on that already-mutated
        // root, since the batch shares one mutating root and applies sequentially.
        let move = JSONResponseMutation(locator: "tags[0]", operation: .move, value: .number("2"))
        let result = try BookmarkJSONRewriteEngine.apply(bodyData: fixture, mutations: [remove, move])
        XCTAssertEqual(result.outcomes[remove.id], .applied)
        XCTAssertEqual(result.outcomes[move.id], .applied)
        let object = try JSONSerialization.jsonObject(with: result.patchedData) as? [String: Any]
        XCTAssertEqual(object?["tags"] as? [String], ["c", "d", "b"])
    }
}
