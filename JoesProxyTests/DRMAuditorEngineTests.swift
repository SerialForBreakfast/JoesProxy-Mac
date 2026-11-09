//
//  DRMAuditorEngineTests.swift
//  JoesProxyTests
//
//  Unit tests for FairPlay, Widevine, and PlayReady DRM key extraction,
//  PSSH box parsing, Content ID mismatch detection, and HTTP 200 error masking.
//

import XCTest
@testable import JoesProxy

final class DRMAuditorEngineTests: XCTestCase {

    func testFairPlaySKDExtractionAndContentIDMismatch() {
        let manifest = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:6
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://fps.example.com/content-alpha-123",KEYFORMAT="com.apple.streamingkeydelivery",KEYFORMATVERSIONS="1"
        #EXTINF:6.0,
        segment1.m4s
        """

        let manifestSession = makeSession(path: "/master.m3u8", text: manifest)
        let licenseSession = makeSession(
            path: "/fps/license?contentId=content-beta-999",
            text: "encrypted-ckc-payload",
            headers: [HTTPHeaderField(name: "Authorization", value: "Bearer sample-token")]
        )

        let report = DRMAuditorEngine.audit(
            manifestSessions: [manifestSession],
            licenseSessions: [licenseSession]
        )

        XCTAssertEqual(report.drmSystem, .fairPlay)
        XCTAssertEqual(report.keyInfo?.method, "SAMPLE-AES")
        XCTAssertEqual(report.keyInfo?.contentID, "content-alpha-123")
        XCTAssertFalse(report.isHandshakeHealthy)
        XCTAssertTrue(report.defects.contains(where: {
            if case .contentIDMismatch(let manifestID, let licenseID) = $0 {
                return manifestID == "content-alpha-123" && licenseID == "content-beta-999"
            }
            return false
        }))
    }

    func testWidevinePSSHBoxExtraction() {
        // Construct synthetic fMP4 'pssh' box for Widevine
        // Box Size (32-bit): 44 bytes (0x00, 0x00, 0x00, 0x2C)
        // Box Type: 'pssh' (0x70, 0x73, 0x73, 0x68)
        // Version: 1 (0x01), Flags: (0x00, 0x00, 0x00)
        // Widevine SystemID (16 bytes): ed ef 8b a9 79 d6 4a ce a3 c8 27 dc d5 1d 21 ed
        // Key ID Count: 1 (0x00, 0x00, 0x00, 0x01)
        // Key ID (16 bytes): 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10
        // Data Size (0x00, 0x00, 0x00, 0x00)
        var psshData = Data([
            0x00, 0x00, 0x00, 0x30, // 48 bytes total box
            0x70, 0x73, 0x73, 0x68, // 'pssh'
            0x01, 0x00, 0x00, 0x00, // Version 1, Flags 0
            0xed, 0xef, 0x8b, 0xa9, 0x79, 0xd6, 0x4a, 0xce, 0xa3, 0xc8, 0x27, 0xdc, 0xd5, 0x1d, 0x21, 0xed, // Widevine SystemID
            0x00, 0x00, 0x00, 0x01, // 1 Key ID
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, // Key ID 1
            0x00, 0x00, 0x00, 0x00  // Data size 0
        ])

        let boxes = DRMAuditorEngine.extractPSSHBoxes(from: psshData)
        XCTAssertEqual(boxes.count, 1)
        guard let box = boxes.first else { return }

        XCTAssertEqual(box.systemName, "Widevine")
        XCTAssertEqual(box.systemID, "edef8ba9-79d6-4ace-a3c8-27dcd51d21ed")
        XCTAssertEqual(box.version, 1)
        XCTAssertEqual(box.keyIDs.count, 1)
        XCTAssertEqual(box.keyIDs[0], "01020304-0506-0708-090a-0b0c0d0e0f10")
    }

    func testHTTP200ErrorEnvelopeDetection() {
        let licenseSession = makeSession(
            path: "/widevine/getlicense",
            text: "{\"status\": \"error\", \"error\": \"license_expired\", \"errorCode\": 403}",
            statusCode: 200,
            headers: [HTTPHeaderField(name: "Authorization", value: "Bearer sample-token")]
        )

        let report = DRMAuditorEngine.audit(licenseSessions: [licenseSession])

        XCTAssertFalse(report.isHandshakeHealthy)
        XCTAssertTrue(report.defects.contains(where: {
            if case .http200ErrorEnvelope = $0 { return true }
            return false
        }))
    }

    func testMissingIVForSampleAES() {
        let manifest = """
        #EXTM3U
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://fps.example.com/asset-1"
        """

        let manifestSession = makeSession(path: "/index.m3u8", text: manifest)
        let report = DRMAuditorEngine.audit(manifestSessions: [manifestSession])

        XCTAssertTrue(report.defects.contains(where: {
            if case .missingIVForSampleAES = $0 { return true }
            return false
        }))
    }

    // MARK: - Helper

    private func makeSession(
        path: String,
        text: String,
        statusCode: Int = 200,
        headers: [HTTPHeaderField] = []
    ) -> SessionRecord {
        let bodyData = text.data(using: .utf8)
        let request = CapturedRequest(
            method: "POST",
            scheme: .https,
            host: "drm.example.com",
            port: 443,
            path: path,
            headers: headers,
            bodyData: nil,
            bodySize: nil
        )

        let response = CapturedResponse(
            statusCode: statusCode,
            headers: [
                HTTPHeaderField(name: "Content-Type", value: "application/json"),
                HTTPHeaderField(name: "Content-Length", value: "\(bodyData?.count ?? 0)")
            ],
            bodyData: bodyData,
            bodySize: bodyData?.count
        )

        return SessionRecord(
            request: request,
            response: response,
            state: .completed,
            timing: SessionTiming(startedAt: Date())
        )
    }
}
