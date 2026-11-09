import Foundation

/// Validates opaque references without opening files or echoing supplied values in errors.
enum CapturedMockImageArguments {
    static func decode(_ supplied: Any?) throws -> [CapturedMockImageFile] {
        guard let supplied else { return [] }
        guard let entries = supplied as? [[String: Any]], entries.count <= 16 else {
            throw failure("images", "invalidCount", "Supply an array of at most 16 image bindings.")
        }
        return try entries.enumerated().map { index, entry in
            let field = "images[\(index)]"
            guard Set(entry.keys).isSubset(of: ["itemPointer", "localFileBookmarkRef", "originalURL", "deliveryURL", "imageReference"]) else {
                throw failure(field, "unknownField", "Use itemPointer, localFileBookmarkRef, originalURL, deliveryURL or imageReference; remove unknown fields.")
            }
            guard let bookmark = entry["localFileBookmarkRef"] as? String, !bookmark.isEmpty else {
                throw failure("\(field).localFileBookmarkRef", "invalidReference", "Supply a nonempty opaque file bookmark for the selected image.")
            }
            let pointer = entry["itemPointer"] as? String
            guard entry["itemPointer"] == nil || pointer != nil else {
                throw failure("\(field).itemPointer", "incompatibleType", "Supply a JSON Pointer string, or omit it for artwork explicitly bound by a related response.")
            }
            var original: URL?
            if let value = entry["originalURL"] {
                guard let url = absoluteURL(value) else {
                    throw failure("\(field).originalURL", "invalidURL", "Supply an absolute HTTP(S) URL with a host.")
                }
                original = url
            }
            var delivery: URL?
            var reference: String?
            if entry["deliveryURL"] != nil || entry["imageReference"] != nil {
                guard original == nil, let url = absoluteURL(entry["deliveryURL"]),
                      let value = entry["imageReference"] as? String, !value.isEmpty else {
                    throw failure(field, "invalidDeliveryPair", "Supply deliveryURL (absolute HTTP(S)) and nonempty imageReference together, without originalURL. Example: deliveryURL=https://images.example.test/mock.png, imageReference=files/mock.png. Verify the client's path transformation separately.")
                }
                delivery = url
                reference = value
            }
            return .init(itemPointer: pointer, bookmarkRef: bookmark, originalURL: original,
                         deliveryURL: delivery, imageReference: reference)
        }
    }

    private static func absoluteURL(_ value: Any?) -> URL? {
        guard let text = value as? String, let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private static func failure(_ field: String, _ reason: String, _ recovery: String) -> CapturedMockPreparationFailure {
        .init(reason: reason, field: field, recovery: recovery)
    }
}
