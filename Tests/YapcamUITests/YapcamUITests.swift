import AVFoundation
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
        #expect(HotkeyAction.startStop.defaultCombo?.display == "⌃⌘↩")
        #expect(HotkeyAction.pauseResume.defaultCombo?.display == "⌥⌘P")
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

@MainActor @Suite struct CaseOnlyRenameTests {
    @Test func caseOnlyRenameSucceeds() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "case-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "demo.yapcam", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: a.appending(path: "recording"), withIntermediateDirectories: true)
        let r = try ProjectActions.rename(a, to: "Demo")
        #expect(r.lastPathComponent == "Demo.yapcam")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["Demo.yapcam"])
        #expect(FileManager.default.fileExists(atPath: r.appending(path: "recording").path))
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
        try withIsolatedPresets {
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
        try PresetIsolation.$directory.withValue(lib) {
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
    }

    @Test func failedAddKeepsExistingPreset() throws {
        let lib = try temp(); defer { try? FileManager.default.removeItem(at: lib) }
        try PresetIsolation.$directory.withValue(lib) {
            let file = lib.appending(path: "Look.yapcampreset")
            try Data("keep".utf8).write(to: file)
            #expect(throws: (any Error).self) { try PresetStore.addToLibrary(URL(filePath: "/nonexistent/Look.yapcampreset")) }
            #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
        }
    }

    // new #4: applying a preset refreshes the editor model and persists.
    @Test func applyingPresetUpdatesEditorAndSaves() throws {
        try withIsolatedPresets {
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
        try withIsolatedPresets {
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
}

@MainActor @Suite struct DeviceModeTests {
    @Test func deviceModeExists() {
        #expect(SourceMode.allCases == [.display, .window, .area, .device])
        #expect(SourceMode.device.title == "Device" && SourceMode.device.symbol == "iphone")
    }

    /// Without a USB device capture reports none, and recording explains what to do. Never a fake device.
    @Test func recordingWithoutADeviceExplainsWhatToDo() throws {
        guard ((try? DeviceScreensModel.currentDevices()) ?? []).isEmpty else { return }   // a real phone is attached: nothing to assert
        let s = AppSettings.shared
        let saved = s.sourceMode; defer { s.sourceMode = saved }
        s.sourceMode = .device
        do { _ = try RecordingController.shared.makeOptions(); Issue.record("must not produce options without a device") }
        catch {
            let m = UserMessage.describe(error)
            #expect(m.contains("iPhone or iPad") && m.contains("USB") && m.contains("Trust"))
        }
    }

    @Test func deviceTargetIsPartOfTheUITargetContract() throws {
        let t = UITarget.device("abc")
        #expect(try JSONDecoder().decode(UITarget.self, from: JSONEncoder().encode(t)) == t)
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
        #expect(s.countdown == 0)      // None by default (reference)
        s.openEditorAfterRecording = false          // persisted only into this suite
        #expect(AppSettings(store: suite).openEditorAfterRecording == false)
    }
}

// MARK: - Recording flow: source overlays

@MainActor @Suite struct RecordingFlowTests {
    @Test func toolbarOffersDisplayWindowAreaOnly() {
        #expect(SourceMode.toolbarModes == [.display, .window, .area])
        #expect(!SourceMode.toolbarModes.contains(.device))
    }

    @Test func aSavedDeviceModeFallsBackToDisplay() {
        let suite = UserDefaults(suiteName: "mov.yapcam.Yapcam.test-\(UUID().uuidString)")!
        suite.set("device", forKey: "sourceMode")
        #expect(AppSettings(store: suite).sourceMode == .display)
        suite.set("window", forKey: "sourceMode")
        #expect(AppSettings(store: suite).sourceMode == .window)
    }

    @Test func cgPointAndRectConversionAcrossArrangements() {
        // primary 1680×1050 at the origin; a second display above it and one to the left.
        let primaryMaxY: CGFloat = 1050
        let above = CGRect(x: 0, y: 1050, width: 1512, height: 982)        // AppKit frame
        let left = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        // The mouse at AppKit (100, 1000) is 50 pt below the top of the primary display.
        #expect(OverlayGeometry.cgPoint(fromAppKit: CGPoint(x: 100, y: 1000), primaryMaxY: primaryMaxY) == CGPoint(x: 100, y: 50))
        // A window on the primary at CG (200,100,400×300) is the same rect locally.
        let main = CGRect(x: 0, y: 0, width: 1680, height: 1050)
        #expect(OverlayGeometry.localRect(cg: CGRect(x: 200, y: 100, width: 400, height: 300), screenFrame: main, primaryMaxY: primaryMaxY)
                == CGRect(x: 200, y: 100, width: 400, height: 300))
        // On the display above, CG y is negative; 20 pt below that display top edge is y = -982+20.
        let local = OverlayGeometry.localRect(cg: CGRect(x: 10, y: -982 + 20, width: 300, height: 200), screenFrame: above, primaryMaxY: primaryMaxY)
        #expect(local == CGRect(x: 10, y: 20, width: 300, height: 200))
        // On the display to the left: x is negative in both systems.
        let l = OverlayGeometry.localRect(cg: CGRect(x: -1400, y: 50, width: 300, height: 200), screenFrame: left, primaryMaxY: primaryMaxY)
        #expect(l == CGRect(x: 40, y: 50 - (1050 - 900), width: 300, height: 200))
    }

    @Test func windowUnderCursorIsTheTopmostRecordableOne() {
        func row(_ id: UInt32, pid: Int32 = 10, layer: Int = 0, _ r: CGRect) -> WindowRow { WindowRow(id: id, pid: pid, layer: layer, app: "A", title: "t", bounds: r) }
        let rows = [
            row(1, layer: 25, CGRect(x: 0, y: 0, width: 1680, height: 30)),       // menu bar: layer ≠ 0
            row(2, pid: 99, CGRect(x: 100, y: 100, width: 500, height: 400)),     // ours (overlay): excluded
            row(3, CGRect(x: 150, y: 150, width: 300, height: 200)),              // front window
            row(4, CGRect(x: 100, y: 100, width: 800, height: 600)),              // behind
            row(5, CGRect(x: 0, y: 0, width: 40, height: 40)),                    // too small
        ]
        #expect(WindowHit.pick(from: rows, at: CGPoint(x: 200, y: 200), excludingPID: 99)?.id == 3)
        #expect(WindowHit.pick(from: rows, at: CGPoint(x: 700, y: 650), excludingPID: 99)?.id == 4)
        #expect(WindowHit.pick(from: rows, at: CGPoint(x: 10, y: 10), excludingPID: 99) == nil)
        #expect(WindowHit.pick(from: rows, at: CGPoint(x: 1600, y: 1000), excludingPID: 99) == nil)
    }

    @Test func startCardSitsNextToTheAreaSelection() {
        let bounds = CGRect(x: 0, y: 0, width: 1680, height: 1050)
        let size = CGSize(width: 520, height: 52)
        // Room below: bar under the selection, centered on it.
        let a = CGRect(x: 200, y: 150, width: 800, height: 500)
        let f1 = AreaOverlayBarLayout.frame(size: size, selection: a, in: bounds)
        #expect(f1.minY >= a.maxY && abs(f1.midX - a.midX) < 0.5)
        // Selection reaches the bottom: bar goes above it.
        let b = CGRect(x: 200, y: 500, width: 800, height: 540)
        let f2 = AreaOverlayBarLayout.frame(size: size, selection: b, in: bounds)
        #expect(f2.maxY <= b.minY)
        // Selection at the far right: bar stays on screen.
        let c = CGRect(x: 1500, y: 100, width: 170, height: 100)
        let f3 = AreaOverlayBarLayout.frame(size: size, selection: c, in: bounds)
        #expect(f3.maxX <= bounds.maxX - 8 && f3.minX >= 8)
        // Whole display selected: still inside the bounds.
        let f4 = AreaOverlayBarLayout.frame(size: size, selection: bounds, in: bounds)
        #expect(bounds.contains(f4))
    }
}

// MARK: - Reference-aligned shortcuts, countdown, recording widget, after-recording action

@MainActor @Suite struct ReferenceFlowTests {
    private func settings() -> AppSettings { AppSettings(store: UserDefaults(suiteName: "mov.yapcam.Yapcam.test-\(UUID().uuidString)")!) }

    @Test func defaultShortcutsFollowTheReferenceLayout() {
        // Physical keys (ANSI codes) and modifiers; the printed character depends on the keyboard layout.
        let cmdOpt = UInt32(cmdKey | optionKey)
        let want: [HotkeyAction: (Int, UInt32)] = [
            .startStop: (kVK_Return, UInt32(cmdKey | controlKey)), .recordDisplay: (kVK_ANSI_3, cmdOpt), .recordWindow: (kVK_ANSI_4, cmdOpt),
            .recordArea: (kVK_ANSI_5, cmdOpt), .pauseResume: (kVK_ANSI_P, cmdOpt), .restart: (kVK_Delete, cmdOpt),
            .marker: (kVK_ANSI_F, cmdOpt | UInt32(controlKey)), .toggleWidget: (kVK_ANSI_Quote, cmdOpt), .prompterPlay: (kVK_ANSI_Period, cmdOpt),
            .toggleNotes: (kVK_ANSI_Slash, cmdOpt), .quickExportCopy: (kVK_ANSI_C, cmdOpt), .quickExportSave: (kVK_ANSI_S, cmdOpt),
            .openLast: (kVK_ANSI_Z, cmdOpt),
        ]
        for (a, d) in want { #expect(a.defaultCombo == KeyCombo(keyCode: UInt32(d.0), modifiers: d.1), "\(a)") }
        #expect(HotkeyAction.startStop.defaultCombo?.display == "⌃⌘↩")
        #expect(HotkeyAction.restart.defaultCombo?.display == "⌥⌘⌫")
        #expect(HotkeyAction.cancel.defaultCombo == nil)
        #expect(Set(HotkeyAction.allCases.compactMap(\.defaultCombo)).count == HotkeyAction.allCases.compactMap(\.defaultCombo).count)   // no clashes
    }

    @Test func rebindingStoresOnlyChangesAndResets() {
        let s = settings()
        #expect(s.combo(for: .pauseResume) == HotkeyAction.pauseResume.defaultCombo)
        let mine = KeyCombo(keyCode: 0x23, modifiers: 0x100)
        s.setCombo(mine, for: .pauseResume)
        #expect(s.combo(for: .pauseResume) == mine && s.shortcuts.count == 1)
        s.setCombo(HotkeyAction.pauseResume.defaultCombo, for: .pauseResume)
        #expect(s.shortcuts.isEmpty)                                   // back to the default stores nothing
        s.setCombo(nil, for: .marker)
        #expect(s.combo(for: .marker) == nil)                          // cleared
        s.resetShortcuts()
        #expect(s.combo(for: .marker) == HotkeyAction.marker.defaultCombo)
    }

    @Test func clashesAreFlagged() {
        let s = settings()
        s.setCombo(HotkeyAction.recordDisplay.defaultCombo, for: .recordWindow)
        let c = HotkeyManager.conflicts(in: s)
        #expect(c == [.recordWindow])
    }

    @Test func menuKeyEquivalents() {
        #expect(HotkeyAction.openLast.defaultCombo?.menuKey?.key.count == 1)       // the layout's character for that key
        #expect(HotkeyAction.openLast.defaultCombo?.menuKey?.flags == [.command, .option])
        #expect(HotkeyAction.startStop.defaultCombo?.menuKey?.key == "\r")
        #expect(KeyCombo.none.menuKey == nil)
    }

    @Test func countdownOptionsAndDefault() {
        let suite = UserDefaults(suiteName: "mov.yapcam.Yapcam.test-\(UUID().uuidString)")!
        #expect(AppSettings(store: suite).countdown == 0)              // None by default
        for n in [0, 3, 5, 10] { suite.set(n, forKey: "countdown"); #expect(AppSettings(store: suite).countdown == n) }
        suite.set(7, forKey: "countdown"); #expect(AppSettings(store: suite).countdown == 0)
    }

    @Test func afterRecordingDefaultsAndLabels() {
        let s = settings()
        #expect(s.afterRecording == .createProject && s.createAutoZooms && s.showQuickExportWidget && s.showRecordingWidget)
        #expect(AfterRecording.createProject.recordLabel == "Start recording")
        #expect(AfterRecording.exportCopy.recordLabel == "Record & Copy" && AfterRecording.exportSave.recordLabel == "Record & Save")
        s.afterRecording = .exportSave
        #expect(AppSettings(store: s.debugStore).afterRecording == .exportSave)
    }

    @Test func markersAreWrittenNextToTheRecording() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "yapcam-markers-\(UUID().uuidString)", directoryHint: .isDirectory)
        let pkg = dir.appending(path: "M.yapcam", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pkg.appending(path: "recording"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        PostRecording.writeMarkers([1_500_000_000, 4_000_000_000], to: pkg)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: pkg.appending(path: "recording/markers.json"))) as? [String: [Int64]]
        #expect(obj?["markers_ns"] == [1_500_000_000, 4_000_000_000])
        // no recording folder → nothing is created
        PostRecording.writeMarkers([1], to: dir.appending(path: "none.yapcam"))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "none.yapcam").path))
    }

