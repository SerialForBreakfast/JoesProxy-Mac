import Combine
import Foundation

/// App-owned operations survive setup-window dismissal. Only local UI actions call recovery;
/// readiness reads never install certificates or enable routing.
@MainActor
final class AgentSetupRecoveryController: ObservableObject {
    @Published private(set) var readiness: MCPSetupReadinessState?
    @Published private(set) var isWorking = false
    @Published private(set) var failure: String?
    @Published private(set) var receipt: String?

    private let read: () async -> MCPSetupReadinessState
    private let install: () throws -> Void

    init(read: @escaping () async -> MCPSetupReadinessState, install: @escaping () throws -> Void) {
        self.read = read
        self.install = install
    }

    func refresh() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        readiness = await read()
    }

    func installCertificate() async {
        guard !isWorking else { return }
        isWorking = true
        failure = nil
        receipt = nil
        defer { isWorking = false }
        do {
            try install()
            receipt = "Certificate installation completed. Review local trust and verify traffic on the target device."
        } catch {
            failure = error.localizedDescription
        }
        readiness = await read()
    }
}
