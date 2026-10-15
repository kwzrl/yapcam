import AppKit
import SwiftUI
import Carbon.HIToolbox
import Foundation
import Testing
import YapcamCapture
import YapcamCore
import YapcamEditor
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
        // YAPCAM_SNAPSHOT_KEEP=<dir> keeps the images (renders in this test process, no app launch).
        let keep = ProcessInfo.processInfo.environment["YAPCAM_SNAPSHOT_KEEP"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        let dir = keep ?? FileManager.default.temporaryDirectory.appending(path: "yapcam-smoke-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { if keep == nil { try? FileManager.default.removeItem(at: dir) } }
        await UISnapshot.render(into: dir)
        #expect(UISmokeTests.check(dir) == [])
    }

    /// The real app binary with `--snapshot-ui`, when it has been built (scripts/build-app.sh).
    nonisolated static let appBinary: URL = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "build/Yapcam.app/Contents/MacOS/Yapcam")

    /// Skipped while QA owns the app (~/Movies/Yapcam/QA/.app-lock): never start a second Yapcam then.
    nonisolated static let qaOwnsApp = FileManager.default.fileExists(
        atPath: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Yapcam/QA/.app-lock").path)
        || !NSRunningApplication.runningApplications(withBundleIdentifier: "mov.yapcam.Yapcam").isEmpty   // any instance running

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: UISmokeTests.appBinary.path) && !UISmokeTests.qaOwnsApp))
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

@MainActor @Suite(.serialized) struct ReviewRound2Tests {
    private func temp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "yapcam-r2-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func fixturePackage(in dir: URL, name: String) throws -> URL {
        let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/synthetic/basic.yapcam")
        let pkg = dir.appending(path: "\(name).yapcam", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: fixture, to: pkg)
        return pkg
    }

    // prior #2: Demo and demo are the same destination on a case-insensitive volume.
    @Test func reservationIsCaseInsensitive() {
        let dir = URL(filePath: "/tmp/yapcam-case-\(UUID().uuidString)", directoryHint: .isDirectory)
        let a = ProjectActions.reserveURL(in: dir, name: "Demo")
        let b = ProjectActions.reserveURL(in: dir, name: "demo")
        defer { ProjectActions.release(a); ProjectActions.release(b) }
        #expect(a.lastPathComponent == "Demo.yapcam")
        #expect(b.lastPathComponent != "demo.yapcam")
        ProjectActions.release(a)
        #expect(ProjectActions.uniqueURL(in: dir, name: "DEMO").lastPathComponent == "DEMO.yapcam")
    }

    // new #2: adding a preset that already is the library copy must not delete it.
    @Test func addingLibraryPresetToItselfKeepsIt() throws {
        let lib = try temp(); defer { try? FileManager.default.removeItem(at: lib) }
        PresetStore.directoryOverride = lib; defer { PresetStore.directoryOverride = nil }
        let file = lib.appending(path: "Look.yapcampreset")
        try Data("one".utf8).write(to: file)
        try PresetStore.addToLibrary(file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "one")

        let outside = try temp(); defer { try? FileManager.default.removeItem(at: outside) }
        let other = outside.appending(path: "Look.yapcampreset")
        try Data("two".utf8).write(to: other)
        try PresetStore.addToLibrary(other)                     // replaces by copy, original untouched
        #expect(try String(contentsOf: file, encoding: .utf8) == "two")
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(PresetStore.names() == ["Look"])                 // no leftover temp files
    }

    @Test func failedAddKeepsExistingPreset() throws {
        let lib = try temp(); defer { try? FileManager.default.removeItem(at: lib) }
        PresetStore.directoryOverride = lib; defer { PresetStore.directoryOverride = nil }
        let file = lib.appending(path: "Look.yapcampreset")
        try Data("keep".utf8).write(to: file)
        #expect(throws: (any Error).self) { try PresetStore.addToLibrary(URL(filePath: "/nonexistent/Look.yapcampreset")) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
    }

    // new #4: applying a preset refreshes the editor model and persists.
    @Test func applyingPresetUpdatesEditorAndSaves() throws {
        let dir = try temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = try fixturePackage(in: dir, name: "T")
        let source = try fixturePackage(in: dir, name: "S")
        let sp = try Project.create(package: source)
        try sp.apply(.set(path: "canvas.padding", value: .number(0.31)))
        let preset = dir.appending(path: "p.yapcampreset")
        try sp.exportPreset(to: preset)

        let doc = try EditorDocument(package: target, restoreUnsavedChanges: false)
        #expect(abs(doc.model.number("canvas.padding") - 0.31) > 0.001)
        try PresetStore.apply(preset, to: doc)
        #expect(abs(doc.model.number("canvas.padding") - 0.31) < 0.001)      // inspector source of truth refreshed
        let saved = try Project.open(package: target)
        let json = try String(data: saved.toJSON(), encoding: .utf8) ?? ""
        #expect(json.contains("0.31"))                                       // persisted without another edit
    }

    // new #5: production transcriber is installed (never a fake).
    @Test func transcriberIsInstalled() {
        EditorWindows.transcriber = nil
        _ = NSApplication.shared
        AppDelegate().installTranscriber()
        #expect(EditorWindows.transcriber != nil)
    }
}