    @Test func markerOnlyWhileRecordingAndNotWhenIdle() {
        let rec = RecordingController.shared
        rec.debugSetPhase(.idle); rec.addMarker()
        #expect(rec.markers.isEmpty)
        rec.debugSetPhase(.paused); rec.addMarker()
        #expect(rec.markers.isEmpty)
        rec.debugSetPhase(.idle)
    }
}

@MainActor @Suite struct ReferenceExtrasTests {
    @Test func areaMinimumIs150() {
        #expect(!AreaGeometry.canRecord(nil))
        #expect(!AreaGeometry.canRecord(CGRect(x: 0, y: 0, width: 149, height: 400)))
        #expect(!AreaGeometry.canRecord(CGRect(x: 0, y: 0, width: 400, height: 149)))
        #expect(AreaGeometry.canRecord(CGRect(x: 0, y: 0, width: 150, height: 150)))
    }

    @Test func areaTooSmallToRecordExplainsItself() {
        let s = AppSettings.shared
        let saved = (s.sourceMode, s.areaRect, s.areaDisplayID); defer { (s.sourceMode, s.areaRect, s.areaDisplayID) = saved }
        guard let d = Displays.resolve(0) else { return }
        s.sourceMode = .area; s.areaDisplayID = d.id; s.areaRect = CGRect(x: 10, y: 10, width: 100, height: 100)
        do { _ = try RecordingController.shared.makeOptions(); Issue.record("100×100 must not record") }
        catch { #expect(UserMessage.describe(error).contains("150")) }
    }

    @Test func removedRecentsPersistAndHideEntries() {
        let suite = UserDefaults(suiteName: "mov.yapcam.Yapcam.test-\(UUID().uuidString)")!
        let s = AppSettings(store: suite)
        #expect(s.removedRecents.isEmpty && s.highlightRecordedArea)
        s.removedRecents.insert("/x/A.yapcam")
        #expect(AppSettings(store: suite).removedRecents == ["/x/A.yapcam"])
    }
}

@MainActor @Suite struct WindowExtrasTests {
    @Test func displayFrameInCGCoordinates() {
        let f = CGRect(x: 0, y: 1050, width: 1512, height: 982)        // display above the primary
        #expect(OverlayGeometry.cgFrame(of: f, primaryMaxY: 1050) == CGRect(x: 0, y: -982, width: 1512, height: 982))
    }
}

/// Own preset folder and own defaults for the duration of `body`: tests never touch the user's real preset
/// library or default-preset choice, and parallel tests can't see each other's.
@MainActor func withIsolatedPresets<T>(_ body: () throws -> T) throws -> T {
    let dir = FileManager.default.temporaryDirectory.appending(path: "yapcam-presets-\(UUID().uuidString)", directoryHint: .isDirectory)
    let suiteName = "mov.yapcam.Yapcam.test-\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    defer { try? FileManager.default.removeItem(at: dir); suite.removePersistentDomain(forName: suiteName) }
    return try PresetIsolation.$directory.withValue(dir) {
        try PresetIsolation.$defaultsSuiteName.withValue(suiteName) { try body() }
    }
}

@MainActor @Suite struct WindowSizeAndIgnoreTests {
    @Test func sizeTextParsing() {
        #expect(WindowAX.parseSize("1280x720") == CGSize(width: 1280, height: 720))
        #expect(WindowAX.parseSize(" 1280 × 720 ") == CGSize(width: 1280, height: 720))
        #expect(WindowAX.parseSize("1024,768") == CGSize(width: 1024, height: 768))
        for bad in ["", "1280", "axb", "100x720", "1280x100", "9000x800", "1x2x3"] { #expect(WindowAX.parseSize(bad) == nil, "\(bad)") }
    }

    @Test func ignoredWindowsAreSkippedWhenPointing() {
        func row(_ id: UInt32, _ r: CGRect) -> WindowRow { WindowRow(id: id, pid: 10, layer: 0, app: "A", title: "t", bounds: r) }
        let rows = [row(1, CGRect(x: 0, y: 0, width: 500, height: 400)), row(2, CGRect(x: 0, y: 0, width: 800, height: 600))]
        #expect(WindowHit.pick(from: rows, at: CGPoint(x: 10, y: 10), excludingPID: 99)?.id == 1)
        #expect(WindowHit.pick(from: rows, at: CGPoint(x: 10, y: 10), excludingPID: 99, ignoring: [1])?.id == 2)
    }

    @Test func savedSizesPersistMostRecentFirst() {
        let suite = UserDefaults(suiteName: "mov.yapcam.Yapcam.test-\(UUID().uuidString)")!
        let s = AppSettings(store: suite)
        s.savedWindowSizes = ["1280x720", "800x600"]
        #expect(AppSettings(store: suite).savedWindowSizes == ["1280x720", "800x600"])
    }
}

// MARK: - QA hooks: hotkey scripts and after-recording choices

@MainActor @Suite struct HotkeyScriptTests {
    private func parse(_ t: String) -> ([HotkeyStep]?, String?) { var e: String?; let r = HotkeyStep.parse(t, error: &e); return (r, e) }

