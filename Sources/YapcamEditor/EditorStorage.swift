import Foundation

/// Where the editor keeps look presets (a folder) and small preferences (a UserDefaults domain). The real locations are used
/// only by the real app. Anything that is not the real app — unit tests, the app's launch-flag self-tests, or a process started
/// with `YAPCAM_PRESETS_DIR` — gets an isolated folder and defaults domain, so it can never read or change the user's presets,
/// their default-preset choice or their remembered settings.
public enum EditorStorage {
    public static let realPresetsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Yapcam/Presets", directoryHint: .isDirectory)
    static let selfTestFlags = ["--editor-selftest", "--editor-reopen-check", "--editor-export-selftest", "--capture-selftest",
                                "--ui-record-selftest", "--drive-input-selftest", "--snapshot-ui"]

    /// True in unit-test processes (XCTest or Swift Testing) and in the app's self-test launches.
    public static var isIsolatedProcess: Bool {
        let env = ProcessInfo.processInfo.environment, name = ProcessInfo.processInfo.processName
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil || env["SWIFT_TESTING_ENABLED"] != nil
            || name.contains("xctest") || name.contains("swiftpm-testing-helper") || name.contains("PackageTests")
            || CommandLine.arguments.contains { selfTestFlags.contains($0) }
    }

    /// `YAPCAM_PRESETS_DIR` wins; otherwise an isolated per-process temp folder when `isIsolatedProcess`; otherwise the real folder.
    static func resolvedPresetsDirectory() -> URL {
        if let p = ProcessInfo.processInfo.environment["YAPCAM_PRESETS_DIR"], !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
        if isIsolatedProcess {
            return FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-editor-isolated-\(ProcessInfo.processInfo.processIdentifier)/Presets", isDirectory: true)
        }
        return realPresetsDirectory
    }

    /// One defaults domain per process (isolated processes get a fresh private suite).
    nonisolated(unsafe) static let sharedDefaults: UserDefaults = resolvedDefaults()

    /// The defaults domain for settings that must not leak between isolated runs and the user's real ones.
    static func resolvedDefaults() -> UserDefaults {
        let env = ProcessInfo.processInfo.environment
        if let p = env["YAPCAM_PRESETS_DIR"], !p.isEmpty, let d = UserDefaults(suiteName: "yapcam.isolated.\(abs(p.hashValue))") { return d }
        if isIsolatedProcess, let d = UserDefaults(suiteName: "yapcam.isolated.\(ProcessInfo.processInfo.processIdentifier)") {
            d.removePersistentDomain(forName: "yapcam.isolated.\(ProcessInfo.processInfo.processIdentifier)")
            return d
        }
        return .standard
    }

    /// A completely private store for one test: its own folder and defaults suite. Call `cleanup()` when done.
    @MainActor public static func makeIsolated() -> (store: PresetStore, defaults: UserDefaults, cleanup: () -> Void) {
        let id = UUID().uuidString
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-test-presets-\(id)", isDirectory: true)
        let suite = "yapcam.test.\(id)"
        let defaults = UserDefaults(suiteName: suite)!
        return (PresetStore(directory: dir, defaults: defaults), defaults, {
            try? FileManager.default.removeItem(at: dir); defaults.removePersistentDomain(forName: suite)
        })
    }
}

/// File-based look presets (one `.yapcampreset` per name; the same folder and format as the app's Presets menu).
@MainActor public final class PresetStore {
    public let directory: URL
    public let defaults: UserDefaults
    static let defaultKey = "yapcam.defaultPreset"

    public init(directory: URL, defaults: UserDefaults) { self.directory = directory; self.defaults = defaults }

    public func names() -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "yapcampreset" }.map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    public func url(_ name: String) -> URL { directory.appending(path: "\(name).yapcampreset") }
    public func clean(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-") }
    /// The preset applied to every new project (nil = none).
    public var defaultName: String? {
        get { defaults.string(forKey: Self.defaultKey) }
        set { defaults.set(newValue, forKey: Self.defaultKey) }
    }
}
