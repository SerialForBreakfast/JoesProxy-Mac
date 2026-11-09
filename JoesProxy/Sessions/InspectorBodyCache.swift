import Foundation

extension SessionStoreChange {
    /// Identity-only invalidation: never compare or hash bodies during view evaluation.
    func affectsInspection(of id: SessionRecord.ID) -> Bool {
        switch self {
        case .appended(let record, let dropped):
            return record.id == id || dropped.contains(id)
        case .updated(let record, _):
            return record.id == id
        case .updatedBatch(let records, _), .bodiesStripped(let records):
            return records.contains { $0.id == id }
        case .removed(let ids):
            return ids.contains(id)
        case .cleared, .loaded:
            return true
        }
    }
}

/// Main-actor presentation cache. The owner must clear it when inspection disappears.
/// Store revisions invalidate same-ID replacements without scanning bytes on each render.
@MainActor
struct InspectorBodyCache {
    private(set) var sessionID: SessionRecord.ID?
    private var revision: UInt64?
    private(set) var requestSource: JSONContentSource?
    private(set) var responseSource: JSONContentSource?
    private(set) var responseDecode: CapturedBodyDecodeResult?

    mutating func clear() {
        self = Self()
    }

    mutating func update(session: SessionRecord?, revision: UInt64) {
        guard let session else { clear(); return }
        guard session.id != sessionID || self.revision != revision else { return }
        sessionID = session.id
        self.revision = revision
        requestSource = Self.jsonSource(data: session.request.bodyData, headers: session.request.headers)
        responseDecode = session.response.flatMap { CapturedBodyDecoder.decode(response: $0) }
        responseSource = responseDecode.flatMap { decoded in
            guard decoded.canUseAnalysisDataForInspection else { return nil }
            return Self.jsonSource(data: decoded.analysisData, headers: session.response?.headers ?? [])
        }
    }

    private static func jsonSource(data: Data?, headers: [HTTPHeaderField]) -> JSONContentSource? {
        guard let data, !data.isEmpty else { return nil }
        let mime = headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?
            .value.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
        let declaredJSON = mime == "application/json" || mime?.hasSuffix("+json") == true
        guard declaredJSON || (InspectorJSONEligibility.shouldProbe(data, headers: headers)
            && JSONTreeParser.canParseJSONObject(from: data)) else { return nil }
        return try? JSONContentSource.makeLoaded(from: data)
    }
}
