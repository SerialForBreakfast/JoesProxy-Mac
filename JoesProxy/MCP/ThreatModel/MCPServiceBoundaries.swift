import Foundation

/// Documents future MCP adapter seams against existing JoesProxy services (AG-1 inventory).
///
/// Implementations arrive in AG-2 onward; this enum exists so contract tests and docs stay aligned.
enum MCPServiceBoundary: String, Equatable, Sendable, CaseIterable {
    case sessionStore
    case responseOverrideStore
    case connectionHandler
    case bookmarkStore
    case bookmarkResponseInterceptStore
    case networkThrottling
    case sensitiveDataRedaction
    case keychainCredentialStorage
    case localHTTPServerActor
}

extension MCPServiceBoundary {
    /// Human-readable mapping to existing app types for grooming and implementation planning.
    var existingSeamDescription: String {
        switch self {
        case .sessionStore:
            return "SessionStore — session list, search, summaries, capture revisions"
        case .responseOverrideStore:
            return "ResponseOverrideStore — Map Local/Remote, Block, response overrides"
        case .connectionHandler:
            return "ConnectionHandler — upstream fetch decisions per override kind"
        case .bookmarkStore:
            return "BookmarkStore — bookmark definitions and execution metadata"
        case .bookmarkResponseInterceptStore:
            return "BookmarkResponseInterceptStore — bookmark rewrite intercept state"
        case .networkThrottling:
            return "NetworkThrottling — NetworkThrottleConfiguration / NetworkThrottleWriter"
        case .sensitiveDataRedaction:
            return "SensitiveDataRedaction — header/query/body redaction helpers"
        case .keychainCredentialStorage:
            return "PersistentKeychainCertificateStore pattern — verifier storage, never plaintext"
        case .localHTTPServerActor:
            return "SDKEventServer / ProfileHostingServer — actor-owned loopback HTTP lifecycle"
        }
    }
}
