import AppKit

/// Optional "hide desktop icons while recording" (Finder `CreateDesktop`).
/// A marker file records that we changed it so a crash can never leave the desktop hidden:
/// the next launch (and every normal stop/quit) restores it.
@MainActor enum DesktopIcons {
    private static var marker: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Yapcam/desktop-icons-hidden")
    }

    static var isHiddenByUs: Bool { FileManager.default.fileExists(atPath: marker.path) }

    static func hide() {
        guard !isHiddenByUs, currentlyShown else { return }
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        set(false)
    }

    static func restoreIfNeeded() {
        guard isHiddenByUs else { return }
        set(true)
        try? FileManager.default.removeItem(at: marker)
    }

    private static var currentlyShown: Bool {
        let v = UserDefaults(suiteName: "com.apple.finder")?.object(forKey: "CreateDesktop")
        return (v as? Bool) ?? true
    }

    private static func set(_ shown: Bool) {
        run("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", "-bool", shown ? "true" : "false"])
        run("/usr/bin/killall", ["Finder"])
    }

    private static func run(_ path: String, _ args: [String]) {
        let p = Process(); p.executableURL = URL(filePath: path); p.arguments = args
        try? p.run(); p.waitUntilExit()
    }
}
