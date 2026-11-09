import Foundation

enum InspectorJSONEligibility {
    /// Untyped object/array and delimited-record sniffing requires a structural opener.
    /// Reject obvious non-JSON without allocating full strings or split-record arrays.
    static func shouldProbe(_ data: Data, headers: [HTTPHeaderField]) -> Bool {
        !CapturedBodyDecoder.isKnownBinaryContentType(headers: headers)
            && (data.contains(0x7B) || data.contains(0x5B))
    }
}
