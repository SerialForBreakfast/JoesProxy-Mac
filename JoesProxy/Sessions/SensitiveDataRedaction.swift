//
//  SensitiveDataRedaction.swift
//  JoesProxy
//
//  Shared privacy heuristics for inspector copy redaction and visualization export.
//

import Foundation

/// Centralizes token/header/query redaction heuristics used by inspector copy and export flows.
enum SensitiveDataRedaction {
    static let authHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "www-authenticate"
    ]

    static let cookieHeaderNames: Set<String> = [
        "cookie",
        "set-cookie"
    ]

    static let explicitSensitiveHeaderNames: Set<String> = [
        "x-api-key",
        "x-auth-token",
        "x-csrf-token"
    ]

    /// Returns whether a header name should be treated as sensitive for copy/export redaction.
    static func isSensitiveHeaderName(_ name: String) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if authHeaderNames.contains(normalizedName) ||
            cookieHeaderNames.contains(normalizedName) ||
            explicitSensitiveHeaderNames.contains(normalizedName) {
            return true
        }
        return isSensitiveKey(normalizedName)
    }

    /// Returns whether a field/key name should be treated as token-like.
    static func isSensitiveKey(_ key: String) -> Bool {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedKey.contains("token") ||
            normalizedKey.contains("secret") ||
            normalizedKey.contains("authorization") ||
            normalizedKey.contains("auth") ||
            normalizedKey.contains("password") ||
            normalizedKey.contains("apikey") ||
            normalizedKey.contains("api-key") ||
            normalizedKey.contains("session")
    }

    /// Returns whether a field/key name should be treated as a user/account identifier.
    static func isUserIdentifierKey(_ key: String) -> Bool {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedKey.contains("userid") ||
            normalizedKey.contains("user_id") ||
            normalizedKey.contains("accountid") ||
            normalizedKey.contains("account_id") ||
            normalizedKey.contains("subscriber") ||
            normalizedKey.contains("deviceid") ||
            normalizedKey.contains("device_id")
    }

    /// Replaces query values with a placeholder while preserving parameter names.
    static func redactedQueryURLString(
        _ urlString: String,
        placeholder: String = "<redacted>"
    ) -> String {
        guard var components = URLComponents(string: urlString),
              let queryItems = components.queryItems,
              !queryItems.isEmpty else {
            return urlString
        }

        components.queryItems = queryItems.map { item in
            URLQueryItem(name: item.name, value: placeholder)
        }
        return components.string ?? urlString
    }
}