    @Test func parsesActionsWaitsKeysAndExpectations() {
        let (steps, err) = parse("recordDisplay, wait:1.5,return,wait:3,marker,pauseResume,expect:paused,restart,return,startStop")
        #expect(err == nil)
        #expect(steps == [.hotkey(.recordDisplay), .wait(1.5), .key("return"), .wait(3), .hotkey(.marker), .hotkey(.pauseResume),
                          .expect("paused"), .hotkey(.restart), .key("return"), .hotkey(.startStop)])
    }

    @Test func everyActionNameIsAcceptedAndBadStepsExplainThemselves() {
        for a in HotkeyAction.allCases { #expect(parse(a.rawValue).0 == [.hotkey(a)], "\(a)") }
        for bad in ["", " , ", "nope", "wait:abc", "wait:-1", "wait:9999", "startStop,whatever"] {
            let (r, e) = parse(bad)
            #expect(r == nil && !(e ?? "").isEmpty, "\(bad)")
        }
        #expect(parse("nope").1?.contains("startStop") == true)       // lists what is valid
    }

    @Test func carbonModifiersBecomeEventFlags() {
        let f = SelfTestKeys.flags(for: UInt32(cmdKey | controlKey))
        #expect(f.contains(.maskCommand) && f.contains(.maskControl) && !f.contains(.maskAlternate) && !f.contains(.maskShift))
        let all = SelfTestKeys.flags(for: UInt32(cmdKey | optionKey | controlKey | shiftKey))
        #expect(all.contains([.maskCommand, .maskAlternate, .maskControl, .maskShift]))
        #expect(SelfTestKeys.flags(for: 0).isEmpty)
        // the default start/stop shortcut posts ⌃⌘ + Return
        let c = HotkeyAction.startStop.defaultCombo!
        #expect(Int(c.keyCode) == kVK_Return && SelfTestKeys.flags(for: c.modifiers).contains([.maskCommand, .maskControl]))
    }

    @Test func phaseNamesForExpectations() {
        #expect(SelfTestKeys.matches(.recording, "recording") && SelfTestKeys.matches(.paused, "paused") && SelfTestKeys.matches(.idle, "idle"))
        #expect(SelfTestKeys.matches(.countdown(3), "countdown") && !SelfTestKeys.matches(.recording, "paused"))
    }

    @Test func afterRecordingChoicesAreTheDocumentedFour() {
        #expect(SelfTestOptions.afterRecordingChoices == ["create", "widget", "copy", "save"])
        #expect(SelfTestOptions() == SelfTestOptions(hotkeyScript: nil, afterRecording: nil, saveTo: nil))
    }
}

@MainActor @Suite struct ExportGuardTests {
    @Test func timeoutMessagesAreActionableAndMentionTheRecordingIsSafe() {
        for e in [QuickExport.QuickExportError.stalled(60)] {
            #expect(e.message.contains("recording is safe") && e.message.contains("editor"))
            #expect(!e.message.contains("Error Domain"))
        }
        #expect(QuickExport.stallLimit == 60 && QuickExport.setupLimit == 180)
        // R3-UI-2: total length never stops an export; only missing progress does.
        #expect(!QuickExport.isStalled(idleFor: 30, hasProgress: true))
        #expect(QuickExport.isStalled(idleFor: 61, hasProgress: true))
        #expect(!QuickExport.isStalled(idleFor: 120, hasProgress: false))   // setup before first progress
        #expect(QuickExport.isStalled(idleFor: 181, hasProgress: false))
    }

    @Test func autoConfirmAnswersConfirmationsWithoutABlockingDialog() {
        let rec = RecordingController.shared
        RecordingController.autoConfirm = true; defer { RecordingController.autoConfirm = false }
        // Not recording: nothing to confirm, nothing blocks.
        rec.confirmRestart(); rec.confirmFinish()
        #expect(rec.phase == .idle)
    }

    @Test func selfTestOptionsKnowAutoConfirmAndWatchdog() {
        var o = SelfTestOptions()
        #expect(!o.autoConfirm && o.watchdog == nil)
        o.autoConfirm = true; o.watchdog = 90
        #expect(o.autoConfirm && o.watchdog == 90)
    }
}

@MainActor @Suite struct OverlayKeyTests {
    @Test func returnStartsAndEscapeCancelsInEveryOverlay() {
        for key: UInt16 in [36, 76] { #expect(OverlayKeys.action(keyCode: key, typing: false) == .start) }
        #expect(OverlayKeys.action(keyCode: 53, typing: false) == .cancel)
        #expect(OverlayKeys.action(keyCode: 53, typing: true) == .cancel)          // Esc cancels even while typing
    }

    @Test func returnBelongsToANumberFieldWhileItIsBeingEdited() {
        #expect(OverlayKeys.action(keyCode: 36, typing: true) == .pass)
        #expect(OverlayKeys.action(keyCode: 76, typing: true) == .pass)
    }

    @Test func otherKeysPassThrough() {
        for key: UInt16 in [0, 12, 49, 123, 124, 125, 126, 51] { #expect(OverlayKeys.action(keyCode: key, typing: false) == .pass, "\(key)") }
    }

    /// The monitor is what makes Return work whichever control has focus; it must be installed and removed cleanly.
    @Test func keyMonitorInstallsAndRemoves() {
        _ = NSApplication.shared
        let token = OverlayKeys.install(start: {}, cancel: {})
        #expect(token != nil)
        OverlayKeys.remove(token)
        OverlayKeys.remove(nil)        // removing nothing is harmless
    }

    /// F16: one activation request can be lost, so the first Return went to another app. The claim repeats until key.
    @Test func keyClaimRepeatsUntilTheOverlayIsKey() async {
        var ready = false, claims = 0
        let c = KeyClaim(isReady: { ready }, claim: { claims += 1; if claims == 3 { ready = true } }, interval: .milliseconds(1), maxAttempts: 10)
        await c.run()
        #expect(claims == 3 && !c.gaveUp)       // the first two requests were "lost"; stops once key
    }

    @Test func keyClaimDoesNothingWhenAlreadyKeyAndGivesUpWhenNeverKey() async {
        var claims = 0
        let ok = KeyClaim(isReady: { true }, claim: { claims += 1 }, interval: .milliseconds(1))
        await ok.run()
        #expect(claims == 0)
        let never = KeyClaim(isReady: { false }, claim: { claims += 1 }, interval: .milliseconds(1), maxAttempts: 5)
        await never.run()
        #expect(claims == 5 && never.gaveUp)
    }

    @Test func keyClaimStopsWhenCancelled() async {
        var claims = 0
        let c = KeyClaim(isReady: { false }, claim: { claims += 1 }, interval: .milliseconds(1), maxAttempts: 1_000_000)
        c.start(); c.cancel()
        try? await Task.sleep(for: .milliseconds(20))
        let seen = claims
        try? await Task.sleep(for: .milliseconds(20))
        #expect(claims == seen)
    }

    // (A show/hide test is deliberately absent: the overlays are process-wide singletons shared with the snapshot smoke test.)
}

// MARK: - Start sound (GAP-CAP-7)

/// A clock that only moves when the test says so: no wall-clock thresholds, so machine load cannot change results.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by d: Duration) -> Instant { Instant(offset: offset + d) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }
    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [(deadline: Instant, id: Int, cont: CheckedContinuation<Void, Error>)] = []
    private var nextID = 0
    var now: Instant { lock.lock(); defer { lock.unlock() }; return current }
    var minimumResolution: Duration { .nanoseconds(1) }
    var sleeperCount: Int { lock.lock(); defer { lock.unlock() }; return sleepers.count }

    private func allocateID() -> Int { lock.lock(); defer { lock.unlock() }; nextID += 1; return nextID }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = allocateID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled { lock.unlock(); c.resume(throwing: CancellationError()); return }
                if deadline <= current { lock.unlock(); c.resume(); return }
                sleepers.append((deadline, id, c)); lock.unlock()
            }
        } onCancel: {
            self.lock.lock()
            let hit = self.sleepers.first { $0.id == id }
            self.sleepers.removeAll { $0.id == id }
            self.lock.unlock()
            hit?.cont.resume(throwing: CancellationError())
        }
    }

    func advance(by d: Duration) {
        lock.lock()
        current = current.advanced(by: d)
        let due = sleepers.filter { $0.deadline <= current }
        sleepers.removeAll { $0.deadline <= current }
        lock.unlock()
        due.forEach { $0.cont.resume() }
    }

    /// Lets the code under test reach its sleeps (yields, no wall-clock timeout).
    func waitForSleepers(_ n: Int) async { while sleeperCount < n { await Task.yield() } }
}