// MARK: - Multi-display and scale geometry (simulated displays)

@Suite struct GeometryTests {
    // AppKit global coordinates, bottom-left origin; the main display is at (0, 0).
    static let main1x = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1680, height: 1050),
                                   visibleFrame: CGRect(x: 0, y: 0, width: 1680, height: 1050 - 25), scale: 1)
    static let left2x = ScreenInfo(id: 2, frame: CGRect(x: -1440, y: 0, width: 1440, height: 900),
                                   visibleFrame: CGRect(x: -1440, y: 0, width: 1440, height: 875), scale: 2)
    static let right1x = ScreenInfo(id: 3, frame: CGRect(x: 1680, y: 0, width: 1920, height: 1080),
                                    visibleFrame: CGRect(x: 1680, y: 0, width: 1920, height: 1055), scale: 1)
    static let above2x = ScreenInfo(id: 4, frame: CGRect(x: 0, y: 1050, width: 1512, height: 982),
                                    visibleFrame: CGRect(x: 0, y: 1050, width: 1512, height: 957), scale: 2)
    static let size = CGSize(width: 66, height: 300)

    @Test func defaultPlacementIsRightEdgeCenteredOnEveryArrangement() {
        for s in [Self.main1x, Self.left2x, Self.right1x, Self.above2x] {
            let o = ToolbarGeometry.origin(size: Self.size, on: s, saved: nil)
            #expect(o.x == s.visibleFrame.maxX - Self.size.width - ToolbarGeometry.defaultInset)
            #expect(abs(o.y + Self.size.height / 2 - s.visibleFrame.midY) < 0.001)
            #expect(s.visibleFrame.contains(CGRect(origin: o, size: Self.size)))
        }
    }

    @Test func savedFractionRoundTripsOnDisplaysWithNegativeAndOffsetOrigins() {
        for s in [Self.left2x, Self.above2x, Self.right1x] {
            let frame = CGRect(x: s.frame.minX + 200, y: s.frame.minY + 400, width: Self.size.width, height: Self.size.height)
            let f = ToolbarGeometry.fraction(frame: frame, on: s)
            let back = ToolbarGeometry.origin(size: Self.size, on: s, saved: f)
            #expect(abs(back.x - frame.minX) < 0.001 && abs(back.y - frame.minY) < 0.001)
        }
    }

    @Test func savedSpotIsClampedWhenDisplayGotSmaller() {
        // Saved at the far top-right of a big display, restored on a small one.
        let o = ToolbarGeometry.origin(size: Self.size, on: Self.left2x, saved: .init(x: 0.999, y: 0.999))
        #expect(Self.left2x.visibleFrame.contains(CGRect(origin: o, size: Self.size)))
    }

    @Test func clampKeepsToolbarOutOfMenuBarAndOffscreen() {
        let off = CGRect(x: 5000, y: 5000, width: 66, height: 300)
        let c = ToolbarGeometry.clamp(off, to: Self.main1x.visibleFrame)
        #expect(Self.main1x.visibleFrame.contains(c))
        let tiny = CGRect(x: 0, y: 0, width: 66, height: 300)
        let small = ToolbarGeometry.clamp(tiny, to: CGRect(x: 0, y: 0, width: 40, height: 200))
        #expect(small.minX == 0 && small.maxY == 200)               // pinned, never straddles
    }

    @Test func removingTheDisplayMovesToolbarToLastUsedThenMain() {
        let onRight = CGRect(x: 2000, y: 300, width: 66, height: 300)       // on right1x
        let remaining = [Self.main1x, Self.left2x]
        // Last used display (left) still connected → go there.
        let a = ToolbarGeometry.relocate(frame: onRight, screens: remaining, lastID: 2, mainID: 1, saved: { _ in nil })
        #expect(a != nil && Self.left2x.visibleFrame.contains(a!))
        // Last used display is the removed one → main display.
        let b = ToolbarGeometry.relocate(frame: onRight, screens: remaining, lastID: 3, mainID: 1, saved: { _ in nil })
        #expect(b != nil && Self.main1x.visibleFrame.contains(b!))
        // A saved position on the fallback display is honoured.
        let c = ToolbarGeometry.relocate(frame: onRight, screens: remaining, lastID: 3, mainID: 1,
                                         saved: { $0 == 1 ? .init(x: 0.1, y: 0.9) : nil })
        #expect(c != nil && abs(c!.minX - 168) < 1)
        // No displays at all: nothing to do.
        #expect(ToolbarGeometry.relocate(frame: onRight, screens: [], lastID: nil, mainID: nil, saved: { _ in nil }) == nil)
    }

    @Test func resolutionChangeKeepsToolbarOnItsDisplayAndClamps() {
        let shrunk = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
                                visibleFrame: CGRect(x: 0, y: 0, width: 1280, height: 775))
        let f = CGRect(x: 1600, y: 100, width: 66, height: 300)             // was valid at 1680 wide
        // Center (1633) is now outside the display → relocated into it.
        let r = ToolbarGeometry.relocate(frame: f, screens: [shrunk], lastID: 1, mainID: 1, saved: { _ in nil })
        #expect(r != nil && shrunk.visibleFrame.contains(r!))
    }

    @Test func popoverSideFollowsTheHalfOfTheCurrentDisplay() {
        // Same x, different displays: left half of `right1x` but right half of `main1x`.
        let frame = CGRect(x: 1700, y: 100, width: 66, height: 300)
        #expect(ToolbarGeometry.onLeftHalf(frame: frame, of: Self.right1x))
        #expect(!ToolbarGeometry.onLeftHalf(frame: frame, of: ScreenInfo(id: 9, frame: CGRect(x: 1000, y: 0, width: 800, height: 600), visibleFrame: .zero)))
    }

    // Area overlay ---------------------------------------------------------------------------

    @Test func areaConvertsBetweenDisplayLocalAndGlobalOnAnyArrangement() {
        let local = CGRect(x: 100, y: 50, width: 400, height: 300)           // top-left origin
        for s in [Self.main1x, Self.left2x, Self.right1x, Self.above2x] {
            let g = AreaGeometry.globalRect(fromLocal: local, screenFrame: s.frame)
            #expect(s.frame.contains(g))
            #expect(g.maxY == s.frame.maxY - 50)                              // 50 pt below the top edge
            #expect(AreaGeometry.localRect(fromGlobal: g, screenFrame: s.frame) == local)
        }
    }

    @Test func areaPixelSizeFollowsScale() {
        let r = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(AreaGeometry.pixelSize(of: r, scale: 1) == CGSize(width: 800, height: 600))
        #expect(AreaGeometry.pixelSize(of: r, scale: 2) == CGSize(width: 1600, height: 1200))
        #expect(AreaGeometry.pixelSize(of: CGRect(x: 0, y: 0, width: 333.5, height: 10), scale: 2) == CGSize(width: 667, height: 20))
    }

    @Test func savedAreaIsClippedOrRejectedWhenDisplayChanges() {
        let area = CGRect(x: 1000, y: 700, width: 600, height: 300)
        // Display still big enough: unchanged.
        #expect(AreaGeometry.fit(area, in: CGSize(width: 1680, height: 1050)) == area)
        // Display shrank: clipped to what is left.
        #expect(AreaGeometry.fit(area, in: CGSize(width: 1280, height: 800)) == CGRect(x: 1000, y: 700, width: 280, height: 100))
        // Almost nothing left, or fully outside: rejected.
        #expect(AreaGeometry.fit(area, in: CGSize(width: 1010, height: 800)) == nil)
        #expect(AreaGeometry.fit(area, in: CGSize(width: 800, height: 600)) == nil)
    }
}

