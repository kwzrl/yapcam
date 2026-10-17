import AppKit
import AVFoundation
import Foundation
import Testing
import UniformTypeIdentifiers
import YapcamCore
import YapcamEditor
@testable import YapcamUI

@MainActor @Suite struct Round7RecordingShellTests {
    // B-01 Dock menu
    @Test func dockMenuListsTheRightItemsPerPhase() {
        func titles(_ p: RecordingPhase, dock: Bool = true) -> [String] { DockMenu.items(phase: p, showInDock: dock).filter { $0.kind != .separator }.map(\.title) }
        #expect(titles(.recording) == ["Finish Recording", "Pause Recording", "Restart Recording…", "Cancel Recording…", "Settings…"])
        #expect(titles(.paused) == ["Finish Recording", "Resume Recording", "Restart Recording…", "Cancel Recording…", "Settings…"])
        #expect(titles(.idle) == ["New Recording", "Open Last Recording", "Settings…", "Keep in Dock"])
        #expect(titles(.countdown(3)) == ["Cancel Countdown"])
        #expect(DockMenu.items(phase: .starting, showInDock: true).first?.enabled == false)
        #expect(DockMenu.items(phase: .idle, showInDock: true).last?.checked == true)
        #expect(DockMenu.items(phase: .idle, showInDock: false).last?.checked == false)
    }
    @Test func dockMenuIsBuiltForTheCurrentPhaseWithLiveTargets() {
        _ = NSApplication.shared
        let d = AppDelegate()
        let m = d.applicationDockMenu(NSApp)
        #expect(m?.items.map(\.title).contains("New Recording") == true)
        #expect(m?.items.allSatisfy { $0.isSeparatorItem || ($0.target === d && $0.action != nil) } == true)
    }

    // B-03 Start / finish
    @Test func startStopOpensThePickerFirst() {
        typealias R = StartStopRule
        #expect(R.action(phase: .idle, pickerVisible: false, overlayActive: false) == .showPicker)
        #expect(R.action(phase: .idle, pickerVisible: true, overlayActive: false) == .begin)
        #expect(R.action(phase: .idle, pickerVisible: true, overlayActive: true) == .begin)
        #expect(R.action(phase: .idle, pickerVisible: false, overlayActive: true) == .begin)
        #expect(R.action(phase: .countdown(2), pickerVisible: true, overlayActive: false) == .cancelCountdown)
        #expect(R.action(phase: .recording, pickerVisible: false, overlayActive: false) == .stop)
        #expect(R.action(phase: .paused, pickerVisible: false, overlayActive: false) == .stop)
        #expect(R.action(phase: .starting, pickerVisible: false, overlayActive: false) == .none)
        #expect(R.action(phase: .finishing, pickerVisible: true, overlayActive: false) == .none)
    }

    // B-02 camera preview during a take
    @Test func cameraPreviewStaysDuringATakeUnlessHidden() {
        func show(_ p: RecordingPhase, bar: Bool = false, hidden: Bool = false) -> Bool {
            CameraPreviewPanel.shouldShow(barVisible: bar, phase: p, cameraID: "cam", cameraAvailable: true, permissionGranted: true, hidden: hidden)
        }
        for p: RecordingPhase in [.countdown(3), .starting, .recording, .paused] { #expect(show(p)) ; #expect(!show(p, hidden: true)) }
        #expect(!show(.idle) && show(.idle, bar: true) && !show(.finishing, bar: true))
        #expect(CameraPreviewPanel.opacity(for: .paused) < 1 && CameraPreviewPanel.opacity(for: .recording) == 1)
    }
    @Test func savedPreviewPositionIsUsedOnlyWhenStillOnAScreen() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        #expect(CameraPreviewPanel.savedOrigin([100, 200], screens: screens) == CGPoint(x: 100, y: 200))
        #expect(CameraPreviewPanel.savedOrigin([5000, 200], screens: screens) == nil)
        #expect(CameraPreviewPanel.savedOrigin(nil, screens: screens) == nil)
        #expect(CameraPreviewPanel.savedOrigin([1], screens: screens) == nil)
    }

