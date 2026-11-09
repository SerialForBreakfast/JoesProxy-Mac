import CryptoKit
import Foundation
import XCTest
@testable import JoesProxy

final class AgentWorkspaceMeasurementManifestTests: XCTestCase {
    func testV2MatchesExecutableProfileContractAndReceiptDigest() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("memlog/Research/Agent-Workspace-Measurement-Manifest-v2.json"))
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(manifest["schemaVersion"] as? Int, 2)
        XCTAssertEqual(manifest["phases"] as? [String], AgentWorkspaceProfileConfiguration.phases)
        let traffic = try XCTUnwrap(manifest["traffic"] as? [String: Any])
        XCTAssertEqual(traffic["bodyBytes"] as? Int, AgentWorkspaceProfileConfiguration.body.count)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let harness = try String(contentsOf: root.appendingPathComponent("JoesProxyUITests/AgentWorkspaceProfilingUITests.swift"), encoding: .utf8)
        XCTAssertTrue(harness.contains(digest))
    }
    private func manifestURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("memlog/Research/Agent-Workspace-Measurement-Manifest-v1.json")
    }

    func testManifestDecodesAndUsesTheExpectedVersion() throws {
        let data = try Data(contentsOf: manifestURL())
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let harness = manifest?["harness"] as? [String: Any]
        XCTAssertEqual(manifest?["schemaVersion"] as? Int, 1)
        XCTAssertEqual(manifest?["candidate"] as? String, "A")
        XCTAssertEqual(harness?["traffic"] as? String, "synthetic loopback only")
        XCTAssertEqual((manifest?["stopConditions"] as? [String])?.count, 4)
    }

    func testManifestFixtureDigestAndExpectedContractAreDeterministic() throws {
        let data = try Data(contentsOf: manifestURL())
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fixture = try XCTUnwrap(manifest["fixture"] as? [String: Any])
        let expected = try XCTUnwrap(manifest["expectedContract"] as? [String: Any])
        let body = try XCTUnwrap(fixture["bodyUTF8"] as? String)
        let digest = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(digest, fixture["bodySHA256"] as? String)
        XCTAssertEqual(digest, expected["deliveredBodySHA256"] as? String)
        XCTAssertEqual(Data(body.utf8).count, fixture["bodyByteCount"] as? Int)
        XCTAssertEqual(Data(body.utf8).count, expected["deliveredByteCount"] as? Int)
    }
}
