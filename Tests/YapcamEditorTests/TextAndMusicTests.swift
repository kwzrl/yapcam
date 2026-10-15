import Testing
import Foundation
import AVFoundation
import YapcamCore
import YapcamRender
@testable import YapcamEditor

private func copyPkg() throws -> URL {
    let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("tm-\(UUID().uuidString).yapcam")
    try FileManager.default.copyItem(at: src, to: d); return d
}

@MainActor @Suite struct TextModelTests {
    private func make() -> (EditorModel, FakeProject) {
        let p = FakeProject(durationNs: 20_000_000_000); return (EditorModel(project: p, player: FakePlayer()), p)
    }

    @Test func annotationReactionCaptionLifecycle() {
        let (m, _) = make()
        m.seek(toNs: 1_000_000_000)
        let a = m.addText(.annotation)!; let r = m.addText(.reaction, text: "🎉")!; let c = m.addText(.caption)!
        #expect(m.textItems(.annotation).count == 1 && m.textItems(.reaction)[0].text == "🎉" && m.textItems(.caption).count == 1)
        #expect(m.selection == .text(.caption, c) && m.allText.count == 3)
        m.updateText(.annotation, id: a) { $0.text = "Hello"; $0.fontSize = 60; $0.space = "source"; $0.color = [1, 0, 0, 1]; $0.background = [0, 0, 0, 0] }
        let t = m.textItems(.annotation)[0]
        #expect(t.text == "Hello" && t.fontSize == 60 && t.space == "source" && t.color == [1, 0, 0, 1] && t.background[3] == 0)
        #expect(m.textItems(.reaction)[0].fontSize == 120)       // reaction preset is large and transparent
        m.selection = .text(.reaction, r); m.deleteSelection()
        #expect(m.textItems(.reaction).isEmpty && m.selection == .none)
    }

    @Test func textRectDragIsOneUndoStep() {
        let (m, _) = make(); let id = m.addText(.annotation)!
        let t = m.textItems(.annotation)[0]; let key = EditorModel.textKey(t)
        for i in 1...25 { m.previewTextRect(key: key, rect: [0.1, 0.1 + Double(i) * 0.02, 0.4, 0.2]) }
        #expect(m.textItems(.annotation)[0].rect == t.rect)
        m.commitTextRect()
        #expect(m.textItems(.annotation)[0].rect[1] <= 0.8 && m.textItems(.annotation)[0].rect != t.rect)
        m.undo(); #expect(m.textItems(.annotation)[0].rect == t.rect && m.textItems(.annotation)[0].id == id)
    }

    @Test func textRangesRetimeThroughLaneDrag() {
        let (m, _) = make(); _ = m.addText(.caption)
        let t = m.textItems(.caption)[0]; let key = EditorModel.textKey(t)
        m.previewRange(key: key, current: t.span, moveToStartNs: 9_000_000_000); m.commitRange(key: key)
        #expect(m.textItems(.caption)[0].startNs == 9_000_000_000)
    }

    @Test func captionGenerationUsesTheSourceAndReportsFailures() async throws {
        let (m, p) = make()
        m.generateCaptions()
        #expect(m.captionState == .failed("Speech transcription isn't available in this build."))
        m.captionState = .idle
        let json = #"{"schema_version":1,"engine":"x","locale":"en","words":[{"text":"hello","src_start_ns":1000000000,"src_end_ns":1500000000},{"text":"world","src_start_ns":1500000000,"src_end_ns":2000000000}]}"#
        m.captionSource = { Data(json.utf8) }
        m.generateCaptions(); await m.waitForCaptions()
        #expect(m.captionState == .idle && p.importedTranscripts == 1 && m.textItems(.caption).map(\.text) == ["hello", "world"])
        m.captionSource = { throw EditorError.transcriptionUnavailable }
        m.generateCaptions(); await m.waitForCaptions()
        #expect(m.captionState == .failed(EditorError.transcriptionUnavailable.localizedDescription))
    }

