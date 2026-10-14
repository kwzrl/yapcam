import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
import YapcamCapture
import YapcamCore
@testable import YapcamUI

@Suite struct KeyComboTests {
    @Test func defaultsDisplay() {
        #expect(KeyCombo.startStop.display == "⌥⌘R")
        #expect(KeyCombo.pauseResume.display == "⌥⌘P")
    }
    @Test func codableRoundTrip() throws {
        let c = KeyCombo(keyCode: UInt32(kVK_F5), modifiers: UInt32(controlKey | shiftKey))
        let back = try JSONDecoder().decode(KeyCombo.self, from: JSONEncoder().encode(c))
        #expect(back == c)
        #expect(c.display == "⌃⇧F5")
    }
}

@MainActor @Suite struct EngineMappingTests {
    @Test func captureErrorsMapToUIErrors() {
        if case .diskFull(let b) = LiveEngine.map(CaptureError.diskFull(availableBytes: 42)) { #expect(b == 42) }
        else { Issue.record("diskFull not mapped") }
        if case .permissionDenied(let p) = LiveEngine.map(CaptureError.permissionDenied(.screen)) { #expect(p == "screen") }
        else { Issue.record("permissionDenied not mapped") }
        if case .failed = LiveEngine.map(CaptureError.sourceUnavailable) {} else { Issue.record("sourceUnavailable not mapped") }
    }
    @Test func unavailableEngineFailsLoudly() async {
        let s = UnavailableEngine().makeSession(UIRecordingOptions(
            target: .display(1), systemAudio: true, microphoneID: nil, cameraID: nil,
            recordKeystrokes: false, maxFPS: 60, outputDirectory: URL(filePath: "/tmp")))
        await #expect(throws: EngineError.self) { try await s.start() }
    }
}

@MainActor @Suite struct PermissionTests {
    @Test func onlyScreenIsRequired() {
        #expect(AppPermission.allCases.filter(\.isRequired) == [.screen])
        for p in AppPermission.allCases { #expect(p.settingsURL.scheme == "x-apple.systempreferences") }
    }
}

@MainActor @Suite struct ProjectActionTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "yapcam-ui-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func renameDuplicateAndUniqueNames() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "A.yapcam", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: a.appending(path: "recording"), withIntermediateDirectories: true)

        let copy = try ProjectActions.duplicate(a)
        #expect(copy.lastPathComponent == "A copy.yapcam")
        #expect(try ProjectActions.duplicate(a).lastPathComponent == "A copy 2.yapcam")

        let renamed = try ProjectActions.rename(a, to: " Demo/1 ")
        #expect(renamed.lastPathComponent == "Demo-1.yapcam")
        #expect(FileManager.default.fileExists(atPath: renamed.path) && !FileManager.default.fileExists(atPath: a.path))
        #expect(throws: EngineError.self) { try ProjectActions.rename(renamed, to: "A copy") }
        #expect(throws: EngineError.self) { try ProjectActions.rename(renamed, to: "   ") }
    }
}

@MainActor @Suite struct ReviewFixTests {
    // #2: concurrent imports of same-named videos get different packages.
    @Test func reservedImportDestinationsDoNotCollide() {
        let dir = URL(filePath: "/tmp/yapcam-ui-reserve-\(UUID().uuidString)", directoryHint: .isDirectory)
        let a = ProjectActions.reserveURL(in: dir, name: "Demo")
        let b = ProjectActions.reserveURL(in: dir, name: "Demo")
        #expect(a != b)
        #expect(b.lastPathComponent == "Demo 2.yapcam")
        ProjectActions.release(a); ProjectActions.release(b)
        #expect(ProjectActions.uniqueURL(in: dir, name: "Demo") == a)
    }

    // #8: the first press asks macOS (also for permissions that report .denied before asking).
    @Test func permissionButtonAsksBeforeOpeningSettings() {
        let p = AppPermission.accessibility
        UserDefaults.standard.removeObject(forKey: "permissionRequested.\(p.rawValue)")
        #expect(!PermissionsModel.shared.hasRequested(p))
    }