// MARK: - User-facing error messages

@MainActor @Suite struct UserMessageTests {
    private func looksRaw(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.contains("error domain=") || l.contains("os error") || l.contains("nserror")
            || s.range(of: #"^[-\d\s.:]+$"#, options: .regularExpression) != nil || s.isEmpty
    }

    @Test func screenPermissionErrorExplainsWhatToDo() {
        let sc = NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3801,
                         userInfo: [NSLocalizedDescriptionKey: "Benutzer:in hat TCCs abgelehnt"])
        let m = UserMessage.describe(sc)
        #expect(m.contains("Screen & System Audio Recording") && m.contains("System Settings"))
        #expect(!m.contains("-3801") && !m.contains("TCC"))
        if case .permissionDenied(let p) = LiveEngine.map(sc) { #expect(p == "screen") } else { Issue.record("not mapped to permission") }
        #expect(AppAlert(title: "t", error: sc).permission == .screen)
    }

    @Test func everyEngineErrorGivesAnActionableSentence() {
        let all: [EngineError] = [.unavailable("Speech recognition is not set up on this Mac"), .permissionDenied("microphone"), .permissionDenied("camera"),
                                  .diskFull(availableBytes: 5_000_000), .failed("Choose a window to record first.")]
        for e in all {
            let m = UserMessage.describe(e)
            #expect(!looksRaw(m) && m.count > 12, "\(e)")
            #expect(".!?".contains(m.last!))
        }
        #expect(UserMessage.describe(EngineError.diskFull(availableBytes: 5_000_000)).contains("Settings → Storage"))
        #expect(AppAlert(title: "t", error: EngineError.permissionDenied("camera")).permission == .camera)
    }

    @Test func captureErrorsAreTranslated() {
        for e: Error in [CaptureError.sourceUnavailable, .deviceLost("USB Mic"), .writerFailed("disk full (os error 28)"), .diskFull(availableBytes: 1)] {
            let m = UserMessage.describe(LiveEngine.map(e))
            #expect(!looksRaw(m), "\(m)")
        }
        #expect(UserMessage.describe(LiveEngine.map(CaptureError.deviceLost("USB Mic"))).contains("USB Mic"))
    }

    @Test func technicalDumpsAreNeverShown() {
        let dump = NSError(domain: "Foo", code: 7, userInfo: [NSLocalizedDescriptionKey: "Error Domain=Foo Code=7 \"x\""])
        #expect(UserMessage.describe(dump).contains("Export Diagnostics"))
        let core = CoreError.status(4, "No such file or directory (os error 2)")
        let m = UserMessage.describe(core)
        #expect(!m.contains("os error") && m.contains("No such file"))
        #expect(UserMessage.describe(CoreError.status(9, "")).contains("Export Diagnostics"))
        #expect(UserMessage.describe(CoreError.missingMedia(["a", "b"])).contains("Locate"))
    }
}

// MARK: - Accessibility

@MainActor @Suite(.serialized) struct AccessibilityTests {
    // The SwiftUI accessibility tree is only built for a real accessibility client (VoiceOver),
    // so labels can't be asserted headlessly; see docs/status/ui.md for the manual check list.

