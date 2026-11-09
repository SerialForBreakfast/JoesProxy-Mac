import XCTest
@testable import JoesProxy

final class MCPCaptureStatusTests: XCTestCase {
    func testPressureFallbackIsExplicitAndSeparateFromRejectedRequests() throws {
        let admission = CaptureAdmissionBudget(byteLimit: 100, countLimit: 4)
        _ = try XCTUnwrap(admission.reserve(bytes: 90))
        _ = try XCTUnwrap(admission.reserveCapture(bytes: 50, metadataBytes: 10))
        let reduced = status("running", admission)
        XCTAssertEqual(reduced.metadataOnlyCaptures, 1)
        XCTAssertEqual(reduced.rejectedCaptures, 0)
        XCTAssertTrue(reduced.admissionPaused)
        XCTAssertEqual(reduced.capturePolicy, "playback_first")
        XCTAssertTrue(reduced.pressureFallback.contains("forwarding_does_not_wait"))
        XCTAssertFalse(reduced.resumeRestoresHistoricalBodies)
    }
    func testCapturePressurePreservesBoundsAndRecoversWithoutForcedResume() throws {
        let admission = CaptureAdmissionBudget()
        let reservation = try XCTUnwrap(admission.reserve(bytes: 128 * 1_024 * 1_024))
        XCTAssertNil(admission.reserve(bytes: 1))
        let paused = status("running", admission)
        XCTAssertEqual(paused.futureBodyCapture, "admission_paused")
        XCTAssertTrue(paused.recommendedAction.contains("do_not_restart_or_raise_limits"))
        admission.release(reservation)
        let recovered = status("running", admission)
        XCTAssertEqual(recovered.futureBodyCapture, "bounded_capture_available")
        XCTAssertEqual(recovered.rejectedCaptures, 1)
        XCTAssertFalse(recovered.resumeRestoresHistoricalBodies)
        XCTAssertEqual(recovered.reservedBytes, 0)
    }

    func testStoppedTransitionAndZeroRetentionHaveDifferentRecovery() {
        let admission = CaptureAdmissionBudget()
        XCTAssertEqual(status("stopped", admission).recommendedAction, "capture_resume_after_runtime_approval")
        XCTAssertEqual(status("starting", admission).futureBodyCapture, "runtime_transition_or_unavailable")
        let disabled = MCPCaptureStatusDTO(proxyState: "running", admission: admission.snapshot,
            perResponseByteLimit: 1_048_576, retainedBodyByteLimit: 0)
        XCTAssertEqual(disabled.futureBodyCapture, "body_retention_disabled")
        XCTAssertTrue(disabled.recommendedAction.contains("local_user"))
    }

    func testResumeCannotArmSystemRoutingAndIsDiscoveredEverywhere() {
        XCTAssertThrowsError(try MCPRuntimeControlSafetyPolicy.validateRemoteAction(.resumeCapture,
            systemProxyManagementEnabled: true))
        XCTAssertNoThrow(try MCPRuntimeControlSafetyPolicy.validateRemoteAction(.resumeCapture,
            systemProxyManagementEnabled: false))
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "capture_resume"), .runtimeControl)
        XCTAssertEqual(MCPCapabilityRouter.capability(forTool: "capture_status"), .captureResource)
        for toolset in MCPToolset.allCases {
            XCTAssertTrue(toolset.includes(toolName: "capture_status"))
            XCTAssertTrue(toolset.includes(toolName: "capture_resume"))
        }
    }

    private func status(_ state: String, _ admission: CaptureAdmissionBudget) -> MCPCaptureStatusDTO {
        MCPCaptureStatusDTO(proxyState: state, admission: admission.snapshot,
            perResponseByteLimit: 1_048_576, retainedBodyByteLimit: 250 * 1_048_576)
    }
}
