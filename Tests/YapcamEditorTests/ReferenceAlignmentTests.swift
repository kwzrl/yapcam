import Testing
import Foundation
import AppKit
import YapcamCore
@testable import YapcamEditor

@MainActor @Suite struct InspectorSectionOrderTests {
    @Test func orderAndShortcutsFollowTheReference() {
        let titles = InspectorSection.allCases.map(\.title)
        #expect(Array(titles.prefix(9)) == ["Background", "Cursor", "Camera layout", "Camera style", "Captions", "Edit by transcript", "Audio", "Keyboard shortcuts", "Animations"])
        #expect(InspectorSection.allCases.last == .extras)                       // our extras come after the reference sections
        #expect(InspectorSection.allCases.map { String($0.shortcutDigit) }.joined() == "1234567890")
    }

    @Test func sectionsAreOnlyShownWhenTheirInputExists() {
        let p = FakeProject(); let m = EditorModel(project: p, player: FakePlayer())
        // 0.11.0 hides the "Text, regions & intro/outro" panel (ReleaseScope).
        #expect(m.availableSections.count == 9)
        p.hasCamera = false; p.hasMic = false; p.hasMouseData = false; p.hasKeystrokes = false
        #expect(m.availableSections == [.background, .audio, .animations])
        p.hasCamera = true
        #expect(m.availableSections.contains(.cameraLayout) && m.availableSections.contains(.cameraStyle))
        m.set("camera.visible", bool: false)
        #expect(m.availableSections.contains(.cameraLayout) && !m.availableSections.contains(.cameraStyle))   // hidden camera: no style section
        p.hasMic = true; #expect(m.availableSections.contains(.captions) && m.availableSections.contains(.transcript))
        p.hasKeystrokes = true; #expect(m.availableSections.contains(.keys))
    }

    @Test func commandDigitsSelectSectionsAndSkipMissingOnes() {
        let p = FakeProject(); let m = EditorModel(project: p, player: FakePlayer())
        #expect(m.handleShortcut("2", .command) && m.inspectorSection == .cursor)
        #expect(m.handleShortcut("9", .command) && m.inspectorSection == .animations)
        #expect(!m.selectInspector(digit: "0"))   // the hidden panel has no shortcut in 0.11.0
        p.hasCamera = false
        m.inspectorSection = .background
        #expect(!m.handleShortcut("3", .command) && m.inspectorSection == .background)     // no camera → ⌘3 does nothing
        m.addZoomAtPlayhead()
        m.inspectorSection = .cursor; m.selection = .zoom(m.zooms[0].id)
        #expect(m.handleShortcut("1", .command) && m.inspectorSection == .background && m.selection == .none)   // leaves the item inspector
    }
}

@MainActor @Suite struct AspectPresetTests {
    @Test func referenceAspectsOnly() {
        #expect(AspectPreset.allCases.map(\.rawValue) == ["source", "16:9", "1:1", "4:3", "9:16", "3:4", "4:5"])
        #expect(AspectPreset.allCases.map(\.label) == ["Auto", "Wide 16:9", "Square 1:1", "Classic 4:3", "Vertical 9:16", "Tall 3:4", "Portrait 4:5"])
        #expect(AspectPreset.tall.outputSize == [1080, 1440] && AspectPreset.portrait.outputSize == [1080, 1350] && AspectPreset.auto.outputSize == nil)
    }
    @Test func autoKeepsTheOutputSizeAndPresetsSetIt() {
        let m = EditorModel(project: FakeProject(), player: FakePlayer())
        m.setAspect(.portrait); #expect(m.string("canvas.aspect") == "4:5" && m.numbers("canvas.output_size") == [1080, 1350])
        m.setAspect(.auto); #expect(m.string("canvas.aspect") == "source" && m.numbers("canvas.output_size") == [1080, 1350])
    }
    @Test func realCoreRendersEveryAspect() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("asp-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        for a in AspectPreset.allCases {
            m.setAspect(a); #expect(m.lastError == nil, "\(a): \(m.lastError ?? "")")
            let g = try #require(m.project.frameGeometry(atNs: 500_000_000))
            if let size = a.outputSize { #expect(abs(g.canvasWidth / g.canvasHeight - size[0] / size[1]) < 0.01, "\(a): \(g.canvasWidth)x\(g.canvasHeight)") }
            else { #expect(g.canvasWidth > 0 && g.canvasHeight > 0) }
        }
    }
}

@MainActor @Suite struct ReferenceKeyMapTests {
    private func make() -> (EditorModel, FakeProject) {
        let p = FakeProject(durationNs: 20_000_000_000); return (EditorModel(project: p, player: FakePlayer()), p)
    }

    @Test func cSplitsTheClipOrTheSelectedItem() {
        let (m, _) = make()
        m.seek(toNs: 8_000_000_000); #expect(m.handleShortcut("c")); #expect(m.clips.count == 2)
        m.seek(toNs: 2_000_000_000); m.addZoomAtPlayhead()                           // zoom 2.0–5.0 s (3 s like the reference), selected
        m.seek(toNs: 3_000_000_000); #expect(m.handleShortcut("c"))
        #expect(m.zooms.count == 2 && m.zooms.map(\.startNs).sorted() == [2_000_000_000, 3_000_000_000] && m.clips.count == 2)
        m.undo(); #expect(m.zooms.count == 1)                                         // one undo step
        m.selection = .zoom(m.zooms[0].id)
        m.seek(toNs: 5_000_000_000); m.handleShortcut("c"); #expect(m.lastError != nil && m.zooms.count == 1)   // at the end: too short
    }

    @Test func xRemovesFromThePreviousCutToThePlayhead() {
        let (m, _) = make()
        m.seek(toNs: 8_000_000_000); m.splitAtPlayhead()
        m.seek(toNs: 12_000_000_000); #expect(m.handleShortcut("x"))
        #expect(m.durationNs == 16_000_000_000 && m.playheadNs == 8_000_000_000)      // 8–12 s removed
        m.seek(toNs: 5_000_000_000); m.handleShortcut("x")                           // no cut before: from the start
        #expect(m.durationNs == 11_000_000_000)
    }

    @Test func speedMenuUsesTheFixedListAndAppliesToAll() {
        let (m, _) = make()
        #expect(clipSpeedOptions == [0.5, 0.75, 1, 1.2, 1.4, 1.6, 1.8, 2, 3, 4, 8, 16, 24])
        m.seek(toNs: 10_000_000_000); m.splitAtPlayhead()
        m.seek(toNs: 12_000_000_000)
        #expect(m.handleShortcut("s") && m.speedMenuVisible && m.speedTargetClip?.id == m.clips[1].id)    // clip under the playhead
        m.setSpeedOfTarget(2); #expect(m.clips[1].speed == 2 && m.clips[0].speed == 1)
        m.applySpeedToAll(1.4); #expect(m.clips.allSatisfy { $0.speed == 1.4 })
        m.undo(); #expect(m.clips[1].speed == 2 && m.clips[0].speed == 1)             // all clips in one undo step
    }

    @Test func volumeMenuSetsTheTargetClipsAmplitude() {
        let (m, _) = make()
        m.seek(toNs: 10_000_000_000); m.splitAtPlayhead(); m.seek(toNs: 12_000_000_000)                     // playhead in the second clip
        #expect(m.handleShortcut("v") && m.volumeMenuVisible && !m.volumeMenuSystem)
        m.handleShortcut("v", .control); #expect(m.volumeMenuSystem)
        m.setVolume(percent: 50, system: false)
        #expect(m.clips[1].micGain == 0.5 && m.clips[0].micGain == 1 && m.volumePercent(system: false) == 50)
        m.setVolume(percent: 0, system: true); #expect(m.clips[1].systemGain == 0 && m.volumePercent(system: true) == 0)
        m.setVolume(percent: 250, system: false); #expect(m.clips[1].micGain == 1)                          // clamped to 100 %
        m.undo(); #expect(m.clips[1].micGain == 0.5)
        m.setClipCursor(hide: true, smoothingOff: true); #expect(m.clips[1].hideCursor && m.clips[1].disableSmoothing && !m.clips[0].hideCursor)
    }

