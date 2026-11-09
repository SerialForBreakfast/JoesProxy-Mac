import Foundation
import Network

enum NetworkConnectionIOError: LocalizedError {
    case failedToStart(String)
    case receiveFailed(String)
    case sendFailed(String)
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .failedToStart(let message):
            return message
        case .receiveFailed(let message):
            return message
        case .sendFailed(let message):
            return message
        case .connectionClosed:
            return "The network connection closed before the operation completed."
        }
    }
}

enum NetworkConnectionIO {
    private static let defaultBufferSize = 64 * 1024

    static func start(_ connection: NWConnection, on queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let state = ConnectionStartState()

            connection.stateUpdateHandler = { newState in
                guard !state.didResume else {
                    return
                }

                switch newState {
                case .ready:
                    state.didResume = true
                    continuation.resume()
                case .failed(let error):
                    state.didResume = true
                    continuation.resume(
                        throwing: NetworkConnectionIOError.failedToStart(error.localizedDescription)
                    )
                case .cancelled:
                    state.didResume = true
                    continuation.resume(throwing: NetworkConnectionIOError.connectionClosed)
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    static func receive(on connection: NWConnection, maximumLength: Int = defaultBufferSize) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: NetworkConnectionIOError.receiveFailed(error.localizedDescription))
                    return
                }

                guard let data else {
                    continuation.resume(throwing: NetworkConnectionIOError.connectionClosed)
                    return
                }

                continuation.resume(returning: (data, isComplete))
            }
        }
    }

    static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: NetworkConnectionIOError.sendFailed(error.localizedDescription))
                    return
                }

                continuation.resume()
            })
        }
    }

    static func receiveAll(on connection: NWConnection) async throws -> Data {
        var buffer = Data()

        while true {
            do {
                let (chunk, isComplete) = try await receive(on: connection)
                buffer.append(chunk)

                if isComplete {
                    return buffer
                }
            } catch NetworkConnectionIOError.connectionClosed where !buffer.isEmpty {
                return buffer
            }
        }
    }
}

private final class ConnectionStartState {
    var didResume = false
}
