import Foundation

/// Migrates recordings made by older Yapcam builds that changed Finder's
/// `CreateDesktop` preference. New recordings use a ScreenCaptureKit filter and
/// never create this marker or restart Finder.
@MainActor enum DesktopIcons {
    private static var marker: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Yapcam/desktop-icons-hidden")
    }

    static func restoreIfNeeded() {
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        set(true)
        try? FileManager.default.removeItem(at: marker)
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
