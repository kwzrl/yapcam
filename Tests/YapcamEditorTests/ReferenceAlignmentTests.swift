import Testing
import Foundation
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
        #expect(m.availableSections.count == 10)
        p.hasCamera = false; p.hasMic = false; p.hasMouseData = false; p.hasKeystrokes = false
        #expect(m.availableSections == [.background, .audio, .animations, .extras])
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
        #expect(m.handleShortcut("0", .command) && m.inspectorSection == .extras)
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
        m.seek(toNs: 2_000_000_000); m.addZoomAtPlayhead()                           // zoom 2.0–4.0 s, selected
        m.seek(toNs: 3_000_000_000); #expect(m.handleShortcut("c"))
        #expect(m.zooms.count == 2 && m.zooms.map(\.startNs).sorted() == [2_000_000_000, 3_000_000_000] && m.clips.count == 2)
        m.undo(); #expect(m.zooms.count == 1)                                         // one undo step
        m.selection = .zoom(m.zooms[0].id)
        m.seek(toNs: 4_000_000_000); m.handleShortcut("c"); #expect(m.lastError != nil && m.zooms.count == 1)   // at the end: too short
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

    @Test func volumeMenuMapsPercentToGainAndMute() {
        let (m, _) = make()
        #expect(m.handleShortcut("v") && m.volumeMenuVisible && !m.volumeMenuSystem)
        m.handleShortcut("v", .control); #expect(m.volumeMenuSystem)
        m.setVolume(percent: 50, system: false)
        #expect(abs(m.number("audio.mic_gain_db") - (-6.0206)) < 0.01 && !m.bool("audio.mic_muted") && m.volumePercent(system: false) == 50)
        m.setVolume(percent: 0, system: false); #expect(m.bool("audio.mic_muted") && m.volumePercent(system: false) == 0)
        m.setVolume(percent: 100, system: true); #expect(m.number("audio.system_gain_db") == 0 && m.volumePercent(system: true) == 100)
    }

    @Test func zoomKeysOnlyActOnASelectedZoom() {
        let (m, _) = make()
        #expect(!m.handleShortcut("a") && !m.handleShortcut("5") && !m.handleShortcut("="))
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
        #expect(m.handleShortcut("c", .command))                                      // copies the zoom's settings, not the frame
        m.selection = .zoom(b.id); #expect(m.handleShortcut("v", .command))
        #expect(m.zooms[1].scale == 3.2 && m.zooms[1].easeInNs == 0)
        m.selection = .none; var copied = 0
        m.copyFrameHandler = { copied += 1 }
        m.handleShortcut("c", .command); #expect(copied == 1)                         // nothing selected: copies the frame
        m.selection = .clip(m.clips[0].id); m.setSpeed(clipID: m.clips[0].id, 4); m.handleShortcut("c", .command)
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
    @Test func choosingAPresetWritesTheSpringAndMarksItActive() {
        let m = EditorModel(project: FakeProject(), player: FakePlayer())
        let smooth = SpringPreset.screen[1]
        m.setSpring(screen: true, stiffness: smooth.stiffness, damping: smooth.damping, mass: smooth.mass)
        #expect(m.activePreset(screen: true) == "smooth" && m.string("zoom_settings.animation_style") == "custom")
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
        m.hideWord(id: m.transcriptWords[1].id); #expect(m.transcriptWords.count == 4 && m.durationNs == dur)
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
        let m = EditorModel(project: p, player: FakePlayer())
        #expect(m.typingSuggestions.count == 2 && m.visibleLanes.contains(.typing))
        UserDefaults.standard.removeObject(forKey: EditorModel.typingSpeedKey)
        #expect(m.typingSpeed == 3)
        m.typingSpeed = 5
        m.applyTypingSuggestion(m.typingSuggestions[0])
        #expect(p.processSilenceCalls.count == 1 && p.processSilenceCalls[0].speed == 5 && p.processSilenceCalls[0].spans.count == 1)
        m.applyAllTypingSuggestions()
        #expect(p.processSilenceCalls.last?.spans.count == 2)
        m.typingSpeed = 99; #expect(m.typingSpeed == 8); m.typingSpeed = 0.1; #expect(m.typingSpeed == 1.5)
        UserDefaults.standard.removeObject(forKey: EditorModel.typingSpeedKey)
    }

    @Test func removedSuggestionsStayHiddenUntilTheTimelineChanges() {
        let p = FakeProject(durationNs: 30_000_000_000)
        p.keyTimesNs = keys(from: 2000, count: 20, gapMs: 150)
        let m = EditorModel(project: p, player: FakePlayer())
        let sp = m.typingSuggestions[0]
        m.dismissTypingSuggestion(sp); #expect(m.typingSuggestions.isEmpty && !m.visibleLanes.contains(.typing))
        m.set("canvas.padding", number: 3); #expect(m.typingSuggestions.count == 1)
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
