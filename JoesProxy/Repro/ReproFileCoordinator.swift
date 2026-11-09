import AppKit
import UniformTypeIdentifiers

@MainActor
final class ReproFileCoordinator {
    func promptForSaveURL(defaultName: String = "JoesProxy-Reproduction") -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jproxyReproductionPackage]
        panel.nameFieldStringValue = defaultName + ".jproxy-repro"
        panel.title = "Save Reproduction Package"
        panel.prompt = "Save"
        panel.message = "Bodies, credentials, query values, private addresses, and local paths are removed before export."
        return panel.runModal() == .OK ? panel.url : nil
    }

    func promptForOpenReproURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jproxyReproductionPackage]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Open Reproduction Package"
        panel.prompt = "Open"
        return panel.runModal() == .OK ? panel.url : nil
    }

    func promptForHARURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.harArchive]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import HAR as Reproduction Package"
        panel.prompt = "Import"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