    @Test func realCoreStoresClipSettingsAndSplitsInheritThem() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cs2-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        m.setVolume(percent: 40, system: true); m.setClipCursor(hide: true)
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        #expect(abs(m.clips[0].systemGain - 0.4) < 1e-9 && m.clips[0].hideCursor)
        m.seek(toNs: 2_000_000_000); m.splitAtPlayhead()
        #expect(m.clips.count == 2 && m.clips.allSatisfy { abs($0.systemGain - 0.4) < 1e-9 && $0.hideCursor })   // splits inherit settings
        m.saveNow(); m.close()
        let again = try EditorDocument(package: d).model
        #expect(again.clips.allSatisfy { abs($0.systemGain - 0.4) < 1e-9 && $0.hideCursor })                     // saved and reopened
    }

    @Test func zoomKeysOnlyActOnASelectedZoom() {
        let (m, _) = make()
        #expect(!m.handleShortcut("a") && !m.handleShortcut("9") && !m.handleShortcut("="))      // 2…8 toggle timelines
        m.addZoomAtPlayhead(); let id = m.zooms[0].id
        #expect(m.handleShortcut("a") && m.zooms[0].mode == .auto); #expect(m.handleShortcut("m") && m.zooms[0].mode == .manual)
        #expect(m.handleShortcut("d") && !m.zooms[0].enabled); m.handleShortcut("d"); #expect(m.zooms[0].enabled)
        m.handleShortcut("1"); #expect(m.zooms[0].scale == 1.0); m.handleShortcut("9"); #expect(abs(m.zooms[0].scale - 2.6) < 1e-9)
        m.handleShortcut("0"); #expect(m.zooms[0].scale == 2.0)
        m.handleShortcut("="); #expect(abs(m.zooms[0].scale - 2.2) < 1e-9); m.handleShortcut("-"); m.handleShortcut("-"); #expect(abs(m.zooms[0].scale - 1.8) < 1e-9)
        for _ in 0..<40 { m.handleShortcut("=") }; #expect(m.zooms[0].scale == 4.0)                    // capped at 400 %
        m.handleShortcut("d", .command); #expect(m.zooms.count == 2 && m.selection != .zoom(id))     // duplicate selects the copy
        m.applyZoomLevelToAll(); #expect(m.zooms.allSatisfy { $0.scale == m.selectedZoom!.scale })
    }

    @Test func copyAndPasteSettingsBetweenItems() {
        let (m, _) = make()
        m.seek(toNs: 1_000_000_000); m.addZoomAtPlayhead(); m.seek(toNs: 10_000_000_000); m.addZoomAtPlayhead()
        let a = m.zooms[0], b = m.zooms[1]
        m.selection = .zoom(a.id); m.setZoomScale(id: a.id, 3.2); m.setZoomEase(id: a.id, inNs: 0, outNs: 0)
        var framesCopied = 0; m.copyFrameHandler = { framesCopied += 1 }
        #expect(m.handleShortcut("c", .command) && framesCopied == 1)                 // S-EDT-60: ⌘C copies the frame even with a zoom selected
        m.apply(.copySettings(.zoom(a.id)))                                           // settings are copied from the context menu
        m.selection = .zoom(b.id); #expect(m.handleShortcut("v", .command))
        #expect(m.zooms[1].scale == 3.2 && m.zooms[1].easeInNs == 0)
        m.selection = .none; var copied = 0
        m.copyFrameHandler = { copied += 1 }
        m.handleShortcut("c", .command); #expect(copied == 1)                         // nothing selected: copies the frame
        m.selection = .clip(m.clips[0].id); m.setSpeed(clipID: m.clips[0].id, 4); m.handleShortcut("c", .command); #expect(copied == 2); m.apply(.copySettings(.clip(m.clips[0].id)))
        m.selection = .zoom(a.id); #expect(!m.handleShortcut("v", .command))         // kinds must match
    }

    @Test func timelineZoomWindowStaysBetweenTwoSecondsAndTenMinutes() {
        let (m, _) = make(); m.timelineViewportWidth = 1000
        for _ in 0..<40 { m.handleShortcut("=", .command) }
        #expect(abs(m.geometry.pixelsPerSecond - 500) < 1e-6)                         // 1000 pt / 2 s
        for _ in 0..<60 { m.handleShortcut("-", .command) }
        #expect(abs(m.geometry.pixelsPerSecond - 1000 / 20) < 1e-6)                   // whole 20 s project
        let long = EditorModel(project: FakeProject(durationNs: 3 * 3600 * 1_000_000_000), player: FakePlayer()); long.timelineViewportWidth = 1000
        for _ in 0..<80 { long.handleShortcut("-", .command) }
        #expect(abs(long.geometry.pixelsPerSecond - 1000 / 600) < 1e-6)               // capped at a 10-minute window
    }

    @Test func playbackAndInspectorKeysStillWork() {
        let (m, _) = make()
        #expect(m.handleShortcut("z") && m.zooms.count == 1)
        #expect(m.handleShortcut("k", .command) && m.paletteVisible)
        m.seek(toNs: 5_000_000_000); #expect(m.handleShortcut("l") && m.isPlaying); #expect(m.handleShortcut("k") && !m.isPlaying)
        #expect(!m.handleShortcut("q") && !m.handleShortcut("a", [.command]))
    }
}

@MainActor @Suite struct AnimationPresetTests {
    @Test func presetsUseTheReferenceValues() {
        #expect(SpringPreset.screen.map { [$0.stiffness, $0.damping, $0.mass] } == [[250, 40, 2.25], [170, 50, 3]])
        #expect(SpringPreset.cursor.map { [$0.stiffness, $0.damping, $0.mass] } == [[470, 70, 3], [340, 60, 3], [530, 40, 1]])
    }
    @Test func cursorSectionAndAnimationsShareOnePreset() {      // BS-2
        let m = EditorModel(project: FakeProject(), player: FakePlayer())
        m.chooseCursorAnimation("rapid"); #expect(m.activePreset(screen: false) == "rapid")
        m.chooseCursorAnimation("none"); #expect(m.activePreset(screen: false) == "none")
        m.chooseCursorAnimation("bogus"); #expect(m.activePreset(screen: false) == "none")
    }
    @Test func choosingAPresetWritesTheSpringAndMarksItActive() {
        let m = EditorModel(project: FakeProject(), player: FakePlayer())
        let smooth = SpringPreset.screen[1]
        m.setSpring(screen: true, stiffness: smooth.stiffness, damping: smooth.damping, mass: smooth.mass, preset: smooth.id)
        #expect(m.activePreset(screen: true) == "smooth" && m.string("zoom_settings.animation_style") == "smooth")   // BS-4: not forced to custom
        m.setSpring(screen: true, stiffness: 200, damping: 50, mass: 3)
        #expect(m.string("zoom_settings.animation_style") == "custom")                                              // hand-tuned values
        m.undo()
        m.setSpring(screen: false, stiffness: 340, damping: 60, mass: 3)
        #expect(m.activePreset(screen: false) == "medium" && m.number("cursor.smoothing") == 0.15)       // smoothing switched on
        m.setCursorAnimationNone(); #expect(m.activePreset(screen: false) == "none")
        m.undo(); #expect(m.activePreset(screen: false) == "medium")
        m.setSpring(screen: true, stiffness: 9999, damping: 1, mass: 99)                                  // clamped to what core accepts
        #expect(m.springValues(screen: true) == (600, 5, 10) && m.activePreset(screen: true) == nil)
    }
    @Test func realCoreAcceptsEveryPresetAndTheMassCap() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("anim-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        for p in SpringPreset.screen { m.setSpring(screen: true, stiffness: p.stiffness, damping: p.damping, mass: p.mass); #expect(m.lastError == nil, "\(m.lastError ?? "")") }
        for p in SpringPreset.cursor { m.setSpring(screen: false, stiffness: p.stiffness, damping: p.damping, mass: p.mass); #expect(m.lastError == nil, "\(m.lastError ?? "")") }
        m.setSpring(screen: true, stiffness: 100, damping: 30, mass: 15)
        #expect(m.lastError == nil && m.springValues(screen: true).mass == 10)
    }
}

@MainActor @Suite struct TranscriptEditingTests {
    private func model() -> EditorModel {
        let m = EditorModel(project: FakeProject(durationNs: 20_000_000_000), player: FakePlayer())
        let words: [(String, Int64, Int64)] = [("Hello", 1_000, 1_400), ("um", 1_500, 1_800), ("world", 1_900, 2_300), ("uh,", 4_000, 4_200), ("again", 5_500, 5_900)]
        for (i, w) in words.enumerated() {
            m.seek(toNs: 0)
            guard let id = m.addText(.caption, text: w.0) else { continue }
            m.updateText(.caption, id: id) { $0.startNs = w.1 * 1_000_000; $0.endNs = w.2 * 1_000_000 }
            _ = i
        }
        return m
    }

