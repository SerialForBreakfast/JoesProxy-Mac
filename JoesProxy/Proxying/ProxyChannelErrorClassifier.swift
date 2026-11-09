//
//  ProxyChannelErrorClassifier.swift
//  JoesProxy
//
//  Classifies noisy channel-close errors so long captures surface real failures.
//

import Foundation

enum ProxyChannelErrorClassification: Equatable, Sendable {
    case expectedDisconnect
    case unexpectedFailure
}

enum ProxyChannelErrorClassifier {
    static func classify(_ error: Error) -> ProxyChannelErrorClassification {
        classify(description: error.localizedDescription, debugDescription: String(reflecting: error))
    }

    static func classify(description: String, debugDescription: String = "") -> ProxyChannelErrorClassification {
        let combined = "\(description) \(debugDescription)".lowercased()
        let expectedFragments = [
            "niossl.niosslerror error 0",
            "niossl.niosslerror error 12",
            "niocore.ioerror error 1",
            "connection reset by peer",
            "broken pipe",
            "operation canceled",
            "operation cancelled",
            "socket is not connected"
        ]

        if expectedFragments.contains(where: combined.contains) {
            return .expectedDisconnect
        }

        return .unexpectedFailure
    }
}