private struct ScriptedPlayer: CuePlayer {
    enum Mode { case completes(Int), never, ignoresCancellation, throwing }
    let mode: Mode
    let clock: ManualClock
    struct Boom: Error {}
    func play(_ cue: Cue, gain: Float) async throws {
        switch mode {
        case .completes(let ms): try await clock.sleep(for: .milliseconds(ms))
        case .never: try await clock.sleep(for: .seconds(60))
        case .ignoresCancellation:
            // Hung output device: never returns and does not react to cancellation.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        case .throwing: throw Boom()
        }
    }
}

@Suite struct StartSoundGateTests {
    /// Starts the gate on the manual clock; `finished` flips when the gate lets capture start.
    private final class Probe: @unchecked Sendable { var finished = false }
    private func start(_ mode: ScriptedPlayer.Mode, _ clock: ManualClock) -> (Task<Void, Never>, Probe) {
        let probe = Probe()
        let task = Task {
            await StartSoundGate.run(player: ScriptedPlayer(mode: mode, clock: clock), clock: clock, log: { _ in })
            probe.finished = true
        }
        return (task, probe)
    }

    @Test func startsWhenTheSoundFinishes() async {
        let clock = ManualClock()
        let (task, probe) = start(.completes(200), clock)
        await clock.waitForSleepers(2)                 // sound (200 ms) and cap (540 ms) are both waiting
        clock.advance(by: .milliseconds(199))
        for _ in 0..<50 { await Task.yield() }
        #expect(!probe.finished)
        clock.advance(by: .milliseconds(1))            // t = 200 ms: sound done, cap not reached
        await task.value
        #expect(probe.finished)
        #expect(clock.now.offset == .milliseconds(200))
    }
    @Test func neverCompletingSoundIsCutOffAt540() async {
        let clock = ManualClock()
        let (task, probe) = start(.never, clock)
        await clock.waitForSleepers(2)
        clock.advance(by: .milliseconds(539))
        for _ in 0..<50 { await Task.yield() }
        #expect(!probe.finished)
        clock.advance(by: .milliseconds(1))            // t = 540 ms
        await task.value
        #expect(probe.finished)
    }
    @Test func aPlayerThatIgnoresCancellationStillCannotHoldTheStart() async {
        let clock = ManualClock()
        let (task, probe) = start(.ignoresCancellation, clock)
        await clock.waitForSleepers(1)                 // only the cap is waiting
        clock.advance(by: .milliseconds(540))
        await task.value
        #expect(probe.finished)
    }
    @Test func failingPlayerStartsWithoutWaitingForTheClock() async {
        let clock = ManualClock()
        let (task, probe) = start(.throwing, clock)
        await task.value                               // no clock advance at all
        #expect(probe.finished)
        #expect(clock.now.offset == .zero)
    }
    @Test func gainAndLimitAreTheSpecValues() {
        #expect(StartSoundGate.gain == 0.33)
        #expect(StartSoundGate.limit == .milliseconds(540))
    }
    @Test func chimeIsOurOwnShortValidWav() {
        for cue in [Cue.start, .stop] {
            let wav = ChimeSynth.wav(cue)
            #expect(wav.prefix(4) == "RIFF".data(using: .ascii)!)
            #expect(ChimeSynth.duration(cue) < 0.54, "start chime must fit the gate")
            #expect(wav.count == 44 + ChimeSynth.samples(cue).count * 2)
            #expect(ChimeSynth.samples(cue).contains { abs($0) > 0.3 })
        }
        #expect((try? AVAudioPlayer(data: ChimeSynth.wav(.start))) != nil)
    }
}

@MainActor @Suite struct StartSoundOrderTests {
    @Test func countdownThenSoundThenCapture() async throws {
        let log = EventLog()
        let rec = RecordingController()   // own instance: the shared one is used by other suites
        let settings = AppSettings.shared
        let oldSounds = settings.playSounds, oldCountdown = settings.countdown
        defer { settings.playSounds = oldSounds; settings.countdown = oldCountdown }
        settings.playSounds = true; settings.countdown = 0
        rec.engine = OrderEngine(log: log)
        rec.cuePlayer = OrderPlayer(log: log)
        rec.startSession( UIRecordingOptions(target: .display(1), systemAudio: true, microphoneID: nil, cameraID: nil,
                                                    recordKeystrokes: false, maxFPS: 30, outputDirectory: FileManager.default.temporaryDirectory))
        for _ in 0..<1500 where rec.phase != .recording { try await Task.sleep(for: .milliseconds(20)) }
        #expect(rec.phase == .recording)
        #expect(await log.events == ["sound-start", "sound-end", "capture-start"])
        await rec.cancelAndWait()
    }
}

extension StartSoundOrderTests {
    @Test func silentTakeDoesNotWaitForTheCue() async throws {
        let log = EventLog()
        let rec = RecordingController()
        let settings = AppSettings.shared
        let oldSounds = settings.playSounds, oldCountdown = settings.countdown
        defer { settings.playSounds = oldSounds; settings.countdown = oldCountdown }
        settings.playSounds = true; settings.countdown = 0
        rec.engine = OrderEngine(log: log)
        rec.cuePlayer = OrderPlayer(log: log)
        let silent = UIRecordingOptions(target: .display(1), systemAudio: false, microphoneID: nil, cameraID: nil,
                                        recordKeystrokes: false, maxFPS: 30, outputDirectory: FileManager.default.temporaryDirectory)
        #expect(!RecordingController.shouldAwaitStartSound(silent))
        rec.startSession(silent)
        for _ in 0..<1500 where rec.phase != .recording { try await Task.sleep(for: .milliseconds(20)) }
        #expect(rec.phase == .recording)
        let events = await log.events
        #expect(events.firstIndex(of: "capture-start").map { $0 < (events.firstIndex(of: "sound-end") ?? Int.max) } ?? false)
        await rec.cancelAndWait()
    }
}

actor EventLog { var events: [String] = []; func add(_ e: String) { events.append(e) } }
private struct OrderPlayer: CuePlayer {
    let log: EventLog
    func play(_ cue: Cue, gain: Float) async throws {
        await log.add("sound-start"); try await Task.sleep(for: .milliseconds(100)); await log.add("sound-end")
    }
}

