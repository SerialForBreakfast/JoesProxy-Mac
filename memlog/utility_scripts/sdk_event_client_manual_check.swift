import Foundation

struct HandshakePayload: Encodable {
    let token: String
    let deviceName: String
    let bundleID: String
    let deviceTimestamp: Date
    let sdkVersion: String
    let schemaVersion: Int
    let supportedSchemaVersions: [Int]
}

struct Envelope<Payload: Encodable>: Encodable {
    let type: String
    let version: Int
    let id: UUID
    let sentAt: Date
    let payload: Payload
}

enum ManualCheckError: Error, CustomStringConvertible {
    case invalidArguments
    case invalidURL

    var description: String {
        switch self {
        case .invalidArguments:
            return "Usage: sdk-event-client-manual-check ws://127.0.0.1:9091 <pairing-token>"
        case .invalidURL:
            return "The WebSocket URL is invalid."
        }
    }
}

@main
struct SDKEventClientManualCheck {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw ManualCheckError.invalidArguments
        }

        guard let url = URL(string: CommandLine.arguments[1]) else {
            throw ManualCheckError.invalidURL
        }

        let token = CommandLine.arguments[2]
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.dateFormatter.string(from: date))
        }

        let handshake = HandshakePayload(
            token: token,
            deviceName: Host.current().localizedName ?? "Manual Check Mac",
            bundleID: "com.JoesProxy.ManualSDKCheck",
            deviceTimestamp: Date(),
            sdkVersion: "manual-check",
            schemaVersion: 1,
            supportedSchemaVersions: [1]
        )
        let envelope = Envelope(
            type: "handshake",
            version: 1,
            id: UUID(),
            sentAt: Date(),
            payload: handshake
        )
        let data = try encoder.encode(envelope)
        let message = String(decoding: data, as: UTF8.self)

        try await task.send(.string(message))
        print("Sent handshake to \(url.absoluteString)")

        while true {
            let received = try await task.receive()
            switch received {
            case .string(let text):
                print(text)
            case .data(let data):
                print(String(decoding: data, as: UTF8.self))
            @unknown default:
                print("Received an unknown WebSocket message type.")
            }
        }
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
