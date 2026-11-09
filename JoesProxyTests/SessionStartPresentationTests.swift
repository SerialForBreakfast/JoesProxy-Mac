//
//  SessionStartPresentationTests.swift
//  JoesProxyTests
//
//  Tests for BA-2.1 safe presentation hints and configuration persistence.
//

import XCTest
@testable import JoesProxy

final class SessionStartPresentationTests: XCTestCase {

    func testSessionStartPresentationRecordDefaultValues() {
        let record = SessionStartPresentationRecord.default
        XCTAssertEqual(record.schemaVersion, 1)
        XCTAssertNil(record.selectedTargetID)
        XCTAssertNil(record.lastVerificationSummary)
        XCTAssertNil(record.lastVerifiedAt)
        XCTAssertTrue(record.reviewedCustomizationHintIDs.isEmpty)
    }

    func testSessionStartPresentationRecordEncodingAndDecoding() throws {
        let timestamp = Date(timeIntervalSince1970: 1700000000)
        let record = SessionStartPresentationRecord(
            schemaVersion: 1,
            selectedTargetID: "simulator",
            lastVerificationSummary: "HTTP 8080 • Root CA trusted",
            lastVerifiedAt: timestamp,
            reviewedCustomizationHintIDs: ["hint-1", "hint-2"]
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(SessionStartPresentationRecord.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.selectedTargetID, "simulator")
        XCTAssertEqual(decoded.lastVerificationSummary, "HTTP 8080 • Root CA trusted")
        XCTAssertEqual(decoded.lastVerifiedAt, timestamp)
        XCTAssertEqual(decoded.reviewedCustomizationHintIDs, ["hint-1", "hint-2"])
    }

    func testSessionStartPresentationRecordSchemaMigrationFallback() throws {
        let testDefaults = UserDefaults(suiteName: "testSessionStartPresentationRecordSchemaMigrationFallback")!
        testDefaults.removePersistentDomain(forName: "testSessionStartPresentationRecordSchemaMigrationFallback")

        let config = UserDefaultsAppConfiguration(userDefaults: testDefaults)

        // Write an unsupported schema version 999
        let futureJSON = """
        {
            "schemaVersion": 999,
            "selectedTargetID": "future-target",
            "reviewedCustomizationHintIDs": []
        }
        """.data(using: .utf8)!

        testDefaults.set(futureJSON, forKey: "sessionStartPresentationData")

        // Must safely fall back to default
        XCTAssertEqual(config.sessionStartPresentationRecord, SessionStartPresentationRecord.default)
    }

    func testUserDefaultsAppConfigurationPersistenceAndReset() {
        let testDefaults = UserDefaults(suiteName: "testUserDefaultsAppConfigurationPersistenceAndReset")!
        testDefaults.removePersistentDomain(forName: "testUserDefaultsAppConfigurationPersistenceAndReset")

        let config = UserDefaultsAppConfiguration(userDefaults: testDefaults)
        XCTAssertEqual(config.sessionStartPresentationRecord, .default)

        let customRecord = SessionStartPresentationRecord(
            selectedTargetID: "tvos",
            lastVerificationSummary: "Apple TV 4K",
            lastVerifiedAt: Date(),
            reviewedCustomizationHintIDs: ["hint-abc"]
        )
        config.sessionStartPresentationRecord = customRecord
        XCTAssertEqual(config.sessionStartPresentationRecord, customRecord)

        config.resetToDefaults()
        XCTAssertEqual(config.sessionStartPresentationRecord, .default)
    }
}