@MainActor private final class OrderSession: EngineSession {
    let log: EventLog
    init(log: EventLog) { self.log = log }
    var elapsed: TimeInterval { 0 }
    var micLevel: Float { 0 }
    var warnings: [String] { [] }
    var failure: EngineError? { nil }
    func start() async throws { await log.add("capture-start") }
    func pause() async throws { await log.add("pause") }
    func resume() async throws {}
    var stopDelayMs = 0
    func stop() async throws -> URL {
        try? await Task.sleep(for: .milliseconds(stopDelayMs)); await log.add("stop-end")
        return FileManager.default.temporaryDirectory
    }
    func cancel() async {}
}
@MainActor private struct OrderEngine: RecordingEngine {
    let log: EventLog
    var stopDelayMs = 0
    var issues: [PreflightIssue] = []
    func preflight(_ options: UIRecordingOptions) async -> [PreflightIssue] { issues }
    func makeSession(_ options: UIRecordingOptions) -> EngineSession { let s = OrderSession(log: log); s.stopDelayMs = stopDelayMs; return s }
    func registerExcluded(_ window: NSWindow) {}
    func unregisterExcluded(_ window: NSWindow) {}
    func openEditor(package: URL) {}
    func interruptedPackages(in directory: URL) -> [URL] { [] }
    func recover(_ package: URL) throws -> URL { package }
}

// MARK: - Camera max resolution (GAP-CAP-2)

@MainActor @Suite struct CameraResolutionTests {
    typealias S = CameraResolutionInfo.Size
    let hd720Only = [S(width: 640, height: 480), S(width: 1280, height: 720)]
    let uhd = [S(width: 1280, height: 720), S(width: 1920, height: 1080), S(width: 3840, height: 2160)]

    @Test func lowResolutionDeviceWithBigChoiceShows720p() {
        let t = CameraResolutionInfo.summary(maximum: .uhd4K, cameraSelected: true, formats: hd720Only)
        #expect(t.contains("720p (1280×720)"), "\(t)")
        #expect(t.contains("most this camera offers"))
    }
    @Test func fourKDeviceWith4KChoiceShows4K() {
        #expect(CameraResolutionInfo.summary(maximum: .uhd4K, cameraSelected: true, formats: uhd) == "Will record at 4K (3840×2160).")
    }
    @Test func capBelowDeviceShowsCapAndWhatCameraCanDo() {
        let t = CameraResolutionInfo.summary(maximum: .hd1080, cameraSelected: true, formats: uhd)
        #expect(t.contains("1080p (1920×1080)") && t.contains("up to 4K"), "\(t)")
        #expect(CameraResolutionInfo.effective(formats: uhd, maximum: .hd720) == S(width: 1280, height: 720))
    }
    @Test func noCameraExplainsWhenItApplies() {
        #expect(CameraResolutionInfo.summary(maximum: .hd1080, cameraSelected: false, formats: nil) == "Applies when a camera is used.")
    }
    @Test func unknownDeviceFallsBackToHonestText() {
        #expect(CameraResolutionInfo.summary(maximum: .hd1080, cameraSelected: true, formats: nil).contains("chosen when recording starts"))
    }
    @Test func choiceIsPersistedAndForwarded() throws {
        let s = AppSettings.shared
        let old = s.cameraMaxResolution; defer { s.cameraMaxResolution = old }
        s.cameraMaxResolution = .uhd4K
        #expect(AppDefaults.store.integer(forKey: "cameraMaxResolution") == 2160)
        let sm = s.sourceMode; defer { s.sourceMode = sm }
        s.sourceMode = .display
        guard let o = try? RecordingController.shared.makeOptions() else { return }
        #expect(o.cameraMaxResolution == .uhd4K)
    }
}

// MARK: - Third-party notices (U3)

@MainActor @Suite struct ThirdPartyNoticesTests {
    @Test func helpMenuItemOpensTheBundledFile() throws {
        _ = NSApplication.shared; let menu = MainMenu.build(target: AppDelegate())
        let help = try #require(menu.items.first { $0.title == "Help" }?.submenu)
        let item = try #require(help.items.first { $0.title == "Third-Party Notices" })
        #expect(item.action == #selector(AppDelegate.showThirdPartyNotices))
        // The resolver finds the file in a bundle that has it and opens exactly that URL.
        let dir = FileManager.default.temporaryDirectory.appending(path: "notices-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at: dir) }
        let res = dir.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
        try "Apache-2.0".write(to: res.appending(path: "THIRD_PARTY_NOTICES.txt"), atomically: true, encoding: .utf8)
        try "<plist version=\"1.0\"><dict/></plist>".write(to: dir.appending(path: "Contents/Info.plist"), atomically: true, encoding: .utf8)
        let bundle = try #require(Bundle(url: dir))
        var opened: URL?
        ThirdPartyNotices.open(bundle: bundle, opener: { opened = $0; return true })
        #expect(opened?.lastPathComponent == "THIRD_PARTY_NOTICES.txt")
    }
}

@MainActor @Suite struct PostRecordingQueueTests {
    // R3-UI-1: a slow after-recording export must not delay pause/stop of the next recording.
    @Test func slowPostProcessingDoesNotBlockTheNextRecording() async throws {
        let log = EventLog()
        let rec = RecordingController()
        let settings = AppSettings.shared
        let old = (settings.playSounds, settings.countdown, settings.openEditorAfterRecording)
        defer { (settings.playSounds, settings.countdown, settings.openEditorAfterRecording) = old }
        settings.playSounds = false; settings.countdown = 0; settings.openEditorAfterRecording = true
        rec.engine = OrderEngine(log: log)
        rec.deliver = { _ in try? await Task.sleep(for: .seconds(3600)) }   // blocks until the test ends
        let opts = UIRecordingOptions(target: .display(1), systemAudio: false, microphoneID: nil, cameraID: nil,
                                      recordKeystrokes: false, maxFPS: 30, outputDirectory: FileManager.default.temporaryDirectory)
        rec.startSession(opts)
        for _ in 0..<1500 where rec.phase != .recording { try await Task.sleep(for: .milliseconds(20)) }
        rec.stop()
        for _ in 0..<1500 where rec.phase != .idle { try await Task.sleep(for: .milliseconds(20)) }
        #expect(rec.phase == .idle)
        rec.startSession(opts)
        for _ in 0..<1500 where rec.phase != .recording { try await Task.sleep(for: .milliseconds(20)) }
        rec.pause()
        // Passes only if pause reaches the session while the previous delivery is still blocked (no wall-clock threshold).
        for _ in 0..<1500 where !(await log.events.contains("pause")) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await log.events.contains("pause"), "pause waited behind the previous export")
        await rec.cancelAndWait()
    }
}

// MARK: - Round 3 review fixes (R3-UI-3 … -21)

@MainActor @Suite struct ReviewRound3Tests {
    private func temp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "r3-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // R3-UI-3: the app the user was in comes back when the overlay goes away.
    @Test func overlayRemembersAndRestoresThePreviousApp() throws {
        let finder = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let (oldFront, oldActivate) = (OverlayFocus.frontmost, OverlayFocus.activate)
        defer { OverlayFocus.frontmost = oldFront; OverlayFocus.activate = oldActivate; OverlayFocus.restore() }
        var activated: [String?] = []
        OverlayFocus.activate = { _ in }
        OverlayFocus.restore()                                    // a remembered app left by an overlay test must not leak in
        OverlayFocus.frontmost = { finder }
        OverlayFocus.activate = { activated.append($0.bundleIdentifier) }
        OverlayFocus.remember(); OverlayFocus.remember()
        OverlayFocus.restore(); OverlayFocus.restore()
        #expect(activated == ["com.apple.finder"])               // once, however often remembered/restored
        OverlayFocus.frontmost = { NSRunningApplication.current }  // Yapcam in front: nothing to restore
        OverlayFocus.remember(); OverlayFocus.restore()
        #expect(activated.count == 1)
    }

    // R3-UI-7: Quit waits for Stop's finalization.
    @Test func settleWaitsForStopFinalization() async throws {
        let log = EventLog()
        let rec = RecordingController()
        let s = AppSettings.shared
        let old = (s.playSounds, s.countdown, s.openEditorAfterRecording)
        defer { (s.playSounds, s.countdown, s.openEditorAfterRecording) = old }
        s.playSounds = false; s.countdown = 0; s.openEditorAfterRecording = false
        rec.engine = OrderEngine(log: log, stopDelayMs: 300)
        rec.startSession(UIRecordingOptions(target: .display(1), systemAudio: false, microphoneID: nil, cameraID: nil,
                                            recordKeystrokes: false, maxFPS: 30, outputDirectory: FileManager.default.temporaryDirectory))
        for _ in 0..<1500 where rec.phase != .recording { try await Task.sleep(for: .milliseconds(20)) }
        rec.stop()
        #expect(rec.phase == .finishing)
        await rec.settle()
        #expect(await log.events.contains("stop-end"))
        #expect(rec.phase == .idle)
    }

