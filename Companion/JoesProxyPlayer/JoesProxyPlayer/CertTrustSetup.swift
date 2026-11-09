//
//  CertTrustSetup.swift
//  JoesProxyPlayer
//
/// Thin UIKit bridge that launches JoesProxySDK's iOS certificate setup assistant from SwiftUI.
///

import JoesProxySDK
import SwiftUI
import UIKit

/// Presents `IOSSetupAssistantPresenter` from the key window's root view controller.
enum CertTrustSetup {
    /// Default profile download URL from JoesProxy's profile hosting server (default port 8765).
    nonisolated static let defaultProfileURL = URL(string: "http://127.0.0.1:8765/profile.mobileconfig")

    /// Starts the setup assistant with the given proxy endpoint.
    ///
    /// Must be called on the main actor. Returns `false` when no presenting view controller is available
    /// or when the profile URL cannot be opened immediately.
    @MainActor
    @discardableResult
    static func present(
        proxyHost: String = "127.0.0.1",
        proxyPort: Int = 9090,
        profileURL: URL? = CertTrustSetup.defaultProfileURL
    ) -> Bool {
        let configuration = SetupAssistantConfiguration(
            proxyHost: proxyHost,
            proxyPort: proxyPort,
            profileURL: profileURL
        )
        let assistant = SetupAssistant(configuration: configuration)
        let presenter = IOSSetupAssistantPresenter(assistant: assistant)
        guard let host = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController else {
            return false
        }
        return presenter.start(in: topMost(from: host))
    }

    private static func topMost(from controller: UIViewController) -> UIViewController {
        if let presented = controller.presentedViewController {
            return topMost(from: presented)
        }
        return controller
    }
}
