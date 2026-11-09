import XCTest
#if !JOESPROXY_CAPTION_CONTRACT_TESTS
@testable import JoesProxy
#endif

final class HLSPlaybackConfigurationTests: XCTestCase {
    func testEveryExplicitPresentationAndTimeShiftCombinationPreservesValidationOnRoundTrip() throws {
        for mode in HLSPresentationMode.allCases {
            for shift in HLSTimeShiftMode.allCases {
                var configuration = HLSPlaybackConfiguration.conformant
                configuration.presentationMode = mode
                configuration.timeShiftMode = shift
                let decoded = try JSONDecoder().decode(HLSPlaybackConfiguration.self,
                    from: JSONEncoder().encode(configuration))
                XCTAssertEqual(decoded, configuration)
                if mode == .vodStatic && shift != .off {
                    XCTAssertThrowsError(try decoded.validated()) { error in
                        XCTAssertEqual(error as? HLSPlaybackConfigurationError, .timeShiftRequiresLiveLoop)
                    }
                } else {
                    XCTAssertNoThrow(try decoded.validated())
                }
            }
        }
    }

    func testCacheAndWindowBoundaryValuesDoNotSilentlyClampOrIgnoreInputs() throws {
        for count in [HLSPlaybackConfiguration.minimumWindowSegmentCount,
                      HLSPlaybackConfiguration.maximumWindowSegmentCount] {
            var configuration = HLSPlaybackConfiguration.conformant
            configuration.windowSegmentCount = count
            XCTAssertEqual(try configuration.validated().windowSegmentCount, count)
        }
        for age in [-1, 0, 60, 61] {
            var configuration = HLSPlaybackConfiguration.conformant
            configuration.playlistCachePolicy = .maxAge
            configuration.playlistMaxAgeSeconds = age
            if (0...60).contains(age) {
                XCTAssertEqual(try configuration.validated().cacheControlHeader, "max-age=\(age)")
            } else {
                XCTAssertThrowsError(try configuration.validated())
            }
        }
        for policy in [HLSPlaylistCachePolicy.noCache, .noStore] {
            var configuration = HLSPlaybackConfiguration.conformant
            configuration.playlistCachePolicy = policy
            configuration.playlistMaxAgeSeconds = 0
            XCTAssertThrowsError(try configuration.validated()) { error in
                XCTAssertEqual(error as? HLSPlaybackConfigurationError, .maxAgeSecondsNotAllowed)
            }
        }
    }

    func testConformantDefaultHasNoRecommendationViolations() throws {
        let configuration = try HLSPlaybackConfiguration.conformant.validated()

        XCTAssertEqual(configuration.recommendationViolations, [])
        XCTAssertFalse(configuration.isDeliberatelyNonconformant)
        XCTAssertEqual(configuration.cacheControlHeader, "no-cache")
        XCTAssertEqual(configuration.effectiveTimeShiftMode, .off)
    }

    func testFaultControlsRequireExplicitDeliberateFaultIntent() {
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.loopBoundaryTreatment = .omitDiscontinuity
        configuration.segmentURIIdentity = .reuseAssetURI

        XCTAssertThrowsError(try configuration.validated()) { error in
            XCTAssertEqual(
                error as? HLSPlaybackConfigurationError,
                .deliberateFaultIntentRequired([.undeclaredLoopTimestampReset, .reusedSegmentURI])
            )
        }

        configuration.intent = .deliberateFault
        XCTAssertNoThrow(try configuration.validated())
    }

    func testCacheAndWindowBoundsFailClosed() {
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.windowSegmentCount = 1
        XCTAssertThrowsError(try configuration.validated())

        configuration = .conformant
        configuration.playlistCachePolicy = .maxAge
        XCTAssertThrowsError(try configuration.validated())

        configuration.playlistMaxAgeSeconds = 61
        XCTAssertThrowsError(try configuration.validated())

        configuration.playlistMaxAgeSeconds = 12
        XCTAssertNoThrow(try configuration.validated())
        XCTAssertEqual(configuration.cacheControlHeader, "max-age=12")
    }

    func testConfigurationWithoutPresentationModeDecodesAsLegacyCompatibility() throws {
        let json = """
        {
          "intent": "deliberateFault",
          "windowSegmentCount": 4,
          "loopBoundaryTreatment": "omitDiscontinuity",
          "segmentURIIdentity": "reuseAssetURI",
          "targetDurationTreatment": "source",
          "programDateTimeTreatment": "omit",
          "playlistCachePolicy": "noCache"
        }
        """

        let decoded = try JSONDecoder().decode(HLSPlaybackConfiguration.self, from: Data(json.utf8))

        XCTAssertNil(decoded.presentationMode)
        XCTAssertNil(decoded.timeShiftMode)
        XCTAssertEqual(decoded.effectiveTimeShiftMode, .off)
        XCTAssertEqual(decoded, .legacyCompatible)
    }

    func testExplicitPresentationModeRoundTrips() throws {
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .vodStatic

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(HLSPlaybackConfiguration.self, from: data)

        XCTAssertEqual(decoded.presentationMode, .vodStatic)
        XCTAssertEqual(decoded, configuration)
    }

    func testTimeShiftModesRequireLiveLoopAndAllowBoundedSmokeWindow() throws {
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.timeShiftMode = .warmDVR
        configuration.windowSegmentCount = HLSPlaybackConfiguration.boundedTimeShiftSmokeWindowSegmentCount

        XCTAssertThrowsError(try configuration.validated()) { error in
            XCTAssertEqual(error as? HLSPlaybackConfigurationError, .timeShiftRequiresLiveLoop)
        }

        configuration.presentationMode = .liveLoop
        XCTAssertNoThrow(try configuration.validated())

        configuration.windowSegmentCount = HLSPlaybackConfiguration.maximumWindowSegmentCount + 1
        XCTAssertThrowsError(try configuration.validated()) { error in
            XCTAssertEqual(error as? HLSPlaybackConfigurationError, .invalidWindowSegmentCount)
        }
    }

    func testExplicitTimeShiftModeRoundTrips() throws {
        var configuration = HLSPlaybackConfiguration.conformant
        configuration.presentationMode = .liveLoop
        configuration.timeShiftMode = .coldDVR
        configuration.windowSegmentCount = 15

        let decoded = try JSONDecoder().decode(
            HLSPlaybackConfiguration.self,
            from: JSONEncoder().encode(configuration)
        )

        XCTAssertEqual(decoded, configuration)
        XCTAssertEqual(decoded.effectiveTimeShiftMode, .coldDVR)
    }
}