    @Test func wordsAreOrderedAndFillersDetected() {
        let m = model()
        #expect(m.transcriptWords.map(\.text) == ["Hello", "um", "world", "uh,", "again"])
        #expect(m.fillerWordCount == 2 && m.isFiller(m.transcriptWords[1]) && m.isFiller(m.transcriptWords[3]) && !m.isFiller(m.transcriptWords[0]))
    }
    @Test func deletingWordsCutsTheVideoInOneStep() {
        let m = model(); let dur = m.durationNs
        m.deleteWords(ids: [m.transcriptWords[1].id, m.transcriptWords[2].id])          // two cuts: 1.5–1.8 s and 1.9–2.3 s
        #expect(m.durationNs == dur - 300_000_000 - 400_000_000)
        m.undo(); #expect(m.durationNs == dur)
    }
    @Test func removeFillerWordsCutsAllOfThem() {
        let m = model(); let dur = m.durationNs
        m.removeFillerWords(); #expect(m.durationNs == dur - 300_000_000 - 200_000_000)
    }
    @Test func tightenPausesShortensLongGaps() {
        let m = model()
        let cuts = m.pauseCuts()                                                        // gaps: 2.3→4.0 (1.7 s) and 4.2→5.5 (1.3 s)
        #expect(cuts.count == 2 && cuts[0] == TimeSpan(startNs: 2_550_000_000, endNs: 4_000_000_000) && cuts[1] == TimeSpan(startNs: 4_450_000_000, endNs: 5_500_000_000))
        let dur = m.durationNs; m.tightenPauses()
        #expect(m.durationNs == dur - 1_450_000_000 - 1_050_000_000)
    }
    @Test func hideAndCorrectOnlyTouchTheCaption() {
        let m = model(); let dur = m.durationNs
        m.correctWord(id: m.transcriptWords[0].id, text: "Hallo"); #expect(m.transcriptWords[0].text == "Hallo")
        let hid = m.transcriptWords[1].id
        m.hideWord(id: hid); #expect(m.transcriptWords.count == 5 && m.durationNs == dur && m.isHidden(m.transcriptWords[1]))
        m.unhideWord(id: hid); #expect(!m.isHidden(m.transcriptWords[1]) && m.durationNs == dur)
    }
    @Test func cuttingEverythingIsRefused() {
        let m = EditorModel(project: FakeProject(durationNs: 2_000_000_000), player: FakePlayer())
        m.seek(toNs: 0); let id = m.addText(.caption, text: "all")!
        m.updateText(.caption, id: id) { $0.startNs = 0; $0.endNs = 2_000_000_000 }
        m.deleteWords(ids: [id]); #expect(m.lastError != nil && m.durationNs == 2_000_000_000)
    }
}

@MainActor @Suite struct TypingSuggestionTests {
    private func keys(from startMs: Int, count: Int, gapMs: Int) -> [Int64] { (0..<count).map { Int64(startMs + $0 * gapMs) * 1_000_000 } }

    @Test func detectionFollowsTheReferenceRules() {
        // 20 keys, 150 ms apart: 2.85 s long, 7 keys/s → a burst.
        #expect(TypingBursts.detect(keys(from: 1000, count: 20, gapMs: 150)) == [TimeSpan(startNs: 1_000_000_000, endNs: 3_850_000_000)])
        // a gap of 500 ms or more splits bursts
        let two = keys(from: 0, count: 14, gapMs: 150) + keys(from: 5000, count: 14, gapMs: 150)
        #expect(TypingBursts.detect(two).count == 2)
        // too short (< 1.5 s) is ignored; a 1.8 s run of 5 keys (gaps just under 500 ms) is a burst
        #expect(TypingBursts.detect(keys(from: 0, count: 8, gapMs: 150)).isEmpty)
        #expect(TypingBursts.detect(keys(from: 0, count: 4, gapMs: 490)).isEmpty)
        #expect(TypingBursts.detect(keys(from: 0, count: 5, gapMs: 450)).count == 1)
        // gaps of exactly 500 ms or more break the run, so single keys never form a suggestion
        #expect(TypingBursts.detect(keys(from: 0, count: 6, gapMs: 500)).isEmpty)
        #expect(TypingBursts.detect([]).isEmpty && TypingBursts.detect([1_000_000_000]).isEmpty)
    }

    @Test func suggestionsAppearOnTheTimelineAndApplyThroughCore() {
        let p = FakeProject(durationNs: 30_000_000_000)
        p.keyTimesNs = keys(from: 2000, count: 20, gapMs: 150) + keys(from: 12000, count: 20, gapMs: 150)
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let m = EditorModel(project: p, player: FakePlayer()); m.defaults = iso.defaults; m.presetStore = iso.store
        #expect(m.typingSuggestions.count == 2 && m.visibleLanes.contains(.typing))
        #expect(m.typingSpeed == 3)
        m.typingSpeed = 5
        m.applyTypingSuggestion(m.typingSuggestions[0])
        #expect(p.typingCommands == ["apply k2000000000 5.0"])                                  // by core's suggestion id
        m.applyAllTypingSuggestions()
        #expect(p.typingRuns == 1)
        m.typingSpeed = 99; #expect(m.typingSpeed == 8); m.typingSpeed = 0.1; #expect(m.typingSpeed == 1.5)
    }

    @Test func removedSuggestionsStayHiddenUntilRestored() {
        let p = FakeProject(durationNs: 30_000_000_000)
        p.keyTimesNs = keys(from: 2000, count: 20, gapMs: 150)
        let m = EditorModel(project: p, player: FakePlayer())
        let sp = m.typingSuggestions[0]
        m.dismissTypingSuggestion(sp); #expect(m.typingSuggestions.isEmpty && !m.visibleLanes.contains(.typing))
        m.set("canvas.padding", number: 3); #expect(m.typingSuggestions.isEmpty)                  // dismissal persists in the project
        m.restoreTypingSuggestions(); #expect(m.typingSuggestions.count == 1)
    }

