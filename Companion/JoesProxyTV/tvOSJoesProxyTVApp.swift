import SwiftUI

@main
struct TVOSJoesProxyTVApp: App {
    @StateObject private var presentationState = TVOSSetupPresentationState(
        sdkFacade: TVOSLiveProxySDKClient()
    )

    var body: some Scene {
        WindowGroup {
            TVOSSetupRootView()
                .environmentObject(presentationState)
        }
    }
}
