import Foundation

/// Validates untrusted generated edits before existing authoring can prepare a revision.
/// Call off UI/network execution paths. This type neither retains bodies nor creates effects.
enum SimilarItemProposalValidator {
    enum Failure: String, Error {
        case invalidContract, outputTooLarge, unauthorizedEdit
    }

    static func validate(source: Data, template: CollectionMockDraft,
                         allowedTextPointers: Set<String>, generated: [CollectionMockEdit]) throws
        -> CollectionMockDraft {
        try Task.checkCancellation()
        guard template.item == nil, template.templateIndex != nil, template.expansionItems == nil,
              !allowedTextPointers.isEmpty, allowedTextPointers.count <= 16,
              generated.count <= 16 else { throw Failure.invalidContract }
        let protected = template.identityPointers + template.edits.map(\.pointer)
        for pointer in allowedTextPointers {
            let components = try CollectionMockCompiler.pointer(pointer)
            guard !components.isEmpty else { throw Failure.invalidContract }
            for reserved in protected {
                let reservedComponents = try CollectionMockCompiler.pointer(reserved)
                guard !components.starts(with: reservedComponents),
                      !reservedComponents.starts(with: components) else { throw Failure.invalidContract }
            }
        }
        var seen = Set<String>()
        var bytes = 0
        for edit in generated {
            guard allowedTextPointers.contains(edit.pointer), seen.insert(edit.pointer).inserted,
                  case .string(let text) = edit.value else { throw Failure.unauthorizedEdit }
            bytes += edit.pointer.utf8.count + text.utf8.count
            guard bytes <= 8 * 1_024 else { throw Failure.outputTooLarge }
        }
        let draft = CollectionMockDraft(collectionPointer: template.collectionPointer,
            item: nil, templateIndex: template.templateIndex, edits: template.edits + generated,
            identityPointers: template.identityPointers, countPointers: template.countPointers,
            position: template.position, identityPresence: template.identityPresence,
            ignoredQueryNames: template.ignoredQueryNames)
        _ = try CollectionMockCompiler.prepare(source: source, draft: draft)
        return draft
    }
}
