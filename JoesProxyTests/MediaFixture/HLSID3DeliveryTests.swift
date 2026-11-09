import XCTest
@testable import JoesProxy

final class HLSID3DeliveryTests: XCTestCase {

    private func profileDirectory(for id: String) -> URL {
        let repoRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.appendingPathComponent("Fixtures/HLS/\(id)", isDirectory: true)
    }

    func testID3MuxedAVEquivalentProfile() throws {
        let dir = profileDirectory(for: "id3-muxed-av-equivalent")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.path))

        let descriptor = HLSFixtureProfileDescriptor.load(from: dir)
        XCTAssertEqual(descriptor.audioTopology, "muxedOnly")
        let schedule = try XCTUnwrap(descriptor.id3Schedule)
        XCTAssertEqual(schedule.carrier, "mpeg2TS")
        XCTAssertEqual(schedule.version, "id3v2.3")
        XCTAssertTrue(schedule.allowedFrameIDs.contains("TIT2"))

        let validation = HLSID3Validator.validate(profileDirectory: dir, descriptor: descriptor)
        XCTAssertTrue(validation.isValid, "Profile validation errors: \(validation.errors)")
        XCTAssertGreaterThan(validation.parsedMarkersCount, 0)
    }

    func testID3DemuxedProgramProfile() throws {
        let dir = profileDirectory(for: "id3-demuxed-program")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.path))

        let descriptor = HLSFixtureProfileDescriptor.load(from: dir)
        XCTAssertEqual(descriptor.audioTopology, "demuxedAll")
        let schedule = try XCTUnwrap(descriptor.id3Schedule)
        XCTAssertEqual(schedule.carrier, "mpeg2TS")

        let validation = HLSID3Validator.validate(profileDirectory: dir, descriptor: descriptor)
        XCTAssertTrue(validation.isValid, "Profile validation errors: \(validation.errors)")
        XCTAssertGreaterThan(validation.parsedMarkersCount, 0)
    }

    func testID3HybridProgramOnlyProfile() throws {
        let dir = profileDirectory(for: "id3-hybrid-program-only")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.path))

        let descriptor = HLSFixtureProfileDescriptor.load(from: dir)
        XCTAssertEqual(descriptor.audioTopology, "hybridInBandProgramAD")

        let validation = HLSID3Validator.validate(profileDirectory: dir, descriptor: descriptor)
        XCTAssertTrue(validation.isValid, "Profile validation errors: \(validation.errors)")
        XCTAssertGreaterThan(validation.parsedMarkersCount, 0)
    }

    func testID3HybridEquivalentProfile() throws {
        let dir = profileDirectory(for: "id3-hybrid-equivalent")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.path))

        let descriptor = HLSFixtureProfileDescriptor.load(from: dir)
        XCTAssertEqual(descriptor.audioTopology, "hybridInBandProgramAD")

        let validation = HLSID3Validator.validate(profileDirectory: dir, descriptor: descriptor)
        XCTAssertTrue(validation.isValid, "Profile validation errors: \(validation.errors)")
        XCTAssertGreaterThan(validation.parsedMarkersCount, 0)
    }

    func testID3PackedAudioTimestampProfile() throws {
        let dir = profileDirectory(for: "id3-packed-audio-timestamp")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.path))

        let descriptor = HLSFixtureProfileDescriptor.load(from: dir)
        let schedule = try XCTUnwrap(descriptor.id3Schedule)
        XCTAssertEqual(schedule.carrier, "packedAudioTimestamp")
        XCTAssertTrue(schedule.allowedFrameIDs.contains("PRIV"))

        let validation = HLSID3Validator.validate(profileDirectory: dir, descriptor: descriptor)
        XCTAssertTrue(validation.isValid, "Profile validation errors: \(validation.errors)")
        XCTAssertGreaterThan(validation.parsedMarkersCount, 0)
    }
}
