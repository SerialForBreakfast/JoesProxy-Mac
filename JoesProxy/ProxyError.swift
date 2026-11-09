// ProxyError.swift
// JoesProxyApp
//
// Created by [Your Name] on [Date].
//
// MIT License
//
// [Include MIT License Text]

import Foundation

/// `ProxyError` defines the possible errors that can occur in the proxy server.
enum ProxyError: Error, LocalizedError, Equatable {
    case startFailed(reason: String)
    case stopFailed
    case connectionFailed
    case invalidPort
    case listenerCreationFailed

    var errorDescription: String? {
        switch self {
        case .startFailed(let reason):
            return reason
        case .stopFailed:
            return "The proxy could not be stopped."
        case .connectionFailed:
            return "The proxy connection failed."
        case .invalidPort:
            return "Enter a port between 1 and \(UInt16.max)."
        case .listenerCreationFailed:
            return "The proxy listener could not be created."
        }
    }
}
