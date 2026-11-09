import Foundation
import XCTest
@testable import JoesProxy

final class AgentPrototypeTargetTests: XCTestCase {
    private let prototypeTargetID = "C40000032F00000100844D6D"

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private var project: String {
        get throws {
            try String(
                contentsOf: repositoryRoot.appendingPathComponent("JoesProxy.xcodeproj/project.pbxproj"),
                encoding: .utf8
            )
        }
    }

    func testAgentPrototypeHasNonShippingIdentityAndExplicitCompanionCLI() throws {
        let project = try project
        let target = try XCTUnwrap(project.nativeTargetBlock(id: prototypeTargetID))

        XCTAssertTrue(target.contains("productType = \"com.apple.product-type.application\";"))
        XCTAssertTrue(target.contains("C40000132F00000100844D6D /* Embed CLI */"))
        XCTAssertTrue(target.contains("C40000142F00000100844D6D /* PBXTargetDependency */"))
        XCTAssertTrue(project.contains("target = C11000182F00000100844D6D /* joesproxyctl */;"))
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER = com.ShowBlender.JoesProxy.AgentPrototype;"))
        for configurationID in ["C40000082F00000100844D6D", "C40000092F00000100844D6D"] {
            let configuration = try XCTUnwrap(project.buildConfigurationBlock(id: configurationID))
            XCTAssertTrue(configuration.contains("SKIP_INSTALL = YES;"))
            XCTAssertTrue(configuration.contains("LD_GENERATE_MAP_FILE = YES;"))
        }
        let profiling = try XCTUnwrap(project.buildConfigurationBlock(id: "C40000092F00000100844D6D"))
        XCTAssertTrue(profiling.contains("CODE_SIGNING_ALLOWED = YES;"))
        XCTAssertTrue(profiling.contains("ENABLE_HARDENED_RUNTIME = YES;"))
        XCTAssertTrue(profiling.contains("CODE_SIGN_ENTITLEMENTS = JoesProxy/JoesProxy.entitlements;"))

        let releaseLane = try String(contentsOf: repositoryRoot.appendingPathComponent("fastlane/Fastfile"), encoding: .utf8)
        XCTAssertFalse(releaseLane.contains("JoesProxyAgentPrototype"))
    }

    func testAgentPrototypeExcludesInspectorRoutesButPreservesSharedDocumentation() throws {
        let project = try project
        let exclusions = try XCTUnwrap(project.exceptionSetBlock(id: "C40000022F00000100844D6D"))
        for path in [
            "App/InspectorWorkspaceHost.swift",
            "App/ProxyViewModel.swift",
            "ContentView.swift",
            "SessionDetailView.swift",
            "MediaInfo/MediaInfoWindowView.swift",
            "Configuration/CaptionPlayerUITestView.swift",
            "Workspaces/CaptureWorkspaceViewModel.swift",
            "HelpHubView.swift"
        ] {
            XCTAssertTrue(exclusions.contains(path), "Expected Candidate C exclusion for \(path)")
        }
        XCTAssertFalse(exclusions.contains("Resources/Documentation/"))
        let target = try XCTUnwrap(project.nativeTargetBlock(id: prototypeTargetID))
        XCTAssertFalse(target.contains("JoesProxyAgentPrototypeResources"), "Do not shadow the governed catalog")
    }

    func testAgentPrototypeUsesCompleteSharedAgentDocumentation() throws {
        let directory = repositoryRoot.appendingPathComponent("JoesProxy/Resources/Documentation")
        let catalog = try DocumentationCatalog(directory: directory)

        XCTAssertTrue(catalog.index.topics.contains { $0.id == "mediaInfo" })
        XCTAssertTrue(catalog.index.topics.contains { $0.id == "agent-documentation" })
        XCTAssertNoThrow(try catalog.execute(
            .init(operation: "read", topic: "agent-documentation", section: "offline"),
            source: "installed",
            appVersion: "test"
        ))
    }
}

private extension String {
    func nativeTargetBlock(id: String) -> String? {
        block(startingWith: "\n\t\t\(id) /* JoesProxyAgentPrototype */ = {\n\t\t\tisa = PBXNativeTarget;")
    }

    func exceptionSetBlock(id: String) -> String? {
        block(startingWith: "\n\t\t\(id) /* Exceptions for \"JoesProxy\" folder in \"JoesProxyAgentPrototype\" target */ = {")
    }

    func buildConfigurationBlock(id: String) -> String? {
        block(startingWith: "\n\t\t\(id) /*")
    }

    private func block(startingWith marker: String) -> String? {
        guard let targetStart = range(of: marker)?.lowerBound,
              let blockStart = self[targetStart...].range(of: "= {")?.upperBound,
              let blockEnd = self[blockStart...].range(of: "\n\t\t};")?.lowerBound else {
            return nil
        }
        return String(self[targetStart..<blockEnd])
    }
}
