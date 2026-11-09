import Foundation

/// CLI-local file access only. Shared preparation still validates image bytes and request scopes.
enum CLIImageBindings {
    static func prepare(_ text: String) throws -> [[String: Any]] {
        guard text.utf8.count <= 65_536,
              let entries = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]],
              entries.count <= 16 else {
            throw CLIError.invalidArguments("--images requires a JSON array of at most 16 bindings (64 KiB maximum).")
        }
        var pointers = Set<String>()
        return try entries.map { entry in
            guard Set(entry.keys).isSubset(of: ["itemPointer", "file", "localFileBookmarkRef", "originalURL", "deliveryURL", "imageReference"]),
                  (entry["file"] != nil) != (entry["localFileBookmarkRef"] != nil),
                  entry.values.allSatisfy({ $0 is String }) else {
                throw CLIError.invalidArguments("Each image needs exactly one file or localFileBookmarkRef. Supply itemPointer for primary artwork; omit for related-only artwork. Example: [{\"itemPointer\":\"/poster\",\"file\":\"/absolute/path/poster.png\"}].")
            }
            if let pointer = entry["itemPointer"] as? String {
                guard pointer.hasPrefix("/"), pointers.insert(pointer).inserted else {
                    throw CLIError.invalidArguments("Primary image itemPointer values must be unique JSON Pointers.")
                }
            }
            guard (entry["deliveryURL"] == nil) == (entry["imageReference"] == nil),
                  entry["originalURL"] == nil || entry["deliveryURL"] == nil else {
                throw CLIError.invalidArguments("Pair deliveryURL with imageReference, or use originalURL; do not combine them.")
            }
            var binding = entry
            if let file = entry["file"] as? String {
                guard !file.isEmpty else { throw CLIError.invalidArguments("Image file must not be empty.") }
                let url = URL(fileURLWithPath: file)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw CLIError.invalidArguments("Each image file must be a regular, non-symlink file.")
                }
                binding["localFileBookmarkRef"] = try url.bookmarkData(options: [],
                    includingResourceValuesForKeys: nil, relativeTo: nil).base64EncodedString()
                binding.removeValue(forKey: "file")
            } else if let reference = entry["localFileBookmarkRef"] as? String {
                guard let bytes = Data(base64Encoded: reference), !bytes.isEmpty else {
                    throw CLIError.invalidArguments("localFileBookmarkRef must be a nonempty base64 bookmark reference, not image bytes or a path.")
                }
            }
            return binding
        }
    }
}