    // #10: the menu finds the editor document on a window controller by label.
    final class FakeController: NSWindowController { let editorDocument = "doc" }
    @Test func bridgeFindsEditorDocumentProperty() {
        #expect(EditorBridge.find(String.self, labeled: "editorDocument", in: FakeController()) == "doc")
        #expect(EditorBridge.find(String.self, labeled: "missing", in: FakeController()) == nil)
    }

    // #10: Edit menu exists with the editor commands.
    @Test func mainMenuHasEditorCommands() {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let edit = MainMenu.build(target: delegate).items.first { $0.title == "Edit" }?.submenu
        let titles = edit?.items.map(\.title) ?? []
        for t in ["Undo", "Redo", "Split at Playhead", "Add Zoom at Playhead"] { #expect(titles.contains(t)) }
        #expect(edit?.items.first { $0.title == "Undo" }?.keyEquivalent == "z")
    }
}

@MainActor @Suite struct NotesTests {
    @Test func notesPersistInProject() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "yapcam-notes-\(UUID().uuidString)", directoryHint: .isDirectory)
        let pkg = dir.appending(path: "N.yapcam", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/synthetic/basic.yapcam")
        try? FileManager.default.removeItem(at: pkg)
        try FileManager.default.copyItem(at: fixture, to: pkg)
        try ProjectActions.attachNotes("remember the intro", to: pkg)
        let json = try String(contentsOf: pkg.appending(path: "project.json"), encoding: .utf8)
        #expect(json.contains("remember the intro"))
    }
}

@MainActor @Suite struct PresetTests {
    @Test func saveListApplyRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "yapcam-preset-\(UUID().uuidString)", directoryHint: .isDirectory)
        let pkg = tmp.appending(path: "P.yapcam", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/synthetic/basic.yapcam")
        try FileManager.default.copyItem(at: fixture, to: pkg)
        let project = try Project.create(package: pkg)
        let file = tmp.appending(path: "look.yapcampreset")
        try project.exportPreset(to: file)
        #expect(FileManager.default.fileExists(atPath: file.path))
        try project.apply(.set(path: "canvas.padding", value: .number(0.2)))
        try PresetStore.apply(file, to: project)           // restores the exported look
        #expect(PresetStore.clean("  a/b ") == "a-b")
        #expect(throws: EngineError.self) { try PresetStore.save(project, as: "   ") }
    }
}

// MARK: - UI smoke test: every window renders, light and dark

@MainActor @Suite(.serialized) struct UISmokeTests {
    /// Fails if a PNG is missing, tiny, or a single flat colour (a blank render).
    static func check(_ dir: URL) -> [String] {
        var problems: [String] = []
        for name in UISnapshot.expectedNames {
            for mode in ["light", "dark"] {
                let url = dir.appending(path: "\(name)-\(mode).png")
                guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else {
                    problems.append("missing \(name)-\(mode)"); continue
                }
                if rep.pixelsWide < 20 || rep.pixelsHigh < 20 { problems.append("tiny \(name)-\(mode)"); continue }
                var seen = Set<UInt32>()
                let step = max(1, min(rep.pixelsWide, rep.pixelsHigh) / 24)
                for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
                    for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        seen.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
                    }
                }
                if seen.count < 3 { problems.append("blank \(name)-\(mode)") }
            }
        }
        return problems
    }

    @Test func everyWindowRendersInLightAndDark() async throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appending(path: "yapcam-smoke-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        await UISnapshot.render(into: dir)
        #expect(UISmokeTests.check(dir) == [])
    }

    /// The real app binary with `--snapshot-ui`, when it has been built (scripts/build-app.sh).
    nonisolated static let appBinary: URL = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "build/Yapcam.app/Contents/MacOS/Yapcam")

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: UISmokeTests.appBinary.path)))
    func appLaunchedWithSnapshotFlagRendersEverything() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "yapcam-smoke-app-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = UISmokeTests.appBinary
        p.arguments = ["--snapshot-ui", dir.path]
        try p.run()
        let deadline = Date().addingTimeInterval(60)
        while p.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        if p.isRunning { p.terminate(); Issue.record("app did not exit after --snapshot-ui") }
        #expect(UISmokeTests.check(dir) == [])
    }
}
