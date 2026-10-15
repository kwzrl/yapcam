import Foundation
import YapcamEditor

/// Where the app keeps its preferences. Normal launches use the app's own defaults; every self-test /
/// QA launch flag uses a throw-away suite so scripted runs can never change the user's settings
/// (an earlier self-test left `openEditor=0` behind, so the editor did not open after a real recording).
enum AppDefaults {
    nonisolated(unsafe) static var store: UserDefaults = .standard

    static let selfTestSuiteName = "mov.yapcam.Yapcam.selftest"

    /// Every launch flag that drives the app without a person at the controls.
    static let selfTestFlags: Set<String> = [
        "--capture-selftest", "--ui-record-selftest", "--drive-input-selftest",
        "--editor-selftest", "--editor-reopen-check", "--editor-export-selftest",
        "--live-e2e", "--snapshot-ui", "--probe-record",
    ]

    static func isSelfTestLaunch(_ args: [String]) -> Bool { args.contains { selfTestFlags.contains($0) } }

    /// Call once, first thing at launch, before any setting is read.
    static func isolateIfSelfTest(_ args: [String]) {
        guard isSelfTestLaunch(args) else { return }
        UserDefaults().removePersistentDomain(forName: selfTestSuiteName)   // start from defaults every time
        if let suite = UserDefaults(suiteName: selfTestSuiteName) { store = suite; EditorPresets.globalDefaults = suite }
        // Presets made by self-tests live in a scratch folder, never in the user's preset library.
        let scratch = FileManager.default.temporaryDirectory.appending(path: "yapcam-selftest-presets-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
        EditorPresets.globalDirectory = scratch
    }
}
