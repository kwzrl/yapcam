import Foundation
@testable import YapcamEditor

/// Runs `body` with its own preset folder and its own defaults, so parallel tests never share (or touch the
/// user's real) preset library or default-preset choice.
@MainActor func withIsolatedPresets<T>(_ body: () throws -> T) throws -> T {
    let dir = FileManager.default.temporaryDirectory.appending(path: "yapcam-presets-\(UUID().uuidString)", directoryHint: .isDirectory)
    let suiteName = "mov.yapcam.Yapcam.test-\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    defer { try? FileManager.default.removeItem(at: dir); suite.removePersistentDomain(forName: suiteName) }
    return try PresetIsolation.$directory.withValue(dir) {
        try PresetIsolation.$defaultsSuiteName.withValue(suiteName) { try body() }
    }
}