    // R3-UI-8: a project created by the UI starts from the default preset.
    @Test func newProjectStartsFromDefaultPreset() throws {
        try withIsolatedPresets {
            let dir = try temp(); defer { try? FileManager.default.removeItem(at: dir) }
            let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/synthetic/basic.yapcam")
            let source = dir.appending(path: "S.yapcam"), target = dir.appending(path: "T.yapcam")
            try FileManager.default.copyItem(at: fixture, to: source)
            try FileManager.default.copyItem(at: fixture, to: target)
            let sp = try Project.create(package: source)
            try sp.apply(.set(path: "canvas.padding", value: .number(0.31)))
            _ = try PresetStore.save(sp, as: "Look")
            EditorPresets.currentStore.defaultName = "Look"
            let p = try ProjectActions.openOrCreateProject(target)
            let json = try String(data: p.toJSON(), encoding: .utf8) ?? ""
            #expect(json.contains("0.31"))
        }
    }

    // R3-UI-11: a failed copy never costs the user the existing file; a good one replaces it.
    @Test func saveReplacesAtomically() throws {
        let dir = try temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appending(path: "talk.mp4")
        try "original".write(to: dest, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try QuickExport.replaceFile(at: dest, with: dir.appending(path: "missing.mp4")) }
        #expect(try String(contentsOf: dest, encoding: .utf8) == "original")
        let src = dir.appending(path: "new.mp4"); try "fresh".write(to: src, atomically: true, encoding: .utf8)
        try QuickExport.replaceFile(at: dest, with: src)
        #expect(try String(contentsOf: dest, encoding: .utf8) == "fresh")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }.isEmpty)
    }

    // R3-UI-15: auto-repeat of a held Return does not skip the countdown.
    @Test func heldReturnDoesNotSkipTheCountdown() throws {
        _ = NSApplication.shared
        let panel = ReadyPanel()
        var returns = 0
        panel.onReturn = { returns += 1 }
        func key(repeat r: Bool) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                             characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: r, keyCode: 36)
        }
        panel.keyDown(with: try #require(key(repeat: false)))
        panel.keyDown(with: try #require(key(repeat: true)))
        #expect(returns == 1)
    }

    // R3-UI-16: a chosen display that is gone is an error, not the main display.
    @Test func missingChosenDisplayFailsVisibly() {
        let s = AppSettings.shared
        let old = (s.sourceMode, s.displayID); defer { (s.sourceMode, s.displayID) = old }
        s.sourceMode = .display; s.displayID = 987_654
        do { _ = try RecordingController.shared.makeOptions(); Issue.record("must not fall back to the main display") }
        catch { #expect(UserMessage.describe(error).contains("not connected")) }
    }

    // R3-UI-17: an area clipped below the minimum does not record.
    @Test func clippedAreaBelowMinimumDoesNotRecord() {
        let s = AppSettings.shared
        let old = (s.sourceMode, s.areaRect, s.areaDisplayID); defer { (s.sourceMode, s.areaRect, s.areaDisplayID) = old }
        guard let d = Displays.resolve(0) else { return }
        s.sourceMode = .area; s.areaDisplayID = d.id
        s.areaRect = CGRect(x: d.frame.width - 120, y: 10, width: 400, height: 300)   // only 120 pt remain on the display
        do { _ = try RecordingController.shared.makeOptions(); Issue.record("120 pt wide must not record") }
        catch { #expect(UserMessage.describe(error).contains("150")) }
    }

    // R3-UI-18: old quick-export runs are pruned, new ones are kept.
    @Test func cachePruneRemovesOnlyOldRuns() throws {
        let dir = try temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appending(path: "old", directoryHint: .isDirectory), new = dir.appending(path: "new", directoryHint: .isDirectory)
        for d in [old, new] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 24 * 3600)], ofItemAtPath: old.path)
        QuickExport.pruneCache(in: dir)
        #expect(!FileManager.default.fileExists(atPath: old.path) && FileManager.default.fileExists(atPath: new.path))
    }

    // R3-UI-20: a recording the engine ended keeps its markers and notes.
    @Test func salvageKeepsMarkersAndNotes() throws {
        let dir = try temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = dir.appending(path: "X.yapcam", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pkg.appending(path: "recording"), withIntermediateDirectories: true)
        PostRecording.salvage(package: pkg, notes: "say hello", markers: [5, 9])
        #expect(try String(contentsOf: pkg.appending(path: "recording/notes.txt"), encoding: .utf8) == "say hello")
        #expect(FileManager.default.fileExists(atPath: pkg.appending(path: "recording/markers.json").path))
    }
}

// The area overlay is a shared singleton; this lives in the serialized snapshot suite so it never overlaps its rendering.
extension UISmokeTests {
    // R3-UI-6: Start/Stop while an area overlay is open records what the overlay shows.
    @Test func startShortcutWhileAreaOverlayIsOpenCommitsTheOverlay() throws {
        guard let screen = NSScreen.main else { return }
        var result: CGRect?? = .none
        AreaSelector.shared.begin(on: screen, initial: CGRect(x: 100, y: 100, width: 400, height: 300)) { result = .some($0) }
        defer { AreaSelector.shared.cancelForTesting() }
        RecordingController().begin()
        #expect(AreaSelector.shared.isActive == false)
        #expect(result == .some(CGRect(x: 100, y: 100, width: 400, height: 300)))
    }

}


// MARK: - Per-app system audio (GAP-CAP-1)

@MainActor @Suite struct SystemAudioChoiceTests {
    private func store() -> UserDefaults {
        let name = "yapcam.test.audio.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!; d.removePersistentDomain(forName: name); return d
    }

    @Test func existingUsersKeepAllAppsWhileTheirToggleIsOn() {
        let d = store()
        d.set(true, forKey: "systemAudio")      // what versions before this one stored
        #expect(AppSettings(store: d).systemAudioChoice == .all)
        d.set(false, forKey: "systemAudio")
        #expect(AppSettings(store: d).systemAudioChoice == .off)
        #expect(AppSettings(store: store()).systemAudioChoice == .off)      // reference default: off
    }

    @Test func selectedAppsPersistByBundleID() {
        let d = store()
        let s = AppSettings(store: d)
        s.systemAudioChoice = .selected
        s.setApp("com.apple.Safari", selected: true); s.setApp("com.apple.Music", selected: true)
        s.setApp("com.apple.Safari", selected: false)
        let again = AppSettings(store: d)
        #expect(again.systemAudioChoice == .selected)
        #expect(again.systemAudioApps == ["com.apple.Music"])
        again.systemAudioChoice = .off
        #expect(AppSettings(store: d).systemAudioChoice == .off)
        #expect(AppSettings(store: d).systemAudioApps == ["com.apple.Music"])       // the list survives switching away
    }

    @Test func choiceIsForwardedToTheCaptureSelection() {
        let s = AppSettings(store: store())
        func opts() -> UIRecordingOptions {
            UIRecordingOptions(target: .display(1), systemAudio: s.systemAudio, systemAudioApps: s.systemAudioAppsForRecording,
                               microphoneID: nil, cameraID: nil, recordKeystrokes: false, maxFPS: 30, outputDirectory: URL(fileURLWithPath: "/tmp"))
        }
        s.systemAudioChoice = .off
        #expect(LiveEngine.selection(for: opts()) == .off)
        s.systemAudioChoice = .all
        #expect(LiveEngine.selection(for: opts()) == .allApplications)
        s.systemAudioChoice = .selected; s.systemAudioApps = ["a.b", "c.d"]
        #expect(LiveEngine.selection(for: opts()) == .applications(bundleIDs: ["a.b", "c.d"]))
        s.systemAudioChoice = .selected; s.systemAudioApps = []
        #expect(LiveEngine.selection(for: opts()) == .applications(bundleIDs: []))     // never widened to all apps
    }

    @Test func desktopIconPreferenceReachesCaptureWithoutFinderMutation() {
        let ui = UIRecordingOptions(
            target: .display(7), systemAudio: false, microphoneID: nil, cameraID: nil,
            recordKeystrokes: false, maxFPS: 30, hideDesktopIcons: true,
            outputDirectory: URL(fileURLWithPath: "/tmp"))
        let capture = LiveEngine.captureOptions(for: ui)
        #expect(capture.hideDesktopIcons)
        #expect(capture.target == .display(7))
    }

