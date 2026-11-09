import Foundation

/// Immutable reviewed restrictions. Absence on historical definitions retains legacy matching.
struct HLSRequestPolicy: Codable, Equatable, Sendable {
    let clientAddress: String
    /// A deliberate fault returns a local 404 for this track only, never an upstream fallback.
    let missingTextTrackID: String?

    func validate(scope: HLSSubstitutionScope) throws {
        guard !clientAddress.isEmpty, clientAddress.utf8.count <= 256,
              clientAddress == clientAddress.trimmingCharacters(in: .whitespacesAndNewlines),
              !clientAddress.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              case .selectedPlaylist(let path) = scope,
              path.utf8.count <= 8192,
              CapturedQueryMatcher.exactCanonicalPath(path) != nil else {
            throw HLSSubstitutionError.invalidRequestPolicy
        }
        if let id = missingTextTrackID {
            guard !id.isEmpty, id.utf8.count <= 64,
                  id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
                throw HLSSubstitutionError.invalidRequestPolicy
            }
        }
    }

    func permits(_ request: CapturedRequest) -> Bool {
        request.clientAddress?.trimmingCharacters(in: .whitespacesAndNewlines) == clientAddress
    }

    static func failsTextRequest(_ fixturePath: String, trackID: String) -> Bool {
        let path = String(fixturePath.split(separator: "?", maxSplits: 1).first ?? "")
        let components = path.split(separator: "/")
        let trackIndex: Int
        if components.first == "text" { trackIndex = 1 }
        else if components.count > 3, components[0] == "__jp_media", components[2] == "text" {
            trackIndex = 3
        } else { return false }
        return components.count > trackIndex + 1 && components[trackIndex] == trackID
    }

    static func entryMatches(_ path: String, scope: HLSSubstitutionScope, policy: Self?) -> Bool {
        let pathOnly = String(path.split(separator: "?", maxSplits: 1).first ?? "")
        switch scope {
        case .host: return policy == nil && pathOnly.lowercased().hasSuffix(".m3u8")
        case .selectedPlaylist(let selected):
            if policy == nil { return pathOnly == String(selected.split(separator: "?", maxSplits: 1).first ?? "") }
            guard let expected = CapturedQueryMatcher.exactCanonicalPath(selected),
                  let actual = CapturedQueryMatcher.exactCanonicalPath(path) else { return false }
            return expected == actual
        }
    }

    var summary: String {
        "Client: \(clientAddress); exact canonical entry query; child sequence queries retained."
            + (missingTextTrackID.map { " Deliberate missing-text fault: \($0)." } ?? "")
    }

    static let legacySummary = "Legacy HLS scope: all routed clients; entry query ignored. JSON client restrictions do not apply."

    static func disclosure(_ policy: Self?) -> [String: Any] {
        ["mode": policy == nil ? "legacyAllClients" : "explicitClient",
         "clientAddress": policy?.clientAddress as Any? ?? NSNull(),
         "entryQueryPolicy": policy == nil ? "ignored" : "exactCanonical",
         "missingTextTrackID": policy?.missingTextTrackID as Any? ?? NSNull(),
         "clientIdentityIsAuthentication": false]
    }
}