    @Test func realCoreSpeedsUpTheChosenStretchOnly() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("typ-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        let before = m.durationNs
        m.applyTypingSuggestion(TimeSpan(startNs: 1_000_000_000, endNs: 3_000_000_000))      // default 3x → 2 s become 0.667 s
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        #expect(m.clips.count == 3 && m.clips[1].speed == 3 && abs(Double(before - m.durationNs) - 1.333e9) < 5e6)
        m.undo(); #expect(m.durationNs == before)                                             // one undo step
    }
}

@MainActor @Suite(.serialized) struct ReferenceControlTests {
    private func fixture() throws -> URL {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); return d
    }

    @Test func cameraPositionGridHasEightPointsWithoutACenter() {
        #expect(CameraPositionRow.xs.count == 3 && CameraPositionRow.ys.count == 3)
        let m = EditorModel(project: FakeProject(), player: FakePlayer())
        m.set("camera.position", .array([.number(CameraPositionRow.xs[2]), .number(CameraPositionRow.ys[0])]))
        #expect(m.numbers("camera.position") == [0.82, 0.22])
    }

    @Test func captionLookAppliesToAllCaptionsAndNewOnes() {
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let m = EditorModel(project: FakeProject(durationNs: 20_000_000_000), player: FakePlayer()); m.defaults = iso.defaults
        m.set("canvas.output_size", .array([.number(1920), .number(1000)]))
        m.addText(.caption, text: "a"); m.seek(toNs: 5_000_000_000); m.addText(.caption, text: "b")
        var look = CaptionLook(); look.size = 0.1; look.light = true; look.center = true
        m.setCaptionLook(look)
        for c in m.textItems(.caption) {
            #expect(c.fontSize == 100 && c.color == [0.08, 0.08, 0.08, 1] && c.background[3] > 0.8)
            #expect(abs(c.rect[1] + c.rect[3] / 2 - 0.5) < 1e-9)                      // centered
        }
        m.undo(); #expect(m.textItems(.caption).allSatisfy { $0.fontSize != 100 })      // one undo step for all captions
        m.redo()
        m.seek(toNs: 9_000_000_000); m.addText(.caption, text: "new")
        #expect(m.textItems(.caption).last?.fontSize == 100)                             // new captions follow the remembered look
        look.size = 5; look.light = false; look.center = false; m.setCaptionLook(look)
        #expect(m.textItems(.caption).allSatisfy { abs($0.fontSize - 0.125 * 1000) < 1e-9 && $0.rect[1] > 0.6 })   // clamped to 12.5 %, bottom
    }

    @Test func newRegionsInheritTheLastStyleAndApplyToAllWorks() {
        let m = EditorModel(project: FakeProject(durationNs: 30_000_000_000), player: FakePlayer())
        m.addHighlightAtPlayhead(kind: .highlight)
        #expect(m.highlights[0].dimOpacity == 0.5)                                       // reference default
        let first = m.highlights[0].id
        m.updateHighlight(id: first) { $0.dimOpacity = 0.8; $0.strokeWidth = 7; $0.stroke = [1, 0, 0, 1] }
        m.seek(toNs: 10_000_000_000); m.addHighlightAtPlayhead(kind: .highlight)
        #expect(m.highlights[1].dimOpacity == 0.8 && m.highlights[1].strokeWidth == 7 && m.highlights[1].stroke == [1, 0, 0, 1])
        m.seek(toNs: 20_000_000_000); m.addHighlightAtPlayhead(kind: .mask)
        #expect(m.highlights[2].kind == .mask && m.highlights[2].dimOpacity == 0)        // a different kind does not inherit
        m.updateHighlight(id: first) { $0.dimOpacity = 0.3 }
        m.applyHighlightStyleToAll(from: first)
        #expect(m.highlights[1].dimOpacity == 0.3 && m.highlights[2].dimOpacity == 0)    // only the same kind changes
    }

    @Test func presetManagementRenameUpdateMatchAndDefault() throws {
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let store = iso.store
        let p = FakeProject(), m = EditorModel(project: p, player: FakePlayer()); m.presetStore = store; m.defaults = iso.defaults
        let base = "ut-\(UUID().uuidString.prefix(6))"
        m.savePreset(named: base); #expect(store.names().contains(base))
        m.renamePreset(from: base, to: base + "-b")
        #expect(store.names().contains(base + "-b") && !store.names().contains(base))
        store.defaultName = base + "-b"
        m.renamePreset(from: base + "-b", to: base); #expect(store.defaultName == base)           // default follows a rename
        m.savePreset(named: base + "-b")
        m.renamePreset(from: base, to: base + "-b"); #expect(m.lastError != nil)                           // no overwrite on rename
        m.lastError = nil
        let before = try Data(contentsOf: store.url(base))
        m.updatePreset(named: base)
        let after = try Data(contentsOf: store.url(base))
        #expect(m.lastError == nil, "\(m.lastError ?? "")"); #expect(after == before)                    // fake exports "{}" both times
    }

    @Test func defaultPresetStartsNewProjects() throws {
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let store = iso.store
        let src = try fixture(); defer { try? FileManager.default.removeItem(at: src) }
        let name = "ut-def-\(UUID().uuidString.prefix(6))"
        let a = try EditorDocument(package: src, presets: store); a.model.set("canvas.padding", number: 91); a.model.set("canvas.radius", number: 40)
        a.model.savePreset(named: name)
        #expect(a.model.presetMatchesProject(named: name))                                              // "Matches project"
        a.model.set("canvas.padding", number: 50); #expect(!a.model.presetMatchesProject(named: name))
        a.model.updatePreset(named: name); #expect(a.model.presetMatchesProject(named: name))           // update to match
        a.model.close()
        store.defaultName = name
        let fresh = try fixture(); defer { try? FileManager.default.removeItem(at: fresh) }
        let b = try EditorDocument(package: fresh, presets: store)
        #expect(b.model.number("canvas.padding") == 50 && b.model.number("canvas.radius") == 40)        // new project starts from the default
        store.defaultName = nil
        let plain = try fixture(); defer { try? FileManager.default.removeItem(at: plain) }
        let plainPadding = try EditorDocument(package: plain, presets: store).model.number("canvas.padding")
        #expect(plainPadding == 48)
    }
}