    @Test func desktopIconSettingReachesControllerOptions() throws {
        let s = AppSettings.shared
        let saved = (s.sourceMode, s.displayID, s.hideDesktopIcons)
        defer { (s.sourceMode, s.displayID, s.hideDesktopIcons) = saved }
        s.sourceMode = .display
        s.displayID = 0
        s.hideDesktopIcons = true
        guard Displays.resolve(0) != nil else { return }
        #expect(try RecordingController.shared.makeOptions().hideDesktopIcons)
    }

    @Test func checklistListsInjectedAppsAndKeepsClosedSelections() async {
        let m = AudioAppsModel()
        m.load = { [CaptureApplication(bundleID: "com.a", name: "Alpha"), CaptureApplication(bundleID: "com.b", name: "Beta")] }
        await m.refresh()
        #expect(m.rows(selected: [], search: "").map(\.bundleID) == ["com.a", "com.b"])
        #expect(m.rows(selected: ["com.gone"], search: "").map(\.bundleID) == ["com.a", "com.b", "com.gone"])
        #expect(m.rows(selected: [], search: "bet").map(\.bundleID) == ["com.b"])
    }
}

// MARK: - Pre-flight prompts (GAP-CAP-6)

@MainActor @Suite struct PreflightPromptTests {
    private func issue(_ k: PreflightIssue.Kind, _ p: AppPermission? = nil) -> PreflightIssue { PreflightIssue(kind: k, message: "m", permission: p) }

    @Test func noConditionNeverAsks() {
        var asked = 0
        let o = PreflightFlow.resolve([], systemAudioApps: ["x"]) { _, _ in asked += 1; return .cancel }
        #expect(asked == 0 && o == .start(systemAudioApps: ["x"]))
    }

    @Test func everyConditionOffersItsChoices() {
        #expect(PreflightFlow.choices(for: issue(.cameraWithoutMicrophone)) == [.continue, .chooseDevice, .cancel])
        #expect(PreflightFlow.choices(for: issue(.cameraMissing)) == [.continue, .chooseDevice, .cancel])
        #expect(PreflightFlow.choices(for: issue(.microphoneMissing)) == [.continue, .chooseDevice, .cancel])
        #expect(PreflightFlow.choices(for: issue(.microphoneLidClosed)) == [.continue, .chooseDevice, .cancel])
        #expect(PreflightFlow.choices(for: issue(.permissionRequired, .microphone)) == [.openSettings(.microphone), .continue, .cancel])
        #expect(PreflightFlow.choices(for: issue(.permissionRequired, .screen)) == [.openSettings(.screen), .cancel])   // nothing to record without it
        #expect(PreflightFlow.choices(for: issue(.applicationAudioUnavailable)) == [.chooseDevice, .recordAllAppAudio, .cancel])
        #expect(PreflightFlow.choices(for: issue(.windowResizePermission)) == [.openSettings(.accessibility), .continue, .cancel])
        for k in [PreflightIssue.Kind.cameraWithoutMicrophone, .cameraMissing, .microphoneMissing, .microphoneLidClosed, .permissionRequired, .applicationAudioUnavailable, .windowResizePermission] {
            #expect(!PreflightFlow.title(for: issue(k)).isEmpty)
        }
    }

    @Test func answersLeadWhereTheyShould() {
        func run(_ i: PreflightIssue, _ answer: PreflightChoice) -> PreflightOutcome {
            PreflightFlow.resolve([i], systemAudioApps: ["x"]) { _, _ in answer }
        }
        #expect(run(issue(.cameraWithoutMicrophone), .continue) == .start(systemAudioApps: ["x"]))
        #expect(run(issue(.cameraWithoutMicrophone), .chooseDevice) == .chooseDevice)
        #expect(run(issue(.microphoneLidClosed), .cancel) == .cancel)
        #expect(run(issue(.permissionRequired, .camera), .openSettings(.camera)) == .openSettings(.camera))
        #expect(run(issue(.applicationAudioUnavailable), .recordAllAppAudio) == .start(systemAudioApps: nil))
        #expect(run(issue(.cameraMissing), .recordAllAppAudio) == .cancel)      // an answer the prompt did not offer cancels
    }

    @Test func severalConditionsAreAskedInOrderAndCancelStopsTheRest() {
        var seen: [PreflightIssue.Kind] = []
        let o = PreflightFlow.resolve([issue(.cameraMissing), issue(.microphoneLidClosed), issue(.cameraWithoutMicrophone)], systemAudioApps: nil) { i, _ in
            seen.append(i.kind); return seen.count == 2 ? .cancel : .continue
        }
        #expect(seen == [.cameraMissing, .microphoneLidClosed] && o == .cancel)
    }

    @Test func controllerAsksBeforeTheRecordingStartsAndHonoursCancel() async throws {
        let log = EventLog()
        let rec = RecordingController()
        let settings = AppSettings.shared
        let old = settings.countdown, oldSounds = settings.playSounds
        defer { settings.countdown = old; settings.playSounds = oldSounds }
        settings.countdown = 0; settings.playSounds = false
        var engine = OrderEngine(log: log)
        engine.issues = [issue(.cameraWithoutMicrophone)]
        rec.engine = engine
        let opts = UIRecordingOptions(target: .display(1), systemAudio: false, microphoneID: nil, cameraID: nil,
                                      recordKeystrokes: false, maxFPS: 30, outputDirectory: FileManager.default.temporaryDirectory)
        var prompts: [PreflightIssue.Kind] = []
        rec.askPreflight = { i, _ in prompts.append(i.kind); return .cancel }
        rec.preflightThenStart(opts)
        for _ in 0..<500 where rec.preflighting { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(prompts == [.cameraWithoutMicrophone] && rec.phase == .idle)
        #expect(await log.events.isEmpty)               // nothing was captured

        rec.askPreflight = { i, _ in prompts.append(i.kind); return .continue }
        rec.preflightThenStart(opts)
        for _ in 0..<1500 where rec.phase != .recording { try await Task.sleep(for: .milliseconds(20)) }
        #expect(rec.phase == .recording && prompts.count == 2)
        await rec.cancelAndWait()
    }

    @Test func controllerRoutesChooseDeviceAndPermissionAnswers() async throws {
        let rec = RecordingController()
        var engine = OrderEngine(log: EventLog())
        engine.issues = [issue(.microphoneMissing)]
        rec.engine = engine
        var routed: [PreflightOutcome] = []
        rec.routePreflight = { routed.append($0) }
        rec.askPreflight = { _, _ in .chooseDevice }
        rec.preflightThenStart(UIRecordingOptions(target: .display(1), systemAudio: false, microphoneID: nil, cameraID: nil,
                                                  recordKeystrokes: false, maxFPS: 30, outputDirectory: FileManager.default.temporaryDirectory))
        for _ in 0..<500 where routed.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(routed == [.chooseDevice] && rec.phase == .idle)
    }

    @Test func noIssuesStartsWithoutAnyPrompt() async throws {
        let rec = RecordingController()
        let settings = AppSettings.shared
        let old = settings.countdown, oldSounds = settings.playSounds
        defer { settings.countdown = old; settings.playSounds = oldSounds }
        settings.countdown = 0; settings.playSounds = false
        rec.engine = OrderEngine(log: EventLog())
        var asked = 0
        rec.askPreflight = { _, _ in asked += 1; return .cancel }
        rec.preflightThenStart(UIRecordingOptions(target: .display(1), systemAudio: false, microphoneID: nil, cameraID: nil,
                                                  recordKeystrokes: false, maxFPS: 30, outputDirectory: FileManager.default.temporaryDirectory))
        for _ in 0..<1500 where rec.phase != .recording { try await Task.sleep(for: .milliseconds(20)) }
        #expect(rec.phase == .recording && asked == 0)
        await rec.cancelAndWait()
    }
}

// MARK: - Transcription options (AUD-10)

@Suite struct TranscriptionWiringTests {
    private actor Seen { private var items: [String] = []; private var terms: [[String]] = []
        func add(_ l: String, _ k: [String]) { items.append(l); terms.append(k) }
        func langs() -> [String] { items }; func keyterms() -> [[String]] { terms } }

