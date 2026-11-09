import XCTest
@testable import JoesProxy

final class BookmarkJSONPreviewOverlayTests: XCTestCase {
    private let fixture = Data(
        """
        {
          "movie": {
            "title": "Original Title",
            "castNames": ["Alice", "Bob"]
          }
        }
        """.utf8
    )

    func testPatchedPrettifiedTextReplacesMatchingLine() throws {
        let object = try JSONSerialization.jsonObject(with: fixture)
        let prettyData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let base = try XCTUnwrap(String(data: prettyData, encoding: .utf8))
        let overrides: [String: BookmarkJSONValue] = [
            "movie.title": .string("Preview Title")
        ]

        let patched = BookmarkJSONPreviewOverlay.patchedPrettifiedText(
            base: base,
            bodyData: fixture,
            overrides: overrides
        )

        XCTAssertTrue(patched.contains("\"Preview Title\""))
        XCTAssertFalse(patched.contains("\"Original Title\""))
    }

    func testPatchedTreeLabelForStringField() {
        let root = try! JSONTreeParser.parse(fixture)
        guard case .object(_, let rootChildren) = root,
              case .object(_, let movieChildren) = rootChildren.first(where: { node in
                  if case .object(let key, _) = node { return key == "movie" }
                  return false
              }),
              let titleNode = movieChildren.first(where: { node in
                  if case .string(let key, _) = node { return key == "title" }
                  return false
              }) else {
            XCTFail("Expected movie.title string node")
            return
        }

        let label = BookmarkJSONPreviewOverlay.patchedTreeLabel(
            for: titleNode,
            dotPath: "movie.title",
            override: .string("Preview Title")
        )

        XCTAssertTrue(label.contains("Preview Title"))
    }

    func testShouldUseFullBodyPreviewWhenRewriteCountExceedsThreshold() {
        XCTAssertFalse(BookmarkJSONPreviewOverlay.shouldUseFullBodyPreview(enabledRewriteCount: 3))
        XCTAssertFalse(
            BookmarkJSONPreviewOverlay.shouldUseFullBodyPreview(
                enabledRewriteCount: BookmarkJSONPreviewOverlay.fullBodyPreviewRewriteThreshold
            )
        )
        XCTAssertTrue(
            BookmarkJSONPreviewOverlay.shouldUseFullBodyPreview(
                enabledRewriteCount: BookmarkJSONPreviewOverlay.fullBodyPreviewRewriteThreshold + 1
            )
        )
    }

    func testPreviewBodyDataAppliesInsertWithIndexShift() throws {
        let fixture = Data(#"{"tags":["a","b"]}"#.utf8)
        let rewrites = [
            BookmarkResponseFieldRewrite(
                jsonPath: "tags[1]",
                overrideValue: .string("c"),
                operation: .insert,
                isRuleEnabled: true
            )
        ]

        let preview = try XCTUnwrap(BookmarkJSONPreviewOverlay.previewBodyData(base: fixture, rewrites: rewrites))
        let object = try JSONSerialization.jsonObject(with: preview) as? [String: Any]
        XCTAssertEqual(object?["tags"] as? [String], ["a", "c", "b"])
    }

    func testSetOnlyRewritesKeepSurgicalOverrides() {
        let rewrites = [
            BookmarkResponseFieldRewrite(
                jsonPath: "movie.title",
                overrideValue: .string("Preview"),
                operation: .set,
                isRuleEnabled: true
            )
        ]
        XCTAssertFalse(BookmarkJSONPreviewOverlay.shouldUseEngineBackedPreview(for: rewrites))
        XCTAssertEqual(BookmarkJSONPreviewOverlay.overrides(from: rewrites).count, 1)
    }
}