@MainActor @Suite struct FactoryDefaultsContractTests {
    private func fixture() throws -> URL {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("fd-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); return d
    }

    /// New projects follow the documented table for their revision (this core's revision decides which one applies).
    @Test func newProjectsMatchTheDocumentedFactoryTable() throws {
        let d = try fixture(); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        let g = try #require(m.project.frameGeometry(atNs: 500_000_000))
        if m.defaultsRevision >= 1 {
            #expect(m.string("canvas.aspect") == "source" && g.canvasWidth == 1728 && g.canvasHeight == 1080)   // 320×200 recording → 1728×1080
            #expect(m.number("canvas.radius") == 16 && m.number("canvas.motion_blur") == 1 && m.number("canvas.background.blur") == 0)
            #expect(m.usesPaddingRatio && abs(m.number("canvas.padding_ratio") - 0.10) < 1e-9)
            #expect(abs(min(g.dest.minX, g.dest.minY) - 0.10 * min(g.canvasWidth, g.canvasHeight)) < 1.5)          // 108 px padding on the constraining axis (content is centered on the other)
            #expect(m.string("cursor.set_id") == "original" && m.string("cursor.click_effect") == "none")
            #expect(m.number("cursor.smoothing") == (m.defaultsRevision >= 4 ? 1 : 0))                       // revision 4: smooth cursor at full strength (BS-1)
            #expect(m.springValues(screen: true) == (70, 30, 3))                                            // 0.11.0: calmer zoom spring (#18)
        } else {
            #expect(m.string("canvas.aspect") == "16:9" && g.canvasWidth == 1920 && g.canvasHeight == 1080)
            #expect(m.number("canvas.radius") == 18 && m.number("canvas.motion_blur") == 0 && !m.usesPaddingRatio && m.number("canvas.padding") == 48)
            #expect(m.value("cursor.set_id") == .null || m.value("cursor.set_id") == nil)
            #expect(m.number("cursor.smoothing") == 0.15 && m.string("cursor.click_effect") == "ring")
        }
    }

    /// A project written by an older version has no revision and no new fields: it keeps the previous defaults.
    @Test func legacyProjectsKeepTheirPreviousDefaults() throws {
        let d = try fixture(); defer { try? FileManager.default.removeItem(at: d) }
        let first = try EditorDocument(package: d); first.model.saveNow(); first.model.close()
        let url = d.appendingPathComponent("project.json")
        var obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for k in ["canvas", "cursor", "zoom_settings", "audio", "defaults_revision"] { obj[k] = nil }           // as an older version wrote it
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        try? FileManager.default.removeItem(at: d.appendingPathComponent("project.json.prev"))
        let m = try EditorDocument(package: d).model
        let g = try #require(m.project.frameGeometry(atNs: 500_000_000))
        #expect(m.defaultsRevision == 0 && m.string("canvas.aspect") == "16:9" && g.canvasWidth == 1920 && g.canvasHeight == 1080)
        #expect(m.number("canvas.padding") == 48 && !m.usesPaddingRatio && m.number("canvas.radius") == 18 && m.number("cursor.smoothing") == 0.15)
        #expect(m.value("cursor.set_id") == .null || m.value("cursor.set_id") == nil)
    }

    @Test func controlsFollowTheProjectsDefaultStyle() {
        let m = EditorModel(project: FakeProject(), player: FakePlayer())
        #expect(!m.usesPaddingRatio && !m.hasShadowStyle && !m.usesCursorPoints && m.defaultsRevision == 0)
        #expect(m.factoryDefault(radius: true) == 18 && m.factoryDefault(backgroundBlur: true) == 24 && m.factoryMotionBlur == 0)
        m.set("defaults_revision", number: 1); m.set("canvas.padding_ratio", number: 0.1)
        m.set("canvas.shadow.style", string: "directional"); m.set("cursor.size_points", number: 48)
        #expect(m.usesPaddingRatio && m.hasShadowStyle && m.usesCursorPoints && m.defaultsRevision == 1)
        #expect(m.factoryDefault(radius: true) == 16 && m.factoryDefault(backgroundBlur: true) == 0 && m.factoryMotionBlur == 1)
    }
}


/// Tests and self-tests must never see or change the user's real presets, default-preset choice or remembered settings.
@MainActor @Suite struct StorageIsolationTests {
    @Test func testProcessesNeverUseTheRealLocations() {
        #expect(EditorStorage.isIsolatedProcess)
        #expect(EditorPresets.currentStore.directory.standardizedFileURL != EditorStorage.realPresetsDirectory.standardizedFileURL)
        #expect(EditorPresets.currentStore.directory.path.contains(NSTemporaryDirectory().trimmingCharacters(in: CharacterSet(charactersIn: "/")).prefix(8)) || EditorPresets.currentStore.directory.path.contains("yapcam-editor-isolated"))
        let sentinel = "isolation-\(UUID().uuidString)"
        EditorPresets.currentStore.defaults.set(sentinel, forKey: "yapcam.isolation.probe")
        #expect(UserDefaults.standard.string(forKey: "yapcam.isolation.probe") == nil)                   // not the user's domain
        EditorPresets.currentStore.defaults.removeObject(forKey: "yapcam.isolation.probe")
    }

    @Test func environmentVariableSelectsTheFolder() {
        setenv("YAPCAM_PRESETS_DIR", "/tmp/yapcam-env-presets-probe", 1); defer { unsetenv("YAPCAM_PRESETS_DIR") }
        #expect(EditorStorage.resolvedPresetsDirectory().path == "/tmp/yapcam-env-presets-probe")
    }

    @Test func eachStoreIsPrivate() throws {
        let a = EditorStorage.makeIsolated(), b = EditorStorage.makeIsolated(); defer { a.cleanup(); b.cleanup() }
        try FileManager.default.createDirectory(at: a.store.directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: a.store.url("only-in-a"))
        a.store.defaultName = "only-in-a"
        #expect(a.store.names() == ["only-in-a"] && b.store.names().isEmpty)
        #expect(b.store.defaultName == nil && EditorPresets.currentStore.defaultName != "only-in-a")
        a.cleanup()
        #expect(a.store.names().isEmpty)
    }

    @Test func isolatedModelsDoNotShareRememberedSettings() {
        let a = EditorStorage.makeIsolated(), b = EditorStorage.makeIsolated(); defer { a.cleanup(); b.cleanup() }
        let ma = EditorModel(project: FakeProject(), player: FakePlayer()), mb = EditorModel(project: FakeProject(), player: FakePlayer())
        ma.defaults = a.defaults; mb.defaults = b.defaults
        ma.typingSpeed = 6; var look = CaptionLook(); look.light = true; ma.captionLook = look
        #expect(mb.typingSpeed == 3 && !mb.captionLook.light && ma.typingSpeed == 6 && ma.captionLook.light)
    }
}

@MainActor @Suite struct CameraStyleTests {
    private func fixture() throws -> URL {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cs-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); return d
    }

    @Test func realCoreRecipesCustomLookCropAndRenderConfiguration() throws {
        let d = try fixture(); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d); let m = doc.model
        let recipes = m.project.cameraRecipes
        #expect(recipes.count == 12)
        m.set("camera.style.preset", string: recipes[0].id)
        #expect(m.lastError == nil && m.string("camera.style.preset") == recipes[0].id, "\(m.lastError ?? "")")
        m.set("camera.style.warmth", number: 0.5)                                       // editing a recipe value selects custom
        #expect(m.string("camera.style.preset") == "custom" && m.number("camera.style.warmth") == 0.5)
        m.set("camera.style.intensity", number: 0.4); m.set("camera.style.sharpen", number: 0.3); m.set("camera.style.grain", number: 0.2)
        m.set("camera.style.background_blur", number: 0.5)
        m.setCrop(path: "camera.style.crop", left: 0.1, top: 0.1, right: 0.2, bottom: 0.1)
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        let c = m.cropInsets(path: "camera.style.crop"); #expect(abs(c.left - 0.1) < 1e-9 && abs(c.right - 0.2) < 1e-9)
        // The editor's render source hands the style to render (preview and export snapshot).
        let src = ProjectRenderSource(doc.project)
        let cfg = try src.renderEffects(atNs: 500_000_000, canvasSize: CGSize(width: 1920, height: 1080)).configuration
        #expect(abs(cfg.cameraColor.warmth - 0.5) < 1e-5 && abs(cfg.cameraColor.intensity - 0.4) < 1e-5 && abs(cfg.cameraColor.sharpen - 0.3) < 1e-5)
        #expect(abs(cfg.cameraCrop.x - 0.1) < 1e-5 && abs(cfg.cameraBackgroundBlur - 0.5) < 1e-5)
        m.set("camera.style.preset", string: "original")
        #expect(try src.renderEffects(atNs: 500_000_000, canvasSize: CGSize(width: 1920, height: 1080)).configuration.cameraColor.warmth == 0)   // bypassed
        m.set("camera.style.warmth", number: 5); #expect(m.lastError != nil)           // out of range is rejected, state kept
    }

    @Test func lutImportThroughTheProject() throws {
        let d = try fixture(); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        var cube = "TITLE \"t\"\nLUT_3D_SIZE 2\n"
        for b in [0, 1] { for g in [0, 1] { for r in [0, 1] { cube += "\(r) \(g) \(b)\n" } } }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("l-\(UUID().uuidString).cube")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(cube.utf8).write(to: url)
        m.importCameraLUT(url)
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        #expect(m.string("camera.style.preset") == "lut")
        if case .string(let p)? = m.value("camera.style.lut_path") { #expect(p.hasPrefix("assets/")) } else { Issue.record("lut_path missing") }
        m.undo(); #expect(m.string("camera.style.preset") == "original")
        try Data("not a cube".utf8).write(to: url)
        m.importCameraLUT(url); #expect(m.lastError != nil)                              // invalid data: nothing changes
    }

    @Test func fakeFlowAndTilesAvailability() {
        let p = FakeProject(), m = EditorModel(project: p, player: FakePlayer())
        #expect(m.project.cameraRecipes.map(\.id) == ["warm-studio", "cool-daylight"])
        m.importCameraLUT(URL(fileURLWithPath: "/tmp/x.cube"))
        #expect(p.importedLUTs.count == 1 && m.string("camera.style.preset") == "lut")
    }
}

