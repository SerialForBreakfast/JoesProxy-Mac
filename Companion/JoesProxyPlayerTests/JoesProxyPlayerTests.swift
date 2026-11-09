import XCTest
@testable import JoesProxyPlayer

final class JoesProxyPlayerTests: XCTestCase {
    func testTriggerPlanRoundTripLaunchArgument() throws {
        let plan = JoePlayerTriggerPlan(actions: [
            JoePlayerTriggerAction(atPlayerTimeSeconds: 8.5, action: "selectAudio", target: "ad"),
            JoePlayerTriggerAction(atPlayerTimeSeconds: 0.1, action: "play", target: nil)
        ])
        let arg = try TriggerPlanRunner.launchArgument(for: plan)
        let decoded = TriggerPlanRunner.planFromLaunchArguments(["app", arg])
        XCTAssertEqual(decoded, plan)
    }

    func testDiagnosticEventsPathConstant() {
        XCTAssertEqual(JoePlayerDiagnosticRoute.eventsPath, "/joeplayer/v1/events")
    }

    func testPCMGlitchDetectLaunchFlagParsing() {
        XCTAssertFalse(PCMGlitchDetectorLaunch.isEnabled(arguments: ["app"]))
        XCTAssertTrue(PCMGlitchDetectorLaunch.isEnabled(arguments: ["app", "--joeplayer-pcm-glitch-detect=1"]))
        XCTAssertTrue(PCMGlitchDetectorLaunch.isEnabled(arguments: ["app", "--joeplayer-pcm-glitch-detect=true"]))
        XCTAssertEqual(
            PCMGlitchDetectorLaunch.triggerTimeSeconds(arguments: ["--joeplayer-pcm-trigger-time=8.25"]),
            Optional(8.25)
        )
    }

    func testPCMEnergyHeuristicDetectsMute() {
        let windows = stride(from: 7.0, through: 9.0, by: 0.025).map { time -> PCMEnergyWindow in
            let silent = time >= 7.9 && time <= 8.2
            return PCMEnergyWindow(playerTimeSeconds: time, rms: silent ? 0.001 : 0.2)
        }
        let result = PCMEnergyHeuristic.classify(windows: windows, triggerPlayerTimeSeconds: 8.0)
        XCTAssertEqual(result, .mute)
    }

    func testPCMEnergyHeuristicDetectsGlitch() {
        let windows: [PCMEnergyWindow] = [
            PCMEnergyWindow(playerTimeSeconds: 7.95, rms: 0.25),
            PCMEnergyWindow(playerTimeSeconds: 7.97, rms: 0.001),
            PCMEnergyWindow(playerTimeSeconds: 7.99, rms: 0.22)
        ]
        let result = PCMEnergyHeuristic.classify(windows: windows, triggerPlayerTimeSeconds: 8.0)
        XCTAssertEqual(result, .glitch)
    }

    func testPCMEnergyHeuristicOkWhenSteady() {
        let windows = (0..<20).map { index in
            PCMEnergyWindow(playerTimeSeconds: 7.5 + Double(index) * 0.05, rms: 0.18)
        }
        XCTAssertEqual(
            PCMEnergyHeuristic.classify(windows: windows, triggerPlayerTimeSeconds: 8.0),
            .ok
        )
    }

    func testPCMRMSFromFloatSamples() {
        let samples: [Float] = [0.5, -0.5, 0.5, -0.5]
        let value = PCMEnergyHeuristic.rms(float32Samples: samples, channelCount: 1)
        XCTAssertEqual(value, 0.5, accuracy: 0.0001)
    }

    func testPCMDiagnosticKindMapping() {
        XCTAssertEqual(PCMGlitchDetector.diagnosticKind(for: .ok), "pcmOk")
        XCTAssertEqual(PCMGlitchDetector.diagnosticKind(for: .mute), "pcmMute")
        XCTAssertEqual(PCMGlitchDetector.diagnosticKind(for: .glitch), "pcmGlitch")
    }

    func testSampleBufferOutputStillUnavailableOnCurrentSDKSpike() {
        XCTAssertFalse(
            PCMGlitchDetector.sampleBufferOutputVisibleToSwiftSDK,
            "Flip only after a successful Swift compile reference to AVPlayerItemSampleBufferOutput"
        )
    }

    func testTriggerPlanEncodesLanguageSwitchTarget() throws {
        let plan = JoePlayerTriggerPlan(actions: [
            JoePlayerTriggerAction(atPlayerTimeSeconds: 8.0, action: "selectAudio", target: "es")
        ])
        let arg = try TriggerPlanRunner.launchArgument(for: plan)
        let decoded = TriggerPlanRunner.planFromLaunchArguments(["app", arg])
        XCTAssertEqual(decoded?.actions.first?.target, "es")
    }
}