    @Test func contrastAndTransparencyHelpers() {
        #expect(ContrastOpacity(increased: true).activeFill > ContrastOpacity(increased: false).activeFill)
        #expect(ContrastOpacity(increased: true).outline > ContrastOpacity(increased: false).outline)
        #expect(ContrastOpacity(increased: true).hoverFill > ContrastOpacity(increased: false).hoverFill)
    }

    @Test func spokenTimes() {
        #expect(Announcer.timeDescription(0) == "0 seconds")
        #expect(Announcer.timeDescription(61) == "1 minute 1 second")
        #expect(Announcer.timeDescription(3725) == "1 hour 2 minutes 5 seconds")
    }

    @Test func movingToolbarByKeyboardActionStaysOnScreen() {
        // The VoiceOver "Move toolbar" actions funnel through ToolbarGeometry.clamp.
        let vis = GeometryTests.main1x.visibleFrame
        var f = CGRect(x: vis.maxX - 70, y: 400, width: 66, height: 300)
        for _ in 0..<10 { f = ToolbarGeometry.clamp(f.offsetBy(dx: 60, dy: 0), to: vis) }
        #expect(vis.contains(f))
    }
}

// MARK: - Launch-flag self-tests (QA hooks)

@MainActor @Suite struct SelfTestArgumentTests {
    private func parse(_ a: [String]) -> (SelfTests.CaptureArgs?, String?) {
        var e: String?
        let r = SelfTests.parseCapture(["Yapcam"] + a, error: &e)
        return (r, e)
    }