@MainActor @Suite struct CameraLayoutTests {
    private func fixture() throws -> URL {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cl-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: src, to: d); return d
    }

    @Test func realCoreAcceptsEveryLayoutSettingAndSegmentMode() throws {
        let d = try fixture(); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        let p = "camera.layout_settings."
        for mode in ["overlay", "cutout", "split"] { m.set(p + "mode", string: mode); #expect(m.lastError == nil, "\(mode): \(m.lastError ?? "")") }
        m.set(p + "aspect", .number(16.0 / 9)); m.set(p + "aspect", .null)
        m.set(p + "split_ratio", .number(0.5)); m.set(p + "split_ratio", .number(2.0 / 3)); m.set(p + "split_ratio", .null)
        m.set(p + "split_flip", bool: true); m.set(p + "split_padded", bool: true)
        m.set(p + "cutout_position", .array([.number(0.5), .number(1)])); m.set(p + "cutout_size", number: 0.4)
        m.set(p + "edge_softness", number: 0.5); m.set(p + "edge_inset", number: 3)
        m.set("camera.hide_during_silence", bool: true); m.set("camera.min_silence_ns", number: 6_000_000_000)
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        m.set(p + "cutout_size", number: 0.05); #expect(m.lastError != nil && m.number(p + "cutout_size") == 0.4)     // out of range: rejected, kept
        #expect(layoutModes.map(\.value).contains("cutout") && layoutModes.map(\.value).contains("split"))
    }

    @Test func silenceRangesAreStoredSortedForCore() async throws {
        let p = FakeProject(durationNs: 60_000_000_000)
        p.silences = [TimeSpan(startNs: 20_000_000_000, endNs: 26_000_000_000), TimeSpan(startNs: 5_000_000_000, endNs: 9_000_000_000), TimeSpan(startNs: 8_000_000_000, endNs: 10_000_000_000)]
        let m = EditorModel(project: p, player: FakePlayer())
        m.setHideDuringSilence(true); #expect(m.bool("camera.hide_during_silence"))
        await m.waitForCameraSilence()
        #expect(m.silenceRangesState == .idle && m.cameraSilenceCount == 2)                       // overlapping ones merged
        if case .array(let rows)? = m.value("camera.silence_ranges"), case .object(let first) = rows[0], case .number(let a)? = first["tl_start_ns"], case .number(let b)? = first["tl_end_ns"] {
            #expect(a == 5_000_000_000 && b == 10_000_000_000)
        } else { Issue.record("no ranges stored") }
        m.setHideDuringSilence(false); #expect(!m.bool("camera.hide_during_silence"))
    }

    @Test func realCoreTakesSilenceRangesAndMinimum() throws {
        let d = try fixture(); defer { try? FileManager.default.removeItem(at: d) }
        let m = try EditorDocument(package: d).model
        let rows: [JSONValue] = [.object(["tl_start_ns": .number(1_000_000_000), "tl_end_ns": .number(4_000_000_000)])]
        m.set("camera.silence_ranges", .array(rows)); m.set("camera.hide_during_silence", bool: true)
        #expect(m.lastError == nil && m.cameraSilenceCount == 1, "\(m.lastError ?? "")")
        m.set("camera.min_silence_ns", number: 1_000_000_000); #expect(m.lastError != nil)        // below the 2 s floor
    }

    @Test func closingCancelsTheAnalysis() async {
        let p = FakeProject(durationNs: 10_000_000_000); p.silenceDelay = .seconds(5)
        let m = EditorModel(project: p, player: FakePlayer())
        m.refreshCameraSilence(); m.close(); await m.waitForCameraSilence()
        #expect(m.cameraSilenceCount == 0)
    }
}

@MainActor @Suite struct ClickSoundTests {      // BS-10
    @Test func percentMapsToDecibelsAndBack() {
        #expect(abs(ClickSoundSettings.gainDb(percent: 100)) < 1e-9)
        #expect(abs(ClickSoundSettings.gainDb(percent: 50) + 6.0206) < 1e-3)
        #expect(ClickSoundSettings.gainDb(percent: 0) == -48)
        #expect(abs(ClickSoundSettings.percent(gainDb: ClickSoundSettings.gainDb(percent: 25)) - 25) < 1e-6)
        #expect(ClickSoundSettings.percent(gainDb: -48) == 0)
    }
    @Test func previewHasSoundForBothVariantsAndPeakScalesWithVolume() {
        for v in ["soft", "crisp"] {
            let loud = ClickSoundSettings.previewSamples(variant: v, percent: 100).map { abs(Int($0)) }.max() ?? 0
            let quiet = ClickSoundSettings.previewSamples(variant: v, percent: 25).map { abs(Int($0)) }.max() ?? 0
            #expect(loud > 1000 && quiet > 0 && abs(Double(quiet) / Double(loud) - 0.25) < 0.02)
        }
        #expect(ClickSoundSettings.previewSamples(variant: "soft", percent: 0).allSatisfy { $0 == 0 })
    }
    @Test func choosingVariantTurnsSoundOnAndNoneOff() {
        let m = EditorModel(project: FakeProject(), player: FakePlayer())
        m.setClickSound("crisp"); #expect(m.clickSoundChoice == "crisp")
        m.setClickSoundPercent(50); #expect(abs(m.clickSoundPercent - 50) < 1e-6)
        m.setClickSound("none"); #expect(m.clickSoundChoice == "none")
        m.undo(); #expect(m.clickSoundChoice == "crisp")
    }
}

@MainActor @Suite struct CameraPlacementTests {      // CAM-15/16, CAM-04
    @Test func gridCellsIncludeTheCentre() {
        #expect(CameraPlacement.cell(of: [0.5, 0.5]) != nil && CameraPlacement.cell(of: [0.5, 0.5])! == (1, 1))
        #expect(CameraPlacement.cell(of: [0.82, 0.78])! == (2, 2))
        #expect(CameraPlacement.cell(of: nil) == nil && CameraPlacement.cell(of: [0.3, 0.3]) == nil)
    }
    @Test func layoutPositionAndSizeAreStoredPerSection() {
        let m = EditorModel(project: FakeProject(), player: FakePlayer())
        m.set("camera.layouts", .array([.object(["id": .string("a"), "tl_start_ns": .number(0), "tl_end_ns": .number(2e9), "mode": .string("overlay")])]))
        m.setLayoutCameraPosition(id: "a", [0.5, 0.5]); #expect(m.layoutCameraPosition(id: "a") == [0.5, 0.5])
        m.setLayoutCameraSize(id: "a", 0.5); #expect(m.layoutCameraSize(id: "a") == 0.5)
        m.setLayoutCameraSize(id: "a", 9); #expect(m.layoutCameraSize(id: "a") == 0.75)
        m.setLayoutCameraPosition(id: "a", nil); #expect(m.layoutCameraPosition(id: "a") == nil)
        m.setLayoutCameraSize(id: "a", nil); #expect(m.layoutCameraSize(id: "a") == nil)
    }
    @Test func roundnessReachesACircleAndComesBack() {
        let m = EditorModel(project: FakeProject(), player: FakePlayer())
        m.setCameraRoundness(0.5); #expect(m.number("camera.radius") == 32 && abs(m.cameraRoundness - 0.5) < 1e-9)
        m.setCameraRoundness(1); #expect(m.string("camera.shape") == "circle" && m.cameraRoundness == 1)
        m.setCameraRoundness(0.25); #expect(m.string("camera.shape") == "rounded_rect" && m.number("camera.radius") == 16)
    }
}

