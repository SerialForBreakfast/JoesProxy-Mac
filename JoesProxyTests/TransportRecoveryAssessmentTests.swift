import XCTest
@testable import JoesProxy

final class TransportRecoveryAssessmentTests: XCTestCase {
    func testFailureTakesPrecedenceOverSuccessfulPrefixWrites() throws {
        let diagnostics = RequestTransportDiagnostics(now: 0)
        diagnostics.connected(now: 1)
        diagnostics.submitted(bytes: 100, now: 2)
        diagnostics.completed(bytes: 100, succeeded: true, now: 3)
        diagnostics.failed(error: HTTPResponseParserError.incompleteResponse)
        diagnostics.failed(error: HTTPResponseParserError.invalidChunkFraming)
        let assessment = TransportRecoveryAssessment.assess(diagnostics.snapshot())
        XCTAssertEqual(assessment.reason, .incomplete)
        XCTAssertEqual(assessment.impact, "transport_failure")
        XCTAssertTrue(assessment.actions.allSatisfy { $0.authority == "read_only_existing_disclosure_policy" })
        XCTAssertLessThan(try JSONEncoder().encode(assessment).count, 4096)
    }

    func testMissingPendingFailureCaptureAndReadGapStayDistinct() {
        XCTAssertEqual(TransportRecoveryAssessment.assess(nil).reason, .unavailable)
        var evidence = RequestTransportEvidence()
        evidence.captureEnabled = false
        XCTAssertEqual(TransportRecoveryAssessment.assess(evidence).impact, "capture_evidence_only")
        evidence.pendingWrites = 1
        XCTAssertEqual(TransportRecoveryAssessment.assess(evidence).reason, .pending)
        evidence.failedWrites = 1
        XCTAssertEqual(TransportRecoveryAssessment.assess(evidence).reason, .downstream)
        evidence.failedWrites = 0; evidence.pendingWrites = 0; evidence.captureEnabled = true
        evidence.maximumUpstreamReadGapSeconds = 2
        XCTAssertEqual(TransportRecoveryAssessment.assess(evidence).impact, "cause_unknown")
    }

    func testHistoricalTransportEvidenceDecodesWithoutFailureReason() throws {
        let data = try JSONEncoder().encode(RequestTransportEvidence())
        let decoded = try JSONDecoder().decode(RequestTransportEvidence.self, from: data)
        XCTAssertNil(decoded.failureReason)
        XCTAssertEqual(TransportRecoveryAssessment.assess(decoded).reason, .observed)
    }
}
