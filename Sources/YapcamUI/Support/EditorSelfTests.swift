import AppKit
import AVFoundation
import YapcamCore
import YapcamEditor

/// Launch-flag self-tests for the editor UI path (QA has no Accessibility, so it can't drive the editor).
///
///   --editor-selftest <package> [--crash-after-autosave | --crash-now]
///   --editor-reopen-check <package>
///   --editor-export-selftest <package> <out.mp4>
///
/// Everything is logged to ~/Library/Logs/Yapcam/probe.log. Launch via `open -n -W` (see docs/status/ui.md).
@MainActor enum EditorSelfTests {
    /// State the reopen check compares against; written by `--editor-selftest`.
    struct Expectation: Codable, Equatable {
        var package: String
        var clips: Int
        var zooms: Int
        var durationNs: Int64
        var padding: Double
        var crashMode: String
    }

    static var expectationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Yapcam/editor-selftest-expect.json")
    }

    /// Package path = first argument after the flag that isn't itself a flag.
    static func argument(after flag: String, in args: [String], offset: Int = 1) -> String? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + offset), !args[i + offset].hasPrefix("--") else { return nil }
        return args[i + offset]
    }

    private static func state(_ m: EditorModel) -> String {
        "clips=\(m.clips.count) zooms=\(m.zooms.count) durationMs=\(m.durationNs / 1_000_000) padding=\(m.number("canvas.padding")) canUndo=\(m.canUndo) save=\(m.saveState)"
    }

    private static func waitFor(_ cond: @MainActor () -> Bool, seconds: Double) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
        return cond()
    }

    private static func openLikeAUser(_ package: URL, tag: String) async -> EditorDocument? {
        if EditorDocument.hasUnsavedJournal(package) {
            Probe.log("\(tag) SKIP package has an unsaved autosave journal (would show the restore prompt); use --editor-reopen-check or delete autosave/")
            return nil
        }
        EditorWindows.open(package: package)
        guard await waitFor({ EditorBridge.anyDocument() != nil }, seconds: 20), let doc = EditorBridge.anyDocument() else {
            Probe.log("\(tag) FAIL editor window did not open"); return nil
        }
        NSApp.activate()
        for w in NSApp.windows where w.windowController != nil && w.isVisible { w.makeKeyAndOrderFront(nil) }
        try? await Task.sleep(for: .seconds(1))
        return doc
    }

    // MARK: --editor-selftest

    static func run(_ args: [String]) async {
        let tag = "editor-selftest"
        guard let path = argument(after: "--editor-selftest", in: args) else { Probe.log("\(tag) failed: missing <package>"); return }
        let crash = args.contains("--crash-after-autosave") ? "after-autosave" : args.contains("--crash-now") ? "now" : "none"
        let package = URL(filePath: path)
        guard FileManager.default.fileExists(atPath: package.path) else { Probe.log("\(tag) failed: no such package \(path)"); return }
        Probe.log("\(tag) start package=\(path) crash=\(crash) accessibility=\(AXIsProcessTrusted())")
        guard let doc = await openLikeAUser(package, tag: tag) else { return }
        let m = doc.model
        let delegate = NSApp.delegate as? AppDelegate
        Probe.log("\(tag) opened: \(state(m)) keyEditorRoutable=\(EditorBridge.keyEditor() != nil)")
        let dur = m.durationNs
        guard dur > 2_000_000_000 else { Probe.log("\(tag) failed: recording shorter than 2 s (\(dur / 1_000_000) ms)"); return }

        // 1. split at 1/3 (menu action: Edit → Split at Playhead)
        m.seek(toNs: dur / 3)
        delegate?.editSplit()
        Probe.log("\(tag) after split: \(state(m))")
        // 2. delete the second clip (select it, then Delete)
        if let second = m.clipStarts().dropFirst().first {
            m.selection = .clip(second.clip.id)
            m.deleteSelection()
        }
        Probe.log("\(tag) after delete: \(state(m))")
        // 3. add a zoom (menu action)
        m.seek(toNs: m.durationNs / 5)
        delegate?.editAddZoom()
        Probe.log("\(tag) after add zoom: \(state(m))")
        // 4. padding
        m.set("canvas.padding", number: 72)
        Probe.log("\(tag) after padding: \(state(m))")
        // 5. undo (menu) then redo (menu): the padding must go away and come back
        let before = m.number("canvas.padding")
        delegate?.editUndo()
        let undone = m.number("canvas.padding")
        delegate?.editRedo()
        let redone = m.number("canvas.padding")
        Probe.log("\(tag) undo/redo via menu actions: padding \(before) → \(undone) → \(redone) \(undone != before && redone == before ? "OK" : "FAIL")")

        let expect = Expectation(package: package.path, clips: m.clips.count, zooms: m.zooms.count, durationNs: m.durationNs,
                                 padding: m.number("canvas.padding"), crashMode: crash)
        try? JSONEncoder().encode(expect).write(to: expectationURL)
        Probe.log("\(tag) expectation written: clips=\(expect.clips) zooms=\(expect.zooms) durationMs=\(expect.durationNs / 1_000_000) padding=\(expect.padding)")

        switch crash {
        case "now":
            Probe.log("\(tag) crashing now (exit 9, nothing saved explicitly; only the journal can hold the edits)")
            _exit(9)
        case "after-autosave":
            let saved = await waitFor({ m.saveState == .clean }, seconds: 30)
            Probe.log("\(tag) autosave \(saved ? "completed" : "DID NOT complete"): \(state(m))")
            Probe.log("\(tag) crashing now (exit 9 without a clean quit)")
            _exit(9)
        default:
            _ = await waitFor({ m.saveState == .clean }, seconds: 30)
            Probe.log("\(tag) done: \(state(m))")
            NSApp.terminate(nil)
        }
    }

    // MARK: --editor-reopen-check

    static func reopenCheck(_ args: [String]) async {
        let tag = "editor-reopen-check"
        guard let path = argument(after: "--editor-reopen-check", in: args) else { Probe.log("\(tag) failed: missing <package>"); return }
        let package = URL(filePath: path)
        guard let data = try? Data(contentsOf: expectationURL), let expect = try? JSONDecoder().decode(Expectation.self, from: data) else {
            Probe.log("\(tag) failed: no expectation file (run --editor-selftest first)"); return
        }
        guard expect.package == package.path else { Probe.log("\(tag) failed: expectation is for \(expect.package)"); return }
        let journal = EditorDocument.hasUnsavedJournal(package)
        Probe.log("\(tag) start package=\(path) crashMode=\(expect.crashMode) unsavedJournalPresent=\(journal)")
        do {
            // Same code path EditorWindows takes after the user answers "Restore".
            let doc = try EditorDocument(package: package, restoreUnsavedChanges: true)
            let m = doc.model
            let got = (clips: m.clips.count, zooms: m.zooms.count, dur: m.durationNs, pad: m.number("canvas.padding"))
            Probe.log("\(tag) reopened: \(state(m))")
            let ok = got.clips == expect.clips && got.zooms == expect.zooms && got.dur == expect.durationNs && abs(got.pad - expect.padding) < 1e-9
            Probe.log("\(tag) \(ok ? "PASS edits survived" : "FAIL expected clips=\(expect.clips) zooms=\(expect.zooms) durationMs=\(expect.durationNs / 1_000_000) padding=\(expect.padding)")")
            m.saveNow()
        } catch { Probe.log("\(tag) FAIL could not reopen: \(UserMessage.describe(error)) | \(error)") }
    }

    // MARK: --editor-export-selftest

    static func export(_ args: [String]) async {
        let tag = "editor-export-selftest"
        guard let path = argument(after: "--editor-export-selftest", in: args),
              let out = argument(after: "--editor-export-selftest", in: args, offset: 2) else {
            Probe.log("\(tag) failed: usage --editor-export-selftest <package> <out.mp4>"); return
        }
        let outURL = URL(filePath: out)
        try? FileManager.default.removeItem(at: outURL)
        Probe.log("\(tag) start package=\(path) out=\(out)")
        guard let doc = await openLikeAUser(URL(filePath: path), tag: tag) else { return }
        Probe.log("\(tag) opened: \(state(doc.model))")
        doc.export.format = .mp4h264
        doc.export.height = 1080
        doc.export.fps = 30
        doc.export.includeAudio = true
        doc.export.start(to: outURL)
        await doc.export.waitUntilFinished()
        Probe.log("\(tag) export state: \(doc.export.state)")
        let asset = AVURLAsset(url: outURL)
        if let d = try? await asset.load(.duration), let v = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await v.load(.naturalSize) {
            let audio = (try? await asset.loadTracks(withMediaType: .audio).count) ?? 0
            let projectSec = Double(doc.model.durationNs) / 1e9
            Probe.log("\(tag) output: \(Int(size.width))x\(Int(size.height)) duration=\(String(format: "%.3f", d.seconds))s (project \(String(format: "%.3f", projectSec))s) audioTracks=\(audio)")
            Probe.log("\(tag) \(abs(d.seconds - projectSec) < 0.1 && audio == 1 ? "PASS" : "CHECK duration/tracks")")
        } else { Probe.log("\(tag) FAIL no readable output at \(out)") }
    }
}