    // B-04 speaker notes + prompter
    @Test func prompterScrollsWhenPlayingRegardlessOfTheRecordingPhase() {
        let m = PrompterModel(); m.speed = 8
        m.tick(dt: 1, maxOffset: 1000)
        #expect(m.offset == 0)                      // not playing: no movement
        m.playing = true
        m.tick(dt: 0.5, maxOffset: 1000)
        #expect(m.offset == PrompterRanges.pointsPerSecond(8) * 0.5)
        #expect(RecordingController.shared.phase == .idle)      // no take is running
    }
    @Test func prompterStopsAtTheEndAndRestartsFromTheTop() {
        let m = PrompterModel(); m.speed = 25; m.playing = true
        m.tick(dt: 10, maxOffset: 200)
        #expect(m.offset == 200 && !m.playing)
        m.togglePlay(maxOffset: 200)
        #expect(m.offset == 0 && m.playing)
        let empty = PrompterModel(); empty.playing = true
        empty.tick(dt: 1, maxOffset: 0)
        #expect(!empty.playing)                      // nothing to scroll
    }
    @Test func prompterSizeResetAndRanges() {
        let m = PrompterModel(); m.fontSize = 30
        #expect(!m.sizeIsDefault)
        m.resetSize()
        #expect(m.fontSize == 20 && m.sizeIsDefault)
        #expect(PrompterRanges.speed == 1...25 && PrompterRanges.speedDefault == 8)
        #expect(PrompterRanges.clampedSpeed(0) == 1 && PrompterRanges.clampedSpeed(99) == 25)
    }
    @Test func notesAreOneWindowAndThePlayShortcutOpensIt() {
        _ = NSApplication.shared
        let before = NotesWindow.shared.isVisible
        NotesWindow.shared.hide()
        NotesWindow.shared.togglePlay()
        #expect(NotesWindow.shared.isVisible && PrompterModel.shared.playing)
        PrompterModel.shared.playing = false; NotesWindow.shared.hide()
        if before { NotesWindow.shared.show() }
    }

