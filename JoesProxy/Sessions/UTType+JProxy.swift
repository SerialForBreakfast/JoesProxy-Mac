import UniformTypeIdentifiers

extension UTType {
    /// The UTI for `.jproxy` session recording files exported and owned by this app.
    static let jproxyRecording = UTType(exportedAs: "com.JoesProxy.jproxy")

    /// The UTI for privacy-sanitized portable reproduction packages.
    static let jproxyReproductionPackage = UTType(exportedAs: "com.JoesProxy.jproxy-repro")

    /// HAR files are JSON data but use their own conventional extension.
    static let harArchive = UTType(filenameExtension: "har", conformingTo: .json) ?? .json
}
