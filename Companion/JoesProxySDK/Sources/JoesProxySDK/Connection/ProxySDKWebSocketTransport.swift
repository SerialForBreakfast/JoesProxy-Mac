import Foundation

protocol ProxySDKWebSocketTransport: Sendable {
    func connect(to url: URL) async throws
    func sendText(_ text: String) async throws
    func receiveText() async throws -> String
    func close() async
}

struct URLSessionProxySDKWebSocketTransport: ProxySDKWebSocketTransport {
    private let storage = URLSessionProxySDKWebSocketStorage()

    func connect(to url: URL) async throws {
        let task = URLSession.shared.webSocketTask(with: url)
        await storage.setTask(task)
        task.resume()
    }

    func sendText(_ text: String) async throws {
        guard let task = await storage.task else {
            throw ProxySDKError.protocolError("WebSocket is not connected.")
        }
        try await task.send(.string(text))
    }

    func receiveText() async throws -> String {
        guard let task = await storage.task else {
            throw ProxySDKError.protocolError("WebSocket is not connected.")
        }
        let message = try await task.receive()
        switch message {
        case .string(let text):
            return text
        case .data:
            throw ProxySDKError.protocolError("Expected a text WebSocket message.")
        @unknown default:
            throw ProxySDKError.protocolError("Received an unknown WebSocket message.")
        }
    }

    func close() async {
        await storage.close()
    }
}

private actor URLSessionProxySDKWebSocketStorage {
    private(set) var task: URLSessionWebSocketTask?

    func setTask(_ task: URLSessionWebSocketTask) {
        self.task = task
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}