    @Test func keytermsAndChosenLanguageReachTheTranscriber() async throws {
        let seen = Seen()
        let run: TranscriptionWiring.Transcribe = { _, l, k in await seen.add(l, k); return Data("{}".utf8) }
        _ = try await TranscriptionWiring.transcribe(package: URL(fileURLWithPath: "/p"),
            options: TranscriptionOptions(keyterms: ["Yapcam", " Kilian ", "", "yapcam"], language: "de-DE"), using: run)
        #expect(await seen.langs() == ["de-DE"])
        #expect(await seen.keyterms() == [["Yapcam", "Kilian"]])
    }

    @Test func autoIsHandedToCaptureForDetection() async throws {
        let seen = Seen()
        let run: TranscriptionWiring.Transcribe = { _, l, k in await seen.add(l, k); return Data() }
        _ = try await TranscriptionWiring.transcribe(package: URL(fileURLWithPath: "/p"), options: TranscriptionOptions(), using: run, system: "fr_FR")
        #expect(await seen.langs() == ["auto"])
    }

    @Test func languageListIsSortedAndDeduplicated() {
        let l = TranscriptionWiring.languages(from: [Locale(identifier: "en-US"), Locale(identifier: "de-DE"), Locale(identifier: "en-US")], display: Locale(identifier: "en_US"))
        #expect(l.map(\.id) == ["en-US", "de-DE"] && l[1].name.contains("German"))
    }

    @Test @MainActor func theAppSetsBothHooks() {
        let saved = (EditorWindows.transcriber, EditorWindows.transcriberWithOptions, EditorWindows.languageProvider)
        defer { (EditorWindows.transcriber, EditorWindows.transcriberWithOptions, EditorWindows.languageProvider) = saved }
        EditorWindows.transcriberWithOptions = nil; EditorWindows.languageProvider = nil
        AppDelegate().installTranscriber()
        #expect(EditorWindows.transcriberWithOptions != nil && EditorWindows.languageProvider != nil)
        let list = EditorWindows.languageProvider?() ?? []
        #expect(list.contains { $0.id.hasPrefix("en") })
    }
}


// MARK: - Settings partials (GAP-UI-6 / UI-10 / RND-9)

@MainActor @Suite struct SettingsPartialsTests {
    private func store() -> UserDefaults {
        let name = "yapcam.test.partials.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!; d.removePersistentDomain(forName: name); return d
    }

    private func package(_ dir: URL, _ name: String) throws -> URL {
        let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/synthetic/basic.yapcam")
        let url = dir.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: fixture, to: url)
        return url
    }

    @Test func customAspectRatioRules() {
        #expect(AreaAspect.ratio(width: 5, height: 4) == 1.25)
        #expect(AreaAspect.ratio(width: 0, height: 4) == nil)
        #expect(AreaAspect.ratio(width: 100, height: 1) == nil)      // beyond 20:1
        #expect(AreaAspect.ratio(width: .nan, height: 1) == nil)
        let r = AreaAspect.fit(CGRect(x: 100, y: 100, width: 400, height: 400), ratio: 2.5, in: CGSize(width: 1000, height: 600))
        #expect(abs(r.width / r.height - 2.5) < 0.001 && r.width == 400 && CGRect(x: 0, y: 0, width: 1000, height: 600).contains(r))
        let tall = AreaAspect.fit(CGRect(x: 0, y: 0, width: 900, height: 100), ratio: 0.1, in: CGSize(width: 1000, height: 600))
        #expect(tall.height <= 600 && abs(tall.width / tall.height - 0.1) < 0.001)
    }

    @Test func newSettingsDefaultAndPersist() {
        let d = store()
        let s = AppSettings(store: d)
        #expect(s.reuseLastProjectSettings && !s.experimentalVariableFrameRate && s.presetsDirectory == nil)
        #expect(s.areaCustomRatioW == 16 && s.areaCustomRatioH == 10)
        s.reuseLastProjectSettings = true; s.experimentalVariableFrameRate = true
        s.presetsDirectory = URL(filePath: "/tmp/yp-presets", directoryHint: .isDirectory)
        s.areaCustomRatioW = 5; s.areaCustomRatioH = 4
        let again = AppSettings(store: d)
        #expect(again.reuseLastProjectSettings && again.experimentalVariableFrameRate)
        #expect(again.presetsDirectory?.path == "/tmp/yp-presets" && again.areaCustomRatioW == 5 && again.areaCustomRatioH == 4)
        again.presetsDirectory = nil
        #expect(AppSettings(store: d).presetsDirectory == nil)
    }

    @Test func presetsFolderIsAppliedToTheEditor() {
        let saved = EditorPresets.globalDirectory
        defer { EditorPresets.globalDirectory = saved }
        let dir = URL(filePath: "/tmp/yp-presets-x", directoryHint: .isDirectory)
        PresetsFolder.apply(dir)
        #expect(EditorPresets.globalDirectory == dir)
        PresetsFolder.apply(nil)
        #expect(EditorPresets.globalDirectory == nil)
    }

    @Test func quickExportHonoursTheVariableFrameRateToggle() {
        #expect(QuickExport.quickExportSettings(variableFrameRate: false).variableFrameRate == false)
        #expect(QuickExport.quickExportSettings(variableFrameRate: true).variableFrameRate == true)
    }

    @Test func reuseLastProjectCopiesTheMostRecentLook() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "yp-reuse-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try package(dir, "A.yapcam")
        let pa = try Project.create(package: a)
        try pa.apply(.set(path: "canvas.padding", value: .number(0.37)))
        try pa.save()
        let b = try package(dir, "B.yapcam")
        let pb = try Project.create(package: b)
        #expect(ProjectActions.lastProject(excluding: b, in: dir)?.lastPathComponent == "A.yapcam")
        ProjectActions.applyInitialLook(to: pb, package: b, reuseLast: true, in: dir)
        func padding(_ p: Project) -> Double? {
            let snap = try? p.snapshot()
            guard let data = try? snap?.toJSON(), let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return ((j["canvas"] as? [String: Any])?["padding"] as? NSNumber)?.doubleValue
        }
        #expect(abs((padding(pb) ?? 0) - 0.37) < 0.001)
        // Off: nothing is copied.
        let c = try package(dir, "C.yapcam")
        let pc = try Project.create(package: c)
        ProjectActions.applyInitialLook(to: pc, package: c, reuseLast: false, in: dir)
        #expect(abs((padding(pc) ?? 0) - 0.37) > 0.001)
    }

    @Test func reuseWithNoEarlierProjectFallsBackQuietly() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "yp-reuse-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let only = try package(dir, "Only.yapcam")
        let p = try Project.create(package: only)
        #expect(ProjectActions.lastProject(excluding: only, in: dir) == nil)
        ProjectActions.applyInitialLook(to: p, package: only, reuseLast: true, in: dir)     // must not throw or crash
    }
}

// MARK: - Editor hooks (autosave, variable frame rate)

@MainActor @Suite struct EditorHooksTests {
    private func store() -> UserDefaults {
        let name = "yapcam.test.hooks.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!; d.removePersistentDomain(forName: name); return d
    }

    @Test func autosaveDefaultsOnPersistsAndReachesTheEditor() {
        let savedA = EditorWindows.autosaveEnabled, savedV = EditorWindows.variableFrameRate
        defer { EditorWindows.autosaveEnabled = savedA; EditorWindows.variableFrameRate = savedV }
        let d = store()
        let s = AppSettings(store: d)
        #expect(s.autosaveEnabled)
        EditorHooks.install(s)
        #expect(EditorWindows.autosaveEnabled)
        s.autosaveEnabled = false
        #expect(!EditorWindows.autosaveEnabled)
        #expect(!AppSettings(store: d).autosaveEnabled)
        s.autosaveEnabled = true
        #expect(EditorWindows.autosaveEnabled)
    }

    @Test func variableFrameRateToggleIsReadAtExportTime() {
        let savedA = EditorWindows.autosaveEnabled, savedV = EditorWindows.variableFrameRate
        defer { EditorWindows.autosaveEnabled = savedA; EditorWindows.variableFrameRate = savedV }
        let s = AppSettings(store: store())
        EditorHooks.install(s)
        #expect(EditorWindows.variableFrameRate() == false)
        s.experimentalVariableFrameRate = true
        #expect(EditorWindows.variableFrameRate() == true)
        s.experimentalVariableFrameRate = false
        #expect(EditorWindows.variableFrameRate() == false)
    }
}