    // B-05 / B-07 / B-08
    @Test func speakerNotesShortcutIsGlobal() {
        #expect(HotkeyAction.allCases.filter(\.isGlobal).contains(.toggleNotes))
    }
    @Test func activationPolicyKeepsTheDockIconWhileAnEditorIsOpen() {
        typealias A = AppSettings
        #expect(A.activationPolicy(showInDock: false, hideWhileRecording: false, recording: false, editorOpen: false) == .accessory)
        #expect(A.activationPolicy(showInDock: false, hideWhileRecording: false, recording: false, editorOpen: true) == .regular)
        #expect(A.activationPolicy(showInDock: false, hideWhileRecording: true, recording: true, editorOpen: true) == .regular)
        #expect(A.activationPolicy(showInDock: true, hideWhileRecording: true, recording: true, editorOpen: false) == .accessory)
        #expect(A.activationPolicy(showInDock: true, hideWhileRecording: true, recording: false, editorOpen: false) == .regular)
    }
    @Test func reuseLastProjectSettingsDefaultsToOn() {
        #expect(AppSettings(store: UserDefaults(suiteName: "r7reuse-\(UUID())")!).reuseLastProjectSettings)
    }
    @Test func initialLookPrecedence() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "r7-look-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func make(_ name: String, padding: Double?) throws -> (URL, Project) {
            let u = dir.appending(path: name, directoryHint: .isDirectory)
            let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/synthetic/basic.yapcam")
            try FileManager.default.copyItem(at: fixture, to: u)
            let p = try Project.create(package: u)
            if let padding { try p.apply(.set(path: "canvas.padding", value: .number(padding))); try p.save() }
            return (u, p)
        }
        func padding(_ p: Project) -> Double {
            let j = (try? JSONSerialization.jsonObject(with: p.snapshot().toJSON())) as? [String: Any]
            return ((j?["canvas"] as? [String: Any])?["padding"] as? NSNumber)?.doubleValue ?? -1
        }
        let (lastURL, _) = try make("Last.yapcam", padding: 0.31)
        // a preset marked as default (padding 0.62)
        let presetDir = dir.appending(path: "presets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: presetDir, withIntermediateDirectories: true)
        let store = YapcamEditor.PresetStore(directory: presetDir, defaults: UserDefaults(suiteName: "r7presets-\(UUID())")!)
        let (_, src) = try make("Src.yapcam", padding: 0.62)
        try src.exportPreset(to: store.url("Mine"))

        // 1. default preset + option on: the preset wins
        let (a, pa) = try make("A.yapcam", padding: nil)
        store.defaultName = "Mine"
        ProjectActions.applyInitialLook(to: pa, package: a, reuseLast: true, in: dir, presets: store)
        #expect(abs(padding(pa) - 0.62) < 0.001)
        // 2. no default preset + option on: the last project's look
        store.defaultName = nil
        let (b, pb) = try make("B.yapcam", padding: nil)
        let only = dir.appending(path: "only-last", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: only, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: lastURL, to: only.appending(path: "Last.yapcam"))
        ProjectActions.applyInitialLook(to: pb, package: b, reuseLast: true, in: only, presets: store)
        #expect(abs(padding(pb) - 0.31) < 0.001)                   // taken from the earlier project, not the preset
        // 3. option off, no default preset: standard look
        let (c, pc) = try make("C.yapcam", padding: nil)
        let standard = padding(pc)
        ProjectActions.applyInitialLook(to: pc, package: c, reuseLast: false, in: dir, presets: store)
        #expect(padding(pc) == standard)
    }

    // S-01 / S-02
    @Test func fileMenuHasSaveAndOpenRecent() {
        _ = NSApplication.shared
        let menu = MainMenu.build(target: AppDelegate())
        let file = menu.items.first { $0.submenu?.title == "File" }?.submenu
        let save = file?.items.first { $0.title == "Save" }
        #expect(save?.keyEquivalent == "s" && save?.keyEquivalentModifierMask == .command)
        #expect(save?.action == #selector(AppDelegate.saveProject))
        let recent = file?.items.first { $0.title == "Open Recent" }
        #expect(recent?.submenu?.delegate != nil)
        #expect(file?.items.contains { $0.title == "Save As…" } == true)
    }
    @Test func projectsOpenedAreReportedToTheRecentsUnlessIsolated() {
        let saved = RecentDocuments.note; defer { RecentDocuments.note = saved }
        var noted: [URL] = []
        RecentDocuments.note = { noted.append($0) }
        let u = URL(fileURLWithPath: "/tmp/fixture/A.yapcam")
        RecentDocuments.noteOpened(u, isolated: true)
        #expect(noted.isEmpty)
        RecentDocuments.noteOpened(u, isolated: false)
        #expect(noted == [u])
    }
    @Test func openRecentMenuListsExistingProjectsNewestFirstMax10AndClears() {
        let saved = (RecentDocuments.list, RecentDocuments.clear); defer { (RecentDocuments.list, RecentDocuments.clear) = saved }
        let urls = (0..<14).map { URL(fileURLWithPath: "/tmp/fixture/P\($0).yapcam") }
        RecentDocuments.list = { urls }
        var cleared = false
        RecentDocuments.clear = { cleared = true }
        let menu = NSMenu(); OpenRecentMenuDelegate.shared.menuNeedsUpdate(menu)
        #expect(RecentDocuments.visible(urls, exists: { _ in true }).count == 10)
        #expect(RecentDocuments.visible(urls, exists: { $0 != urls[0] }).first == urls[1])
        // none of the fixture paths exist: the menu says so and Clear Menu is disabled
        #expect(menu.items.first?.title == "No Recent Recordings" && menu.items.last?.isEnabled == false)
        _ = cleared
    }
    @Test func choosingAMovedProjectAlertsAndDropsIt() {
        let saved = (RecentDocuments.list, RecentDocuments.clear, RecentDocuments.note, RecentDocuments.exists)
        defer { (RecentDocuments.list, RecentDocuments.clear, RecentDocuments.note, RecentDocuments.exists) = saved }
        let gone = URL(fileURLWithPath: "/tmp/fixture/Gone.yapcam"), kept = URL(fileURLWithPath: "/tmp/fixture/Kept.yapcam")
        var stored = [gone, kept]
        RecentDocuments.list = { stored }
        RecentDocuments.clear = { stored = [] }
        RecentDocuments.note = { stored.insert($0, at: 0) }
        RecentDocuments.exists = { $0 == kept }
        var opened: [URL] = []
        #expect(!RecentDocuments.choose(gone, open: { opened.append($0) }))
        #expect(opened.isEmpty && stored == [kept] && RecordingController.shared.alert != nil)
        RecordingController.shared.alert = nil
        #expect(RecentDocuments.choose(kept, open: { opened.append($0) }) && opened == [kept])
    }

    // S-15
    @Test func exportMenuHoldsEditorExportsAndQuickExport() {
        _ = NSApplication.shared
        let menu = MainMenu.build(target: AppDelegate())
        let exp = menu.items.first { $0.submenu?.title == "Export" }?.submenu
        #expect(exp?.items.map(\.title).filter { !$0.isEmpty } == ["Export…", "Export to File…", "Copy to Clipboard", "Recent Clipboard Copies",
                                                                  "Quick Export: Copy to Clipboard", "Quick Export: Save to File…"])
        let first = exp?.items.first
        #expect(first?.keyEquivalent == "e" && first?.keyEquivalentModifierMask == [.command, .shift])
        let rec = menu.items.first { $0.submenu?.title == "Recording" }?.submenu
        #expect(rec?.items.contains { $0.title.hasPrefix("Quick Export") } == false)
        #expect(ExportMenuState.enabled(hasEditor: true, exportRunning: false))
        #expect(!ExportMenuState.enabled(hasEditor: false, exportRunning: false) && !ExportMenuState.enabled(hasEditor: true, exportRunning: true))
        // with no editor in front the editor items are greyed out
        let d = AppDelegate()
        #expect(exp?.items.first.map { d.validateMenuItem($0) } == (EditorBridge.keyEditor() != nil))
    }

    // S-11
    @Test func presetFileTypeIsDeclaredAndAcceptedByThePanels() throws {
        _ = NSApplication.shared
        let ext = try #require(UTType(filenameExtension: "yapcampreset"))
        #expect(PresetFileType.openTypes.contains { ext.conforms(to: $0) })
        #expect(PresetFileType.isPreset(URL(fileURLWithPath: "/tmp/fixture/A.yapcampreset")) && !PresetFileType.isPreset(URL(fileURLWithPath: "/tmp/fixture/A.mov")))
        let plist = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources/Info.plist")
        let info = try #require(NSDictionary(contentsOf: plist) as? [String: Any])
        let exported = (info["UTExportedTypeDeclarations"] as? [[String: Any]]) ?? []
        let preset = exported.first { $0["UTTypeIdentifier"] as? String == "mov.yapcam.preset" }
        #expect(preset != nil && (preset?["UTTypeConformsTo"] as? [String])?.contains("public.json") == true)
        let docs = (info["CFBundleDocumentTypes"] as? [[String: Any]]) ?? []
        #expect(docs.contains { ($0["LSItemContentTypes"] as? [String])?.contains("mov.yapcam.preset") == true })
        let menu = MainMenu.build(target: AppDelegate())
        let file = menu.items.first { $0.submenu?.title == "File" }?.submenu
        #expect(file?.items.contains { $0.title == "Import Preset…" } == true)
    }

    // B-06
    @Test func cleanVoiceOnRecordTurnsOnTheProjectsVoiceCleanup() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "r7-voice-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/synthetic/basic.yapcam")
        func enhanced(_ name: String, _ on: Bool) throws -> Bool {
            let u = dir.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.copyItem(at: fixture, to: u)
            let p = try Project.create(package: u)
            ProjectActions.applyRecordTimeAudio(to: p, cleanVoice: on)
            let j = try JSONSerialization.jsonObject(with: p.snapshot().toJSON()) as? [String: Any]
            return ((j?["audio"] as? [String: Any])?["speech_enhancement"] as? Bool) ?? false
        }
        #expect(try enhanced("On.yapcam", true))
        #expect(try !enhanced("Off.yapcam", false))
        let s = AppSettings(store: UserDefaults(suiteName: "r7voice-\(UUID())")!)
        #expect(!s.cleanVoiceOnRecord)
        s.cleanVoiceOnRecord = true; s.resetToDefaults()
        #expect(!s.cleanVoiceOnRecord)
    }

    // B-10
    @Test func windowMenuGroupsByAppAndFiltersOwnAndTinyWindows() {
        func row(_ id: UInt32, _ pid: Int32, _ app: String, _ title: String, w: CGFloat = 800, h: CGFloat = 600, layer: Int = 0) -> WindowRow {
            WindowRow(id: id, pid: pid, layer: layer, app: app, title: title, bounds: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let rows = [row(1, 10, "Safari", "Docs"), row(2, 10, "Safari", ""), row(3, 20, "Notes", "Todo"), row(4, 99, "Yapcam", "Own"),
                    row(5, 30, "Tiny", "x", w: 60, h: 40), row(6, 40, "Menubar", "m", layer: 25), row(7, 50, "Hidden", "h")]
        let g = WindowMenu.groups(rows: rows, allowed: nil, excludingPID: 99, ignoring: [7])
        #expect(g.map(\.app) == ["Notes", "Safari"])
        #expect(g.last?.rows.map(\.id) == [1, 2])
        #expect(WindowMenu.title(rows[1]) == "Safari" && WindowMenu.title(rows[0]) == "Docs")
        #expect(WindowMenu.groups(rows: rows, allowed: [3], excludingPID: 99).map(\.app) == ["Notes"])
    }

    // S-EDT-83 / 84
    private var fixturePackage: URL { URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/synthetic/basic.yapcam") }

    @Test func extractPlanListsOneTrackPerFileInSegmentOrder() {
        let all = RawExtract.plan(package: fixturePackage)
        #expect(all.map(\.outputName) == ["Screen.mov", "System audio.m4a"])
        #expect(all.allSatisfy { $0.sources.count == 2 && $0.sources[0].path.contains("seg-000") && $0.sources[1].path.contains("seg-001") })
        #expect(RawExtract.plan(package: fixturePackage, screenOnly: true).map(\.outputName) == ["Screen.mov"])
        #expect(RawExtract.plan(package: URL(fileURLWithPath: "/tmp/fixture/none.yapcam")).isEmpty)
    }
    @Test func extractJoinsSegmentsWithoutReencoding() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "r7-extract-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracks = RawExtract.plan(package: fixturePackage, screenOnly: true)
        try await RawExtract.run(tracks, into: dir)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["Screen.mov"])      // 1 file
        var total = 0.0
        for src in tracks[0].sources { total += try await AVURLAsset(url: src).load(.duration).seconds }
        let out = AVURLAsset(url: dir.appending(path: "Screen.mov"))
        let joined = try await out.load(.duration).seconds
        #expect(abs(joined - total) < 0.1)
        func codec(_ a: AVURLAsset) async throws -> FourCharCode? {
            let t = try await a.loadTracks(withMediaType: .video).first
            let fd = try await t?.load(.formatDescriptions).first
            return fd.map { CMFormatDescriptionGetMediaSubType($0) }
        }
        let original = try await codec(AVURLAsset(url: tracks[0].sources[0]))
        #expect(original != nil)
        #expect(try await codec(out) == original)
    }
    @Test func extractCancelAndEmptyPlanThrow() async {
        let dir = FileManager.default.temporaryDirectory.appending(path: "r7-extract-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: RawExtract.ExtractError.self) { try await RawExtract.run([], into: dir) }
        await #expect(throws: RawExtract.ExtractError.self) { try await RawExtract.run(RawExtract.plan(package: fixturePackage), into: dir, isCancelled: { true }) }
    }

    // S-09
    @Test func closingTheWidgetAsksOnlyAfterAnExportAndNeverWhileRunning() {
        typealias R = QuickExportCloseRule
        func d(_ st: QuickExport.State, keep: Bool = false, pkg: Bool = true, editor: Bool = false) -> R.Decision {
            R.decide(state: st, alwaysKeep: keep, hasPackage: pkg, openInEditor: editor)
        }
        #expect(d(.done("Copied")) == .askKeepOrTrash)
        #expect(d(.done("Saved"), keep: true) == .justClose)         // the setting turns the question off
        #expect(d(.idle) == .justClose && d(.failed("x")) == .justClose)    // closing without having exported asks nothing
        #expect(d(.working(0.4)) == .justClose)                      // never trash while an export runs
        #expect(d(.done("Copied"), pkg: false) == .justClose)
        #expect(d(.done("Copied"), editor: true) == .justClose)      // Edit opened it: it stays
    }
    @Test func alwaysKeepSettingDefaultsOffAndResets() {
        let s = AppSettings(store: UserDefaults(suiteName: "r7keep-\(UUID())")!)
        #expect(!s.alwaysKeepProjectAfterQuickExport)
        s.alwaysKeepProjectAfterQuickExport = true; s.resetToDefaults()
        #expect(!s.alwaysKeepProjectAfterQuickExport)
    }

    // addendum: confirm before quitting while an export runs
    @Test func quitIsGuardedWhileAnyExportRuns() {
        #expect(QuitGuard.exportRunning(quick: .working(0.3), editors: []))
        #expect(QuitGuard.exportRunning(quick: .idle, editors: [false, true]))
        #expect(!QuitGuard.exportRunning(quick: .done("x"), editors: [false]))
        #expect(!QuitGuard.exportRunning(quick: .idle, editors: []))
        let saved = QuitGuard.confirmQuit; defer { QuitGuard.confirmQuit = saved }
        var asked = 0
        QuitGuard.confirmQuit = { asked += 1; return false }
        #expect(!QuitGuard.shouldBlockQuit() && asked == 0)       // nothing exporting here: no question
    }

    // P2: B-11 / B-12 / B-13 / B-16
    @Test func hidingControlsAppliesToOneTakeOnly() {
        let rec = RecordingController.shared
        rec.debugSetPhase(.recording)
        rec.hideControlsForTake()
        #expect(rec.widgetHiddenForTake)
        #expect(AppSettings.shared.showRecordingWidget)          // the setting is untouched
        rec.debugSetPhase(.idle)
        #expect(!rec.widgetHiddenForTake)
        rec.hideControlsForTake()                                 // idle: nothing to hide
        #expect(!rec.widgetHiddenForTake)
    }
    @Test func menuBarIconOpensThePickerWhenIdle() {
        typealias M = MenuBarClick
        #expect(M.action(phase: .idle, rightClick: false, optionHeld: false) == .showPicker)
        #expect(M.action(phase: .idle, rightClick: true, optionHeld: false) == .showMenu)
        #expect(M.action(phase: .idle, rightClick: false, optionHeld: true) == .showMenu)
        #expect(M.action(phase: .recording, rightClick: false, optionHeld: false) == .toggleRecording)
        #expect(M.action(phase: .paused, rightClick: true, optionHeld: false) == .toggleRecording)
    }
    @Test func displayCardShowsPoints() {
        let d = DisplayInfo(id: 1, name: "X", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
        #expect(d.detail.hasPrefix("1512×982") && d.pixelDetail.hasPrefix("3024×1964"))
    }
    @Test func diagnosticsListsMachineAndDevices() {
        let info = SystemInfo(model: "Mac14,5", chip: "Apple M2 Max", memoryGB: 32, architecture: "arm64",
                              cameras: ["FaceTime HD"], microphones: ["MacBook Mic", "USB Mic"], defaultMicrophone: "MacBook Mic")
        let t = ProjectActions.diagnosticsText(system: info)
        for part in ["Model: Mac14,5", "Chip: Apple M2 Max", "Memory: 32 GB", "Cameras: FaceTime HD", "Microphones: MacBook Mic, USB Mic (default: MacBook Mic)", "no recordings"] {
            #expect(t.contains(part), "missing \(part)")
        }
        #expect(SystemInfo.current().memoryGB > 0)
    }

    // S-EDT-76
    @Test func keepQuestionOnlyForFreshRecordingsClosedQuickly() {
        typealias G = FirstCloseGuard
        #expect(G.shouldAsk(enabled: true, wasFresh: true, openFor: 4))
        #expect(!G.shouldAsk(enabled: false, wasFresh: true, openFor: 4))       // off by default
        #expect(!G.shouldAsk(enabled: true, wasFresh: false, openFor: 4))       // an older project
        #expect(!G.shouldAsk(enabled: true, wasFresh: true, openFor: 11))
        #expect(!AppSettings(store: UserDefaults(suiteName: "r7first-\(UUID())")!).askKeepOnFirstClose)
    }
}