    @Test func staleTranscriptIsRejectedWhenTheTimelineChangedMeanwhile() async throws {
        let (m, p) = make()
        m.captionSource = { try await Task.sleep(for: .milliseconds(80)); return Data(#"{"words":[]}"#.utf8) }
        m.generateCaptions()
        m.seek(toNs: 2_000_000_000); m.trim(keepAfter: true)
        await m.waitForCaptions()
        #expect(p.importedTranscripts == 0)
        if case .failed = m.captionState {} else { Issue.record("expected a failure state") }
    }
}

@MainActor @Suite struct MusicModelTests {
    private func make() -> (EditorModel, FakeProject) {
        let p = FakeProject(durationNs: 20_000_000_000); return (EditorModel(project: p, player: FakePlayer()), p)
    }
    @Test func builtInMusicEditing() {
        let (m, _) = make(); m.seek(toNs: 2_000_000_000)
        let id = m.addBuiltInMusic(builtInMusic[0])!
        #expect(m.music.count == 1 && m.music[0].source == "calm" && m.music[0].startNs == 2_000_000_000 && m.music[0].endNs == 20_000_000_000)
        m.setMusicGain(id: id, -200); #expect(m.music[0].gainDb == -96)
        m.setMusicGain(id: id, -12); m.setMusicLoop(id: id, false); m.setMusicFades(id: id, inNs: 1_000_000_000, outNs: -5)
        #expect(m.music[0].gainDb == -12 && !m.music[0].loop && m.music[0].fadeInNs == 1_000_000_000 && m.music[0].fadeOutNs == 0)
        m.setMusicDucking(id: id, enabled: true, gainDb: -9); #expect(m.music[0].duckEnabled && m.music[0].duckGainDb == -9)
        m.previewRange(key: id, current: m.music[0].span, moveToStartNs: 0); m.commitRange(key: id)
        m.selection = .music(id); m.deleteSelection(); #expect(m.music.isEmpty)
    }
    @Test func importingAFileGoesThroughTheProject() async throws {
        let (m, p) = make(); m.seek(toNs: 3_000_000_000)
        m.importMusicFile(URL(fileURLWithPath: "/tmp/song.m4a"))
        for _ in 0..<500 where p.importedMusic.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(p.importedMusic.first?.1 == 3_000_000_000)
        #expect(m.music.count == 1 && m.music[0].title == "song.m4a")
    }
}

@MainActor @Suite struct TextAndMusicRealCoreTests {
    @Test func coreAcceptsTextAndRendersTextLayers() throws {
        let d = try copyPkg(); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d); let m = doc.model
        m.seek(toNs: 500_000_000)
        m.addText(.annotation, text: "Hello"); m.addText(.reaction, text: "🎉"); m.addText(.caption, text: "A caption")
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        let fx = try doc.project.effects(atNs: 1_000_000_000)
        let ids = fx.layers.map(\.id)
        #expect(ids.contains { $0.hasPrefix("core:annotation:") } && ids.contains { $0.hasPrefix("core:reaction:") } && ids.contains { $0.hasPrefix("core:caption:") })
        // Edits: text change, move, undo — and empty text is rejected by core with state unchanged.
        let a = m.textItems(.annotation)[0]
        m.updateText(.annotation, id: a.id) { $0.text = "Changed" }
        #expect(m.textItems(.annotation)[0].text == "Changed")
        m.updateText(.annotation, id: a.id) { $0.text = "" }
        #expect(m.lastError != nil && m.textItems(.annotation)[0].text == "Changed")
    }

    @Test func keyOverlayClickSoundAndAnimationModesAreAccepted() throws {
        let d = try copyPkg(); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d); let m = doc.model
        m.set("cursor.key_overlay.enabled", bool: true); m.set("cursor.key_overlay.shortcuts_only", bool: false)
        m.set("cursor.key_overlay.duration_ns", number: 1_500_000_000)
        m.set("cursor.key_overlay.rect", color: [0.2, 0.7, 0.5, 0.15])
        m.set("cursor.key_overlay.style.font_size", number: 48); m.set("cursor.key_overlay.style.background", color: [0, 0, 0, 0.5])
        m.set("audio.click_sound.enabled", bool: true); m.set("audio.click_sound.variant", string: "crisp"); m.set("audio.click_sound.gain_db", number: -6)
        for mode in ["zoom", "slide_left", "slide_right", "slide_up", "slide_down", "fade", "none"] {
            m.set("canvas.animation.entrance", string: mode); m.set("canvas.animation.exit", string: mode)
        }
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        #expect(m.bool("cursor.key_overlay.enabled") && m.string("audio.click_sound.variant") == "crisp" && m.numbers("cursor.key_overlay.rect") == [0.2, 0.7, 0.5, 0.15])
        let overlays = try doc.project.audioOverlays()
        #expect(overlays.contains { $0.source == "crisp" })      // click instructions from the fixture's clicks
        m.set("canvas.animation.entrance", string: "zoom")
        #expect(try doc.project.frameExtras(atNs: 0).fade_opacity == 0)   // zoom entrance, not a black fade
    }

    @Test func builtInMusicIsAcceptedAndMapsToOverlays() throws {
        let d = try copyPkg(); defer { try? FileManager.default.removeItem(at: d) }
        let doc = try EditorDocument(package: d); let m = doc.model
        m.seek(toNs: 1_000_000_000); m.addBuiltInMusic(builtInMusic[1])
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        m.setMusicDucking(id: m.music[0].id, enabled: true, gainDb: -12)
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        #expect(try doc.project.audioOverlays().contains { $0.source == "bright" })
        #expect(try doc.project.musicTracks().count == 1)
    }

    @Test func importedAudioFileBecomesAMusicTrack() async throws {
        let d = try copyPkg(); defer { try? FileManager.default.removeItem(at: d) }
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        do {   // the file must be deallocated (flushed and closed) before it is read back
            let file = try AVAudioFile(forWriting: wav, settings: fmt.settings)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44100)!; buf.frameLength = 44100
            for i in 0..<44100 { buf.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.2 }
            try file.write(from: buf)
        }
        let doc = try EditorDocument(package: d); let m = doc.model
        m.importMusicFile(wav)
        for _ in 0..<1000 where m.music.isEmpty && m.lastError == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        #expect(m.music.count == 1 && m.music[0].source == "file" && m.music[0].path.hasPrefix("assets/"))
    }

    @Test func transcriptFileBecomesCaptionsThroughTheDocument() async throws {
        let d = try copyPkg(); defer { try? FileManager.default.removeItem(at: d) }
        let json = #"{"schema_version":1,"engine":"test","locale":"en_US","words":[{"text":"hello","src_start_ns":500000000,"src_end_ns":900000000,"confidence":0.9,"segment_index":0,"track":"system_audio"},{"text":"there","src_start_ns":1000000000,"src_end_ns":1400000000,"confidence":0.9,"segment_index":0,"track":"system_audio"}]}"#
        try Data(json.utf8).write(to: d.appendingPathComponent("recording/transcript.json"))
        let m = try EditorDocument(package: d).model
        m.generateCaptions(); await m.waitForCaptions()
        #expect(m.captionState == .idle, "\(m.captionState)")
        #expect(m.textItems(.caption).map(\.text) == ["hello", "there"])
        m.undo(); #expect(m.textItems(.caption).isEmpty)
    }
}
