//
//  OpenAPISchemaStore.swift
//  JoesProxy
//
//  In-memory store of loaded OpenAPI schema documents with segment-aware route matching.
//

import Foundation

actor OpenAPISchemaStore {

    private(set) var documents: [OpenAPISchemaDocument] = []

    init(documents: [OpenAPISchemaDocument] = []) {
        self.documents = documents
    }

    func addDocument(_ document: OpenAPISchemaDocument) {
        documents.removeAll { $0.id == document.id }
        documents.append(document)
    }

    func removeDocument(id: UUID) {
        documents.removeAll { $0.id == id }
    }

    func clearAll() {
        documents.removeAll()
    }

    @discardableResult
    func importDocument(data: Data) throws -> OpenAPISchemaDocument {
        let doc = try OpenAPISchemaReader.parse(data: data)
        addDocument(doc)
        return doc
    }

    /// Matches an incoming request against all registered OpenAPI operations.
    /// Returns the matched document and operation, or nil if no match is found.
    func match(method: String, path: String) -> (document: OpenAPISchemaDocument, operation: OpenAPIOperationDefinition)? {
        let normalizedPath = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let upperMethod = method.uppercased()

        for doc in documents {
            for op in doc.operations where op.method == upperMethod {
                if matches(path: normalizedPath, template: op.pathTemplate) {
                    return (doc, op)
                }
            }
        }
        return nil
    }

    /// Checks if a concrete request path matches an OpenAPI path template (e.g. `/users/{id}` matches `/users/123`).
    private func matches(path: String, template: String) -> Bool {
        let pathSegments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let templateSegments = template.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        guard pathSegments.count == templateSegments.count else {
            return false
        }

        for (pSeg, tSeg) in zip(pathSegments, templateSegments) {
            if tSeg.hasPrefix("{") && tSeg.hasSuffix("}") {
                // Parameter segment — matches any single non-empty segment
                if pSeg.isEmpty { return false }
            } else {
                // Exact literal segment match
                if pSeg.caseInsensitiveCompare(tSeg) != .orderedSame {
                    return false
                }
            }
        }
        return true
    }
}