@MainActor @Suite struct FrameExportTests {      // editing.md P1 #5
    @Test func destinationExtensionPicksTheFormat() {
        #expect(FrameImageFormat.type(for: URL(fileURLWithPath: "/tmp/a.JPG")) == .jpeg)
        #expect(FrameImageFormat.type(for: URL(fileURLWithPath: "/tmp/a.png")) == .png)
        #expect(FrameImageFormat.type(for: URL(fileURLWithPath: "/tmp/a")) == .png)
    }
    @Test func jpegIsRealJPEGAndPNGPassesThrough() throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        #expect(try FrameImageFormat.encode(png: png, for: URL(fileURLWithPath: "/x.png")) == png)
        let jpg = try FrameImageFormat.encode(png: png, for: URL(fileURLWithPath: "/x.jpeg"))
        #expect(Array(jpg.prefix(2)) == [0xFF, 0xD8])
    }
    @Test func defaultNameUsesTitleAndPlayheadTime() {
        #expect(FrameImageFormat.defaultName(title: "Demo", ns: 72_400_000_000) == "Demo – 1.12.png")
        #expect(FrameImageFormat.defaultName(title: " ", ns: 0) == "Frame – 0.00.png")
    }
    @Test func fakeProjectsCannotExportFrames() {
        #expect(!EditorModel(project: FakeProject(), player: FakePlayer()).canExportFrame)
    }
}

@MainActor @Suite struct ZoomPanelTests {      // BS-11, BS-12
    @Test func thumbnailTargetIsClampedLikeEveryFocusEdit() {
        let m = EditorModel(project: FakeProject(), player: FakePlayer())
        m.addZoom(fromNs: 0, toNs: 1_000_000_000)
        guard let z = m.zooms.first else { Issue.record("no zoom"); return }
        m.setZoomScale(id: z.id, 2)
        m.setZoomTarget(id: z.id, unit: CGPoint(x: 0.1, y: 0.25))
        let f = m.zooms.first { $0.id == z.id }!
        #expect(abs(f.focusX - 0.25) < 1e-9 && abs(f.focusY - 0.25) < 1e-9)      // 2× → half-window 0.25
        #expect(ZoomTargetThumbnail.unit(CGPoint(x: 300, y: -5), in: CGSize(width: 200, height: 100)) == CGPoint(x: 1, y: 0))
    }
    @Test func useForNewZoomsSetsTheDefaultLevel() {
        let m = EditorModel(project: FakeProject(), player: FakePlayer())
        m.addZoom(fromNs: 0, toNs: 1_000_000_000)
        let id = m.zooms[0].id
        m.setZoomScale(id: id, 3)
        m.useZoomForNewZooms(id: id)
        #expect(m.defaultZoomScale == 3)
        m.undo(); #expect(m.defaultZoomScale == 2)
    }
}

@Suite struct CropDraftTests {      // editing.md P1 #3 (EDT-09…13)
    let frame = CGSize(width: 1920, height: 1080)

    @Test func pixelsRoundTripThroughTheStoredFraction() {
        let d = CropDraft(frame: frame, rect: CGRect(x: 100, y: 50, width: 960, height: 540))
        let back = CropDraft(frame: frame, stored: d.stored)
        #expect(back.rect == d.rect)
        #expect(abs(d.insets.left - 100.0 / 1920) < 1e-12 && abs(d.insets.right - (1920 - 1060) / 1920.0) < 1e-12)
        #expect(CropDraft(frame: frame, stored: []).isFullFrame && CropDraft(frame: frame, stored: [0, 0, 0, 0]).isFullFrame)
    }
    @Test func noLockDragMovesOnlyThatEdgeAndKeepsMinimumSize() {
        let d = CropDraft(frame: frame)
        let r = d.dragged(.top, from: d.rect, dx: 500, dy: 80)
        #expect(r == CGRect(x: 0, y: 80, width: 1920, height: 1000))
        let tiny = d.dragged(.bottom, from: d.rect, dx: 0, dy: -5000)
        #expect(tiny.height == 32 && tiny.minY == 0)
        let out = d.dragged(.left, from: d.rect, dx: -300, dy: 0)
        #expect(out.minX == 0)
    }
    @Test func bodyDragStaysInsideTheFrame() {
        let d = CropDraft(frame: frame, rect: CGRect(x: 100, y: 100, width: 400, height: 300))
        #expect(d.dragged(.body, from: d.rect, dx: 5000, dy: -5000) == CGRect(x: 1520, y: 0, width: 400, height: 300))
    }
    @Test func lockedCornerDragKeepsTheRatioAndAnchorsTheOppositeCorner() {
        var d = CropDraft(frame: frame, rect: CGRect(x: 100, y: 100, width: 800, height: 450))
        d.setLock(.r16x9)
        let r = d.dragged(.bottomRight, from: d.rect, dx: 160, dy: 0)
        #expect(r.minX == 100 && r.minY == 100 && abs(r.width / r.height - 16.0 / 9) < 1e-9 && r.width > 800)
        let big = d.dragged(.bottomRight, from: d.rect, dx: 9000, dy: 9000)
        #expect(big.maxX <= 1920 + 1e-9 && big.maxY <= 1080 + 1e-9 && abs(big.width / big.height - 16.0 / 9) < 1e-9)
    }
    @Test func lockedEdgeDragGrowsTheOtherAxisAroundTheCentre() {
        var d = CropDraft(frame: frame, rect: CGRect(x: 400, y: 300, width: 400, height: 400))
        d.setLock(.r1x1)
        let r = d.dragged(.right, from: d.rect, dx: 100, dy: 0)
        #expect(r.width == 500 && r.height == 500 && r.midY == 500 && r.minX == 400)
    }
    @Test func numericFieldsClampAndFollowTheLock() {
        var d = CropDraft(frame: frame, rect: CGRect(x: 0, y: 0, width: 800, height: 600))
        d.setWidth(5000); #expect(d.rect.width == 1920)
        d.setHeight(1); #expect(d.rect.height == 32)
        d.setX(5000); #expect(d.rect.maxX == 1920)
        d.reset(); d.setLock(.r9x16)
        #expect(abs(d.rect.width / d.rect.height - 9.0 / 16) < 1e-9 && d.rect.height == 1080)
        d.setHeight(540); #expect(abs(d.rect.width - 303.75) < 1e-9)
        #expect(d.rounded().rect.width == 304)
    }
    @Test func resetReturnsTheWholeFrame() {
        var d = CropDraft(frame: frame, rect: CGRect(x: 10, y: 10, width: 100, height: 100)); d.reset(); #expect(d.isFullFrame)
    }
}

@MainActor @Suite struct CropToolModelTests {
    @Test func confirmWritesOneUndoStepAndFullFrameClears() {
        let m = EditorModel(project: FakeProject(), player: FakePlayer())
        var d = m.cropDraft(); #expect(d.isFullFrame)
        d.rect = CGRect(x: 192, y: 108, width: 1536, height: 864)
        m.applyCrop(d)
        let c = m.cropInsets(); #expect(abs(c.left - 0.1) < 1e-9 && abs(c.top - 0.1) < 1e-9 && abs(c.right - 0.1) < 1e-9)
        #expect(!m.cropDraft().isFullFrame)
        m.undo(); #expect(m.cropDraft().isFullFrame)                      // one step
        m.applyCrop(d); d.reset(); m.applyCrop(d); #expect(m.cropDraft().isFullFrame)
    }
    @Test func paletteOffersCropAndDiscardLeavesTheProjectAlone() {
        let m = EditorModel(project: FakeProject(), player: FakePlayer())
        let cmd = m.paletteCommands.first { $0.title == "Crop recording…" }
        #expect(cmd != nil); cmd?.run(); #expect(m.cropRequested)
        _ = m.cropDraft()                                                  // staging never writes
        #expect(m.numbers("canvas.crop").isEmpty || CropDraft(frame: CGSize(width: 10, height: 10), stored: m.numbers("canvas.crop")).isFullFrame)
    }
}

