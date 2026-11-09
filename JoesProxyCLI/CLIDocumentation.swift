import Foundation

extension DocumentationCatalog.Page {
    var markdown: String {
        var lines = ["Source: \(source) · App: \(appVersion) · Catalog: \(catalogRevision)", "Digest: \(catalogDigest)", "", notice]
        for entry in entries {
            lines += ["", "# \(entry.topic.title) (`\(entry.topic.id)`)", entry.topic.summary]
            if let section = entry.matchedSectionID { lines.append("Matching section: \(section)") }
            if let excerpt = entry.excerpt { lines.append(excerpt) }
            for section in entry.safetyContext + entry.sections {
                lines += ["", "## \(section.title) (`\(section.id)`)", "", section.markdown]
            }
        }
        if entries.isEmpty { lines += ["", "No matching documentation. Try a broader term or list topics."] }
        if let nextCursor { lines += ["", "More content available. Continue with --cursor \(nextCursor)"] }
        return lines.joined(separator: "\n")
    }
}