    @Test func plainSecondsAndDefaults() {
        #expect(parse(["--capture-selftest", "6"]).0 == .init(seconds: 6, target: nil, pauseAfter: nil))
        #expect(parse(["--capture-selftest"]).0?.seconds == 5)
    }

    @Test func windowAndAreaTargets() {
        #expect(parse(["--capture-selftest", "3", "--target", "window:1234"]).0?.target == .window(1234))
        #expect(parse(["--capture-selftest", "3", "--target", "area:10,20,800,600"]).0?.target == .area(CGRect(x: 10, y: 20, width: 800, height: 600)))
    }

    @Test func pauseAfter() {
        #expect(parse(["--capture-selftest", "6", "--pause-after", "2"]).0?.pauseAfter == 2)
        #expect(parse(["--capture-selftest", "6", "--pause-after", "9"]).1?.contains("shorter") == true)
    }

    @Test func badArgumentsExplainThemselves() {
        for bad in [["--capture-selftest", "0"], ["--capture-selftest", "5000"],                     ["--capture-selftest", "3", "--target", "area:1,2,3"], ["--capture-selftest", "3", "--target", "area:0,0,8,8"],
                    ["--capture-selftest", "3", "--target", "screen"], ["--capture-selftest", "3", "--target"]] {
            let (r, e) = parse(bad)
            #expect(r == nil && !(e ?? "").isEmpty, "\(bad)")
        }
    }

    @Test func inputScriptIsDeterministicInBoundsAndHasClicks() {
        let display = CGRect(x: 0, y: 0, width: 1680, height: 1050)
        let a = SelfTests.inputScript(display: display, duration: 10)
        #expect(a == SelfTests.inputScript(display: display, duration: 10))
        #expect(a.allSatisfy { display.contains(CGPoint(x: $0.x, y: $0.y)) })
        #expect(a.contains { $0.kind == .click } && a.contains { $0.kind == .move })
        #expect(a.map(\.at) == a.map(\.at).sorted())
        #expect(a.allSatisfy { $0.at < 10 })
        #expect(SelfTests.inputScript(display: display, duration: 0.5).isEmpty)
    }

