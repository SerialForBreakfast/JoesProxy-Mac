import Foundation

/// Model-independent projection contract. Full captured bodies never cross the provider boundary.
struct SimilarItemTextInput: Sendable {
    let source: Data
    let template: CollectionMockDraft
    let fields: [String: String]
    enum Failure: Error { case invalidInput, invalidOutput }

    static func inspect(response: CapturedResponse, guided: GuidedCollectionMockDraft,
                        protectedPointers: Set<String>) throws -> Self {
        guard guided.useTemplate, !guided.expandTemplate,
              !response.bodyDeferred, !response.bodyTruncated, response.recordingBodyOmissionReason == nil,
              let bytes = response.bodyData, bytes.count <= CollectionMockCompiler.maximumBodyBytes,
              let decoded = CapturedBodyDecoder.decode(bodyData: bytes, headers: response.headers,
                maxDecodedBytes: CollectionMockCompiler.maximumBodyBytes),
              decoded.canUseAnalysisDataForInspection else { throw Failure.invalidInput }
        let template = try CollectionMockDraftDecoder.decode(guided.encoded())
        let compiled = try CollectionMockCompiler.prepare(source: decoded.analysisData, draft: template)
        guard case .object(let object) = compiled.item else { throw Failure.invalidInput }
        let protected = protectedPointers.union(template.identityPointers).union(template.countPointers)
            .union(template.edits.map(\.pointer))
        var fields: [String: String] = [:]
        for (key, value) in object {
            let pointer = "/" + key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
            guard case .string(let text) = value, eligible(key: key, text: text),
                  !protected.contains(where: { $0 == pointer || $0.hasPrefix(pointer + "/") || pointer.hasPrefix($0 + "/") }) else { continue }
            fields[pointer] = text
            guard fields.count <= 128 else { throw Failure.invalidInput }
        }
        return .init(source: decoded.analysisData, template: template, fields: fields)
    }

    static func eligible(key: String, text: String) -> Bool {
        let reserved = ["id", "uuid", "url", "uri", "href", "src", "image", "artwork", "path", "link",
                        "reference", "count", "total", "token", "password", "secret", "credential", "command"]
        guard !reserved.contains(where: { key.lowercased().contains($0) }), key.utf8.count <= 128 else { return false }
        return safeText(text)
    }

    static func safeText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 512
            && !text.contains(":") && !text.contains("/") && !text.contains("\\")
            && !text.contains("@") && !text.lowercased().contains("www.")
            && text.range(of: #"\w\.\w"#, options: .regularExpression) == nil
    }

    func projection(selected: Set<String>) throws -> String {
        guard (1...8).contains(selected.count), selected.isSubset(of: Set(fields.keys)) else { throw Failure.invalidInput }
        let bytes = try JSONSerialization.data(withJSONObject: fields.filter { selected.contains($0.key) }, options: [.sortedKeys])
        guard bytes.count <= 4_096 else { throw Failure.invalidInput }
        return String(decoding: bytes, as: UTF8.self)
    }

    func validate(_ output: [String: String], selected: Set<String>) throws -> [CollectionMockEdit] {
        _ = try projection(selected: selected)
        guard Set(output.keys) == selected, output.values.allSatisfy(Self.safeText),
              try JSONSerialization.data(withJSONObject: output).count <= 4_096 else { throw Failure.invalidOutput }
        let edits = output.keys.sorted().map { CollectionMockEdit(pointer: $0, value: .string(output[$0]!)) }
        _ = try SimilarItemProposalValidator.validate(source: source, template: template,
            allowedTextPointers: selected, generated: edits)
        return edits
    }
}