@MainActor @Suite struct TranscriptEditTests {      // CAM-33, MKT-037/038
    func words(_ t: [String]) -> [TextItem] {
        t.enumerated().map { i, s in TextItem.make(.caption, id: "w\(i)", start: Int64(i) * 1_000_000_000, end: Int64(i) * 1_000_000_000 + 500_000_000, text: s) }
    }
    @Test func typoFixTouchesOnlyThatWord() {
        let e = EditorModel.wordEdits(old: words(["hello", "yapcom", "world"]), newText: "hello Yapcam world")
        #expect(e == [WordEdit(id: "w1", text: "Yapcam", hide: false)])
    }
    @Test func replacingTwoWordsWithOneHidesTheSurplusInsteadOfCutting() {
        let e = EditorModel.wordEdits(old: words(["a", "b", "c", "d"]), newText: "a X d")
        #expect(e == [WordEdit(id: "w1", text: "X", hide: false), WordEdit(id: "w2", text: "c", hide: true)])
    }
    @Test func insertionJoinsTheNeighbourAndNoChangeIsEmpty() {
        #expect(EditorModel.wordEdits(old: words(["a", "b"]), newText: "a new b") == [WordEdit(id: "w0", text: "a new", hide: false)])
        #expect(EditorModel.wordEdits(old: words(["a", "b"]), newText: "a   b").isEmpty)
    }
    @Test func appliedEditsAreOneUndoStepAndNeverCut() {
        let m = EditorModel(project: FakeProject(), player: FakePlayer())
        m.writeTextList(.caption, words(["one", "two", "three"]))
        let dur = m.durationNs
        m.applyWordEdits(EditorModel.wordEdits(old: m.transcriptWords, newText: "one 2 three"))
        #expect(m.transcriptWords.map(\.text) == ["one", "2", "three"] && m.durationNs == dur)
        m.hideWords(ids: ["w0"]); #expect(m.isHidden(m.transcriptWords[0]) && m.durationNs == dur)
        m.undo(); #expect(!m.isHidden(m.transcriptWords[0]))
        m.undo(); #expect(m.transcriptWords.map(\.text) == ["one", "two", "three"])
        #expect(m.pause(before: 1) == 500_000_000 && EditorModel.pauseLabel(1_500_000_000) == "1.5 s")
    }
}

@MainActor @Suite struct BackgroundAudioTests {      // CAM-37, CAM-42
    @Test func videoFilesCanBeDroppedAsAudioSource() {
        let m = EditorModel(project: FakeProject(), player: FakePlayer())
        #expect(m.dropMusic(urls: [URL(fileURLWithPath: "/tmp/talk.mp4")]))
        #expect(!m.dropMusic(urls: [URL(fileURLWithPath: "/tmp/notes.txt")]))
    }
}

@MainActor @Suite struct ShortcutsGuideTests {      // REC B-09
    @Test func everyRebindableActionIsListedWithItsCurrentKey() {
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let b = EditorKeyBindings(defaults: iso.defaults)
        #expect(b.setKey("q", for: "split"))
        let entries = ShortcutsGuide.categories(bindings: b).flatMap(\.entries)
        for a in EditorKeyBindings.actions { #expect(entries.contains { $0.title == a.title && $0.keys == String(b.key(for: a.id)).uppercased() }, "\(a.title)") }
        #expect(entries.contains { $0.keys == "Q" })
    }
    @Test func paletteShortcutsAppearInTheGuide() {
        let m = EditorModel(project: FakeProject(), player: FakePlayer())
        let keys = Set(ShortcutsGuide.categories().flatMap(\.entries).flatMap { $0.keys.components(separatedBy: " / ") })
        for c in m.paletteCommands where ["⌘D", "⌘K", "⌘Z", "⇧⌘Z", "⌘/", "⌘=", "⌘-"].contains(c.shortcut) {
            let k = c.shortcut == "⌘-" ? "⌘−" : c.shortcut
            #expect(keys.contains(k) || keys.contains { $0.contains(k) }, "\(c.title) \(c.shortcut)")
        }
    }
}

@MainActor @Suite struct ExportDialogParityTests {      // S-03
    @Test func commandReturnCopiesWhateverTheTarget() async {
        let e = ExportModel(engine: FakeExporter()); e.target = .file
        e.copyToClipboard(); #expect(e.runningTarget == .clipboard)
        await e.waitUntilFinished()
    }
    @Test func everyCompressionHasADescription() {
        for p in CompressionPreset.allCases { #expect(p.longHint.count > 10) }
        #expect(Set(CompressionPreset.allCases.map(\.longHint)).count == 4)
    }
}

@MainActor @Suite struct PresetCreateTests {      // S-10
    @Test func existingNameIsNotOverwrittenWithoutConfirmation() throws {
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let m = EditorModel(project: FakeProject(), player: FakePlayer()); m.presetStore = iso.store; m.defaults = iso.defaults
        #expect(m.createPreset(named: "  ") == .invalid)
        #expect(m.createPreset(named: "Demo") == .created)
        let url = iso.store.url("Demo")
        try Data("old".utf8).write(to: url)
        let result = m.createPreset(named: "Demo"), after = try Data(contentsOf: url)
        #expect(result == .needsReplace && after == Data("old".utf8))
        #expect(m.createPreset(named: "Demo", replace: true) == .created)
    }

    /// Import Preset… (S-11) adds the file to the library without replacing an existing preset of the same name.
    @Test func importingAPresetFileKeepsExistingPresets() throws {
        let iso = EditorStorage.makeIsolated(); defer { iso.cleanup() }
        let m = EditorModel(project: FakeProject(), player: FakePlayer()); m.presetStore = iso.store; m.defaults = iso.defaults
        #expect(m.createPreset(named: "Look") == .created)
        let original = try Data(contentsOf: iso.store.url("Look"))
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("imp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: outside) }
        let file = outside.appendingPathComponent("Look.yapcampreset"); try Data("{}".utf8).write(to: file)
        let name = m.importPresetFile(file)
        #expect(name == "Look 2" && iso.store.names().contains("Look 2"))
        #expect(try Data(contentsOf: iso.store.url("Look")) == original)
    }
}


@MainActor @Suite struct ExportPausesPlaybackTests {      // MKT-122
    @Test func startingAnExportPausesThePlayer() async throws {
        let pl = FakePlayer(), m = EditorModel(project: FakeProject(), player: pl)
        let e = ExportModel(engine: RecordingEngine()); m.exportModel = e
        m.togglePlay(); #expect(m.isPlaying)
        e.start(to: URL(fileURLWithPath: "/tmp/p.mp4")); await e.waitUntilFinished()
        #expect(!m.isPlaying)
    }
}


@Suite struct CameraAspectKeyTests {      // MKT-138
    @Test func presetsAreRecognisedAndOtherRatiosAreCustom() {
        #expect(CameraAspect.key(for: 16.0 / 9) == "16:9" && CameraAspect.key(for: 1) == "1:1")
        #expect(CameraAspect.key(for: 1.5) == "custom" && CameraAspect.key(for: 16.0 / 9 + 0.01) == "custom")
    }
}
