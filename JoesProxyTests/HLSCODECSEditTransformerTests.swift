import Foundation
import XCTest
@testable import JoesProxy

final class HLSCODECSEditTransformerTests: XCTestCase {
    func testInsertsCodecsWithoutChangingUneditedBytesOrLineEndings() throws {
        let original = Data("""
        #EXTM3U\r
        #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="main"\r
        video/one.m3u8\r
        #EXT-X-STREAM-INF:BANDWIDTH=2000,CODECS="avc1.4d401f",AUDIO="main"\r
        video/two.m3u8\r
        """.utf8)
        let locator = try XCTUnwrap(
            HLSCODECSEditTransformer.variantLocators(in: original).first
        )

        let result = try HLSCODECSEditTransformer.apply(
            originalBytes: original,
            edits: [
                HLSCODECSVariantEdit(locator: locator, codecs: "avc1.640028,mp4a.40.2")
            ]
        )

        let expected = Data("""
        #EXTM3U\r
        #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="main",CODECS="avc1.640028,mp4a.40.2"\r
        video/one.m3u8\r
        #EXT-X-STREAM-INF:BANDWIDTH=2000,CODECS="avc1.4d401f",AUDIO="main"\r
        video/two.m3u8\r
        """.utf8)
        XCTAssertEqual(result.data, expected)
        XCTAssertEqual(result.editedVariantCount, 1)
        XCTAssertFalse(result.mediaVerified)
    }

    func testReplacesOnlyTheExistingCodecValue() throws {
        let original = Data(
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000,CODECS=\"old.codec\",RESOLUTION=1x1\nvideo.m3u8\n"
                .utf8
        )
        let locator = try XCTUnwrap(
            HLSCODECSEditTransformer.variantLocators(in: original).first
        )

        let result = try HLSCODECSEditTransformer.apply(
            originalBytes: original,
            edits: [
                HLSCODECSVariantEdit(locator: locator, codecs: "new.codec")
            ]
        )

        XCTAssertEqual(
            String(decoding: result.data, as: UTF8.self),
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000,CODECS=\"new.codec\",RESOLUTION=1x1\nvideo.m3u8\n"
        )
    }

    func testSupportsMultipleEditsInOneAtomicOperation() throws {
        let original = Data("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000
        one.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2000
        two.m3u8
        """.utf8)
        let locators = try HLSCODECSEditTransformer.variantLocators(in: original)

        let result = try HLSCODECSEditTransformer.apply(
            originalBytes: original,
            edits: locators.map {
                HLSCODECSVariantEdit(locator: $0, codecs: "avc1.640028,mp4a.40.2")
            }
        )

        XCTAssertEqual(result.editedVariantCount, 2)
        XCTAssertEqual(
            String(decoding: result.data, as: UTF8.self).components(separatedBy: "CODECS=").count,
            3
        )
    }

    func testRejectsStaleLocatorAfterSourceChanges() throws {
        let original = Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\none.m3u8\n".utf8)
        let locator = try XCTUnwrap(
            HLSCODECSEditTransformer.variantLocators(in: original).first
        )
        let changed = Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000\none.m3u8\n".utf8)

        XCTAssertThrowsError(
            try HLSCODECSEditTransformer.apply(
                originalBytes: changed,
                edits: [HLSCODECSVariantEdit(locator: locator, codecs: "avc1.4d401f")]
            )
        ) { error in
            XCTAssertEqual(error as? HLSCODECSEditError, .staleLocator(ordinal: 0))
        }
    }

    func testRejectsInvalidCodecValuesAndDuplicateAttributes() throws {
        let invalid = Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\none.m3u8\n".utf8)
        let locator = try XCTUnwrap(
            HLSCODECSEditTransformer.variantLocators(in: invalid).first
        )
        XCTAssertThrowsError(
            try HLSCODECSEditTransformer.apply(
                originalBytes: invalid,
                edits: [HLSCODECSVariantEdit(locator: locator, codecs: "avc1,,mp4a.40.2")]
            )
        ) { error in
            XCTAssertEqual(error as? HLSCODECSEditError, .invalidCodecValue)
        }

        let duplicate = Data(
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000,CODECS=\"a\",CODECS=\"b\"\none.m3u8\n"
                .utf8
        )
        let duplicateLocator = try XCTUnwrap(
            HLSCODECSEditTransformer.variantLocators(in: duplicate).first
        )
        XCTAssertThrowsError(
            try HLSCODECSEditTransformer.apply(
                originalBytes: duplicate,
                edits: [HLSCODECSVariantEdit(locator: duplicateLocator, codecs: "c")]
            )
        ) { error in
            XCTAssertEqual(error as? HLSCODECSEditError, .duplicateCodecAttribute(ordinal: 0))
        }
    }

    func testResolvePatchesUsesSharedEngineProvenance() throws {
        let original = Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nvideo.m3u8\n".utf8)
        let locator = try XCTUnwrap(HLSCODECSEditTransformer.variantLocators(in: original).first)
        let patches = try HLSCODECSEditTransformer.resolvePatches(
            originalBytes: original,
            edits: [HLSCODECSVariantEdit(locator: locator, codecs: "avc1.640028")]
        )

        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(
            patches.first?.provenance,
            .selectorAdapter(name: "hls-codecs", version: 1)
        )
        let engineResult = try BoundedBytePatchEngine.apply(
            originalBytes: original,
            patches: patches
        )
        let adapterResult = try HLSCODECSEditTransformer.apply(
            originalBytes: original,
            edits: [HLSCODECSVariantEdit(locator: locator, codecs: "avc1.640028")]
        )
        XCTAssertEqual(adapterResult.data, engineResult.data)
        XCTAssertTrue(String(decoding: adapterResult.data, as: UTF8.self).contains("CODECS=\"avc1.640028\""))
    }
}
