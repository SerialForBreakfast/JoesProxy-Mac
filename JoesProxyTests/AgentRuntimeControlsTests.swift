import Combine
import XCTest
@testable import JoesProxy

@MainActor
final class AgentRuntimeControlsTests: XCTestCase {
    func testControlsExposeRuntimeStateWithoutInspectorFacade() async {
        let runtime = UITestProxyRuntime(initialState: .stopped, configuredPort: 9090)
        let controls = AgentRuntimeControls(proxyRuntime: runtime)

        XCTAssertTrue(controls.canStart)
        XCTAssertFalse(controls.canStop)
        let started = expectation(description: "Agent controls receive running state")
        let stopped = expectation(description: "Agent controls receive stopped state")
        var cancellables: Set<AnyCancellable> = []
        controls.$proxyState
            .dropFirst()
            .sink { state in
                switch state {
                case .running:
                    started.fulfill()
                case .stopped:
                    stopped.fulfill()
                case .starting, .stopping, .failed:
                    break
                }
            }
            .store(in: &cancellables)

        controls.start()
        await fulfillment(of: [started], timeout: 1)

        XCTAssertTrue(controls.isRunning)
        XCTAssertFalse(controls.canStart)
        XCTAssertTrue(controls.canStop)
        controls.stop()
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertFalse(controls.isRunning)
    }
}
