import Foundation

/// Tokenized OpenAPI features. AW-2 classifies documents into these tags; AW-1 owns the policy.
enum OpenAPIMockFeatureTag: String, Equatable, Sendable, Codable, CaseIterable {
    case object
    case array
    case string
    case number
    case integer
    case boolean
    case properties
    case required
    case items
    case `enum`
    case `default`
    case example
    case formatDateTime
    case formatUUID
    case formatEmail
    case oneOf
    case anyOf
    case allOf
    case not
    case discriminator
    case remoteRef
    case eventStream
    case xml
    case callbacks
    case links
    case webhooks
    case binaryGeneration
    case additionalPropertiesSchema
    case openAPI31
    case yaml
    case openAPI2
}

/// Split of tokenized features into supported vs report-and-skip.
struct OpenAPIMockSupportReport: Equatable, Sendable {
    var supported: Set<OpenAPIMockFeatureTag>
    var unsupported: Set<OpenAPIMockFeatureTag>

    /// True when every submitted tag is in the v1 subset.
    var isFullySupported: Bool { unsupported.isEmpty }
}

/// v1 schema subset. Unsupported tags are reported, never guessed into fixtures.
enum OpenAPIMockSchemaSupport {
    /// Features the compiler may turn into fixtures.
    static let supportedTags: Set<OpenAPIMockFeatureTag> = [
        .object, .array, .string, .number, .integer, .boolean,
        .properties, .required, .items, .enum, .default, .example,
        .formatDateTime, .formatUUID, .formatEmail
    ]

    /// Classifies already-tokenized tags. Does not parse OpenAPI JSON.
    static func classify(_ tags: [OpenAPIMockFeatureTag]) -> OpenAPIMockSupportReport {
        var supported = Set<OpenAPIMockFeatureTag>()
        var unsupported = Set<OpenAPIMockFeatureTag>()
        for tag in tags {
            if supportedTags.contains(tag) {
                supported.insert(tag)
            } else {
                unsupported.insert(tag)
            }
        }
        return OpenAPIMockSupportReport(supported: supported, unsupported: unsupported)
    }
}
