import XCTest
@testable import JoesProxy

@MainActor
final class AgentEffectsMonitorTests: XCTestCase {
    func testSnapshotAndDisableUseCanonicalMutationOwnersWithoutInspectorModel() async throws {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = UserDefaultsAppConfiguration(userDefaults: defaults)
        let responseOverrides = ResponseOverrideStore()
        let rule = ResponseOverrideRule(
            requestMethod: "GET",
            requestScheme: .https,
            host: "example.test",
            port: 443,
            path: "/fixture",
            sourceKind: .inlineText,
            sourceDescription: "synthetic test rule",
            statusCode: 200,
            headers: [],
            bodySource: .inline(Data("fixture".utf8))
        )
        try await responseOverrides.addRule(rule)

        let hlsCoordinator = HLSSubstitutionCoordinator(
            runStore: HLSFixtureRunStore(),
            routeStore: HLSSubstitutionRouteStore(),
            responseOverrideStore: responseOverrides
        )
        let openAPICoordinator = OpenAPIMockPackCoordinator(
            routeStore: OpenAPIMockRouteStore(),
            responseOverrideStore: responseOverrides
        )
        let monitor = AgentEffectsMonitor(
            configuration: configuration,
            responseOverrideStore: responseOverrides,
            bookmarkStore: InMemoryBookmarkStore(),
            hlsSubstitutionCoordinator: hlsCoordinator,
            openAPIMockPackCoordinator: openAPICoordinator,
            systemProxyController: SystemProxyController()
        )

        await monitor.refresh()
        XCTAssertEqual(monitor.snapshot.activeMapLocalCount, 1)

        try await monitor.disableAll(in: "mapLocal")

        XCTAssertEqual(monitor.snapshot.activeMapLocalCount, 0)
        let remainingRules = await responseOverrides.rules()
        XCTAssertFalse(remainingRules.contains(where: \.isEnabled))
        XCTAssertNotNil(configuration.responseOverridesData)
    }
}