    @Test func hostClockIsMonotonic() {
        let a = SelfTests.hostNs(), b = SelfTests.hostNs()
        #expect(b >= a && a > 0)
    }
}

@MainActor @Suite struct SelfTestOptionTests {
    private func parse(_ a: [String]) -> (SelfTests.CaptureArgs?, String?) {
        var e: String?
        let r = SelfTests.parseCapture(["Yapcam"] + a, error: &e)
        return (r, e)
    }

    @Test func displayAndWindowTitleTargets() {
        #expect(parse(["--capture-selftest", "3", "--target", "display"]).0?.target == .display)
        #expect(parse(["--capture-selftest", "3", "--target", "window:Terminal"]).0?.target == .windowTitle("Terminal"))
        #expect(parse(["--capture-selftest", "3", "--target", "window:77"]).0?.target == .window(77))
        #expect(parse(["--capture-selftest", "3", "--target", "window:"]).1 != nil)
    }

    @Test func noAudioOutAndScriptOptions() {
        let r = parse(["--capture-selftest", "4", "--no-audio", "--out", "/tmp/qa-out", "--drive-input", "/tmp/s.json"]).0
        #expect(r?.noAudio == true && r?.outputDirectory == "/tmp/qa-out" && r?.driveInputScript == "/tmp/s.json")
        #expect(parse(["--capture-selftest", "4"]).0?.noAudio == false)
        #expect(parse(["--capture-selftest", "4", "--out"]).1 != nil)
        #expect(parse(["--capture-selftest", "4", "--drive-input", "--no-audio"]).1 != nil)
    }

    @Test func scriptFileLoadsSortsAndValidates() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "yapcam-script-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appending(path: "good.json")
        try Data(#"[{"kind":"click","x":10,"y":20,"at":2},{"kind":"move","x":5,"y":6,"at":0.5}]"#.utf8).write(to: good)
        let s = try SelfTests.loadScript(good.path)
        #expect(s.map(\.kind) == [.move, .click] && s[1].x == 10)
        let bad = dir.appending(path: "bad.json")
        try Data(#"[{"kind":"drag","x":1,"y":1,"at":0}]"#.utf8).write(to: bad)
        #expect(throws: EngineError.self) { try SelfTests.loadScript(bad.path) }
        try Data("not json".utf8).write(to: bad)
        #expect(throws: (any Error).self) { try SelfTests.loadScript(bad.path) }
    }
}

@MainActor @Suite struct EditorSelfTestTests {
    @Test func argumentParsing() {
        let a = ["Yapcam", "--editor-selftest", "/p/x.yapcam", "--crash-after-autosave"]
        #expect(EditorSelfTests.argument(after: "--editor-selftest", in: a) == "/p/x.yapcam")
        #expect(EditorSelfTests.argument(after: "--editor-selftest", in: a, offset: 2) == nil)      // next is a flag
        let e = ["Yapcam", "--editor-export-selftest", "/p/x.yapcam", "/tmp/o.mp4"]
        #expect(EditorSelfTests.argument(after: "--editor-export-selftest", in: e, offset: 2) == "/tmp/o.mp4")
        #expect(EditorSelfTests.argument(after: "--editor-reopen-check", in: e) == nil)
    }

    @Test func expectationRoundTrips() throws {
        let x = EditorSelfTests.Expectation(package: "/p", clips: 2, zooms: 1, durationNs: 3_000_000_000, padding: 0.23, crashMode: "now")
        #expect(try JSONDecoder().decode(EditorSelfTests.Expectation.self, from: JSONEncoder().encode(x)) == x)
    }

    /// The same edit sequence the flag runs, on a model over a synthetic package, then the reopen comparison.
    @Test func scriptedEditsSurviveSaveAndReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "yapcam-edsel-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/synthetic/basic.yapcam")
        let pkg = dir.appending(path: "E.yapcam", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: fixture, to: pkg)

