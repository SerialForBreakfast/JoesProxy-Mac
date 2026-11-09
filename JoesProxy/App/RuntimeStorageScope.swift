import Foundation

/// Explicit storage namespace for synthetic runtimes. A separate bundle identifier does not
/// isolate stores whose defaults point at the production Application Support directory.
/// This scopes persistence only; callers must still inject credentials and host-facing services.
@MainActor
struct RuntimeStorageScope {
    let root: URL
    let defaults: UserDefaults

    init(root: URL, defaults: UserDefaults) {
        precondition(root.isFileURL && root.path != "/")
        self.root = root.standardizedFileURL
        self.defaults = defaults
    }

    func file(_ name: String) -> URL {
        precondition(!name.isEmpty && !name.contains("/") && name != "..")
        return root.appendingPathComponent(name)
    }

    /// The host wrapper owns this directory. A missing/unsafe root must never select user storage.
    static func uiTest(environment: [String: String], runID: UUID = UUID()) throws -> RuntimeStorageScope {
        guard let path = environment["JOESPROXY_UI_ARTIFACT_DIRECTORY"], path.hasPrefix("/"),
              !path.split(separator: "/").contains("..") else { throw UITestStorageError.invalidRoot }
        let parent = URL(fileURLWithPath: path).standardizedFileURL
        guard parent.path.contains("/build/HostTestResults/"),
              parent.lastPathComponent.hasSuffix("-artifacts"),
              parent.resolvingSymlinksInPath().path == parent.path else { throw UITestStorageError.invalidRoot }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue,
              let defaults = UserDefaults(suiteName: "com.ShowBlender.JoesProxy.UITest.\(runID.uuidString)")
        else { throw UITestStorageError.invalidRoot }
        let root = parent.appendingPathComponent("runtime-\(runID.uuidString)", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: root.path) else { throw UITestStorageError.reusedRoot }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return RuntimeStorageScope(root: root, defaults: defaults)
    }

    enum UITestStorageError: Error { case invalidRoot, reusedRoot }
}