        let doc = try EditorDocument(package: pkg, restoreUnsavedChanges: false)
        let m = doc.model
        let dur = m.durationNs
        #expect(dur > 2_000_000_000)
        m.seek(toNs: dur / 3); m.splitAtPlayhead()
        let clipsAfterSplit = m.clips.count
        #expect(clipsAfterSplit >= 2)
        if let second = m.clipStarts().dropFirst().first { m.selection = .clip(second.clip.id); m.deleteSelection() }
        m.seek(toNs: m.durationNs / 5); m.addZoomAtPlayhead()
        m.set("canvas.padding", number: 72)
        m.undo(); m.redo()
        #expect(abs(m.number("canvas.padding") - 72) < 1e-9)
        let want = (m.clips.count, m.zooms.count, m.durationNs)
        m.saveNow()

        let again = try EditorDocument(package: pkg, restoreUnsavedChanges: true)
        #expect((again.model.clips.count, again.model.zooms.count, again.model.durationNs) == want)
        #expect(abs(again.model.number("canvas.padding") - 72) < 1e-9)
    }
}

@MainActor @Suite struct DeviceModeTests {
    @Test func deviceModeExistsAndIsNeverFaked() {
        #expect(SourceMode.allCases.contains(.device))
        #expect(SourceMode.device.title == "Device" && SourceMode.device.symbol == "iphone")
        #expect(IOSDevices.connected().isEmpty)          // no capture backend yet: never a made-up device
        #expect(!IOSDevices.isSupported)
    }

    @Test func recordingADeviceExplainsInsteadOfFailingSilently() {
        let s = AppSettings.shared
        let saved = s.sourceMode; defer { s.sourceMode = saved }
        s.sourceMode = .device
        do { _ = try RecordingController.shared.makeOptions(); Issue.record("device mode must not produce recording options") }
        catch { #expect(UserMessage.describe(error).contains("iPhone or iPad")) }
    }
}

@MainActor @Suite(.serialized) struct SelfTestIsolationTests {
    @Test func everyDrivingFlagIsDetected() {
        for f in AppDefaults.selfTestFlags { #expect(AppDefaults.isSelfTestLaunch(["Yapcam", f, "x"]), "\(f)") }
        #expect(!AppDefaults.isSelfTestLaunch(["Yapcam"]))
        #expect(!AppDefaults.isSelfTestLaunch(["Yapcam", "-NSDocumentRevisionsDebugMode", "YES"]))
        // every flag the app actually handles must be on the list
        for f in ["--capture-selftest", "--ui-record-selftest", "--drive-input-selftest", "--editor-selftest",
                  "--editor-reopen-check", "--editor-export-selftest", "--live-e2e", "--snapshot-ui", "--probe-record"] {
            #expect(AppDefaults.selfTestFlags.contains(f))
        }
    }

    @Test func selfTestLaunchesWriteToAnIsolatedSuiteNeverTheUsersDefaults() {
        let original = AppDefaults.store; defer { AppDefaults.store = original }
        let key = "isolationProbe-\(UUID().uuidString)"
        AppDefaults.isolateIfSelfTest(["Yapcam", "--editor-selftest", "/p"])
        #expect(AppDefaults.store !== UserDefaults.standard)
        AppDefaults.store.set(true, forKey: key)
        #expect(UserDefaults.standard.object(forKey: key) == nil)
        AppDefaults.store.removeObject(forKey: key)
        // a normal launch leaves the store alone
        AppDefaults.store = original
        AppDefaults.isolateIfSelfTest(["Yapcam"])
        #expect(AppDefaults.store === original)
    }

    @Test func freshSettingsOpenTheEditorAfterRecording() {
        let suite = UserDefaults(suiteName: "mov.yapcam.Yapcam.test-\(UUID().uuidString)")!
        let s = AppSettings(store: suite)
        #expect(s.openEditorAfterRecording == true)
        #expect(s.countdown == 3)
        s.openEditorAfterRecording = false          // persisted only into this suite
        #expect(AppSettings(store: suite).openEditorAfterRecording == false)
    }
}
