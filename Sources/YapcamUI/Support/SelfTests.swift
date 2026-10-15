import AppKit
import ApplicationServices
import CoreMedia
import YapcamCapture
import YapcamEditor

/// Launch-flag self-tests for QA and CI. All results go to ~/Library/Logs/Yapcam/probe.log.
///
///   --capture-selftest <sec> [--target window:<id>|area:x,y,w,h] [--pause-after <sec>]
///   --ui-record-selftest <sec>     toolbar + HUD, recording through RecordingController
///   --drive-input-selftest <sec>   same, plus scripted CGEvent moves/clicks from inside the app
@MainActor enum SelfTests {
    // MARK: Argument parsing (pure, unit-tested)

    enum TargetSpec: Equatable {
        case display
        case window(UInt32)
        case windowTitle(String)      // first window whose title or app name contains the text
        case area(CGRect)
    }

    struct CaptureArgs: Equatable {
        var seconds: Double
        var target: TargetSpec?
        var pauseAfter: Double?
        var noAudio = false
        var outputDirectory: String?
        /// JSON file with scripted input to post from inside the app while recording.
        var driveInputScript: String?
    }

    /// Parses everything after `--capture-selftest`. Returns nil with an explanation in `error`.
    static func parseCapture(_ args: [String], error: inout String?) -> CaptureArgs? {
        guard let i = args.firstIndex(of: "--capture-selftest") else { error = "missing --capture-selftest"; return nil }
        var out = CaptureArgs(seconds: 5, target: nil, pauseAfter: nil)
        if args.indices.contains(i + 1), !args[i + 1].hasPrefix("--") {
            guard let s = Double(args[i + 1]), s > 0, s <= 3600 else { error = "seconds must be in (0, 3600]"; return nil }
            out.seconds = s
        }
        if let t = args.firstIndex(of: "--target") {
            guard args.indices.contains(t + 1) else { error = "--target needs a value"; return nil }
            let v = args[t + 1]
            if v == "display" {
                out.target = .display
            } else if v.hasPrefix("window:") {
                let rest = String(v.dropFirst(7))
                guard !rest.isEmpty else { error = "empty window in \(v)"; return nil }
                if let id = UInt32(rest) { guard id != 0 else { error = "bad window id in \(v)"; return nil }; out.target = .window(id) }
                else { out.target = .windowTitle(rest) }
            } else if v.hasPrefix("area:") {
                let p = v.dropFirst(5).split(separator: ",").compactMap { Double($0) }
                guard p.count == 4, p[2] >= 16, p[3] >= 16, p[0] >= 0, p[1] >= 0 else { error = "area needs x,y,w,h (w,h ≥ 16): \(v)"; return nil }
                out.target = .area(CGRect(x: p[0], y: p[1], width: p[2], height: p[3]))
            } else { error = "unknown --target \(v) (use display, window:<id|title>, or area:x,y,w,h)"; return nil }
        }
        if let a = args.firstIndex(of: "--pause-after") {
            guard args.indices.contains(a + 1), let s = Double(args[a + 1]), s > 0 else { error = "--pause-after needs seconds"; return nil }
            guard s < out.seconds else { error = "--pause-after must be shorter than the recording"; return nil }
            out.pauseAfter = s
        }
        out.noAudio = args.contains("--no-audio")
        if let o = args.firstIndex(of: "--out") {
            guard args.indices.contains(o + 1), !args[o + 1].hasPrefix("--") else { error = "--out needs a directory"; return nil }
            out.outputDirectory = args[o + 1]
        }
        if let d = args.firstIndex(of: "--drive-input") {
            guard args.indices.contains(d + 1), !args[d + 1].hasPrefix("--") else { error = "--drive-input needs a script.json path"; return nil }
            out.driveInputScript = args[d + 1]
        }
        return out
    }

    /// Loads `[{"kind":"move|click","x":..,"y":..,"at":seconds}]` (display-local top-left points).
    static func loadScript(_ path: String) throws -> [ScriptedEvent] {
        struct Row: Decodable { var kind: String; var x: Double; var y: Double; var at: Double }
        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(filePath: path)))
        return try rows.map { r in
            guard let k = ScriptedEvent.Kind(rawValue: r.kind) else { throw EngineError.failed("Unknown event kind “\(r.kind)” in the script (use move or click).") }
            guard r.at >= 0 else { throw EngineError.failed("Event times in the script must be ≥ 0.") }
            return ScriptedEvent(kind: k, x: r.x, y: r.y, at: r.at)
        }.sorted { $0.at < $1.at }
    }

    /// The scripted input used by `--drive-input-selftest`: positions in display points, top-left origin.
    struct ScriptedEvent: Equatable {
        enum Kind: String { case move, click }
        var kind: Kind
        var x: Double
        var y: Double
        /// Seconds after the script starts.
        var at: Double
    }

    static func inputScript(display: CGRect, duration: Double) -> [ScriptedEvent] {
        var out: [ScriptedEvent] = []
        let cx = display.midX, cy = display.midY
        let usable = duration - 1      // leave a second at the end so the last events land before stop
        var t = 0.5
        var i = 0
        while t < usable {
            let phase = Double(i) / 4
            out.append(.init(kind: .move, x: cx + 250 * cos(phase), y: cy + 150 * sin(phase), at: t))
            // A click every 8th step, at a fixed spot so it is easy to find in the events.
            if i % 8 == 7 { out.append(.init(kind: .click, x: cx + 100, y: cy - 80, at: t + 0.05)) }
            t += 0.25; i += 1
        }
        return out
    }

    // MARK: --capture-selftest

    static func runCapture(_ args: [String]) async {
        var error: String?
        guard let parsed = parseCapture(args, error: &error) else {
            Probe.log("capture-selftest failed bad arguments: \(error ?? "?")")
            return
        }
        var target: CaptureTarget?
        switch parsed.target {
        case .display?, nil: break
        case .window(let id)?: target = .window(CGWindowID(id))
        case .windowTitle(let text)?:
            let list = WindowList(); await list.reload()
            guard let w = list.windows.first(where: { $0.title.localizedCaseInsensitiveContains(text) || $0.appName.localizedCaseInsensitiveContains(text) }) else {
                Probe.log("capture-selftest failed no window matching “\(text)” (\(list.windows.count) windows listed)"); return
            }
            Probe.log("capture-selftest window “\(w.title)” of \(w.appName) id=\(w.id)")
            target = .window(CGWindowID(w.id))
        case .area(let r)?:
            guard let d = Displays.resolve(0) else { Probe.log("capture-selftest failed no display"); return }
            target = .area(display: d.id, rect: r)
        }
        var script: [ScriptedEvent] = []
        if let path = parsed.driveInputScript {
            do { script = try loadScript(path) } catch { Probe.log("capture-selftest failed bad drive-input script: \(UserMessage.describe(error))"); return }
        }
        Probe.log("capture-selftest start seconds=\(parsed.seconds) target=\(String(describing: target)) pauseAfter=\(String(describing: parsed.pauseAfter)) audio=\(!parsed.noAudio) out=\(parsed.outputDirectory ?? "default") script=\(script.count) accessibility=\(AXIsProcessTrusted())")
        var driver: Task<Void, Never>?
        if !script.isEmpty, let d = Displays.resolve(0) {
            // Start the script shortly after capture begins; hostNs in the log lines up with events.jsonl.
            driver = Task { try? await Task.sleep(for: .seconds(1)); await post(script, on: d, tag: "capture-selftest") }
        }
        do {
            let url = try await CaptureSelfTest.run(
                seconds: parsed.seconds, outputDirectory: parsed.outputDirectory.map { URL(filePath: $0, directoryHint: .isDirectory) },
                target: target, pauseAfter: parsed.pauseAfter, systemAudio: !parsed.noAudio)
            Probe.log("capture-selftest ok \(url.path)")
        } catch { Probe.log("capture-selftest failed \(UserMessage.describe(error)) | \(error)") }
        driver?.cancel()
    }

    // MARK: --ui-record-selftest / --drive-input-selftest

    /// Records through the same `RecordingController` path as the Record button, with the toolbar and HUD
    /// on screen. `driveInput` additionally posts scripted CGEvents while recording.
    static func runUIRecord(seconds: Double, driveInput: Bool, source: String? = nil) async {
        let tag = driveInput ? "drive-input-selftest" : "ui-record-selftest"
        guard seconds > 0, seconds <= 3600 else { Probe.log("\(tag) failed seconds must be in (0, 3600]"); return }
        let settings = AppSettings.shared, rec = RecordingController.shared
        // Run with fixed settings but leave the user's preferences as they were.
        let saved = (settings.countdown, settings.openEditorAfterRecording, settings.sourceMode)
        defer { (settings.countdown, settings.openEditorAfterRecording, settings.sourceMode) = saved }
        settings.sourceMode = .display
        ToolbarPanelController.shared.show()
        try? await Task.sleep(for: .seconds(1))
        let trusted = AXIsProcessTrusted()
        Probe.log("\(tag) start seconds=\(seconds) source=\(source ?? "record-button") accessibility=\(trusted) inputMonitoring=\(CGPreflightListenEventAccess()) countdown=\(settings.countdown)")
        if let source {
            // The same path a click takes: source overlay → Start recording.
            guard await startThroughOverlay(source, settings: settings, tag: tag) else { return }
        } else {
            rec.begin()
        }
        guard await waitFor({ rec.phase == .recording }, seconds: Double(settings.countdown) + 20) else {
            Probe.log("\(tag) failed never recording phase=\(rec.phase) alert=\(rec.alert?.message ?? "-")")
            return
        }
        if driveInput && !trusted { Probe.log("\(tag) WARNING: Accessibility is not granted to this app; macOS drops posted CGEvents, so the script will not move the cursor") }
        let recordingStart = hostNs()
        Probe.log("\(tag) recording started hostNs=\(recordingStart)")
        if driveInput, let display = Displays.resolve(settings.displayID) {
            await drive(display: display, duration: seconds, tag: tag)
        } else {
            try? await Task.sleep(for: .seconds(seconds))
        }
        Probe.log("\(tag) overlays while recording: sourceOverlayWindows=\(SourceOverlay.shared.windowCountForTesting) areaOverlayActive=\(AreaSelector.shared.isActive)")
        rec.stop()
        _ = await waitFor({ rec.phase == .idle }, seconds: 60)
        if let a = rec.alert { Probe.log("\(tag) alert \(a.title): \(a.message)") }
        let pkg = newestPackage(in: settings.storageDirectory)
        Probe.log("\(tag) \(pkg == nil ? "failed no package" : "ok") \(pkg?.path ?? "")")
        // After Stop the editor opens at once, in front, on the new recording.
        let editor = await waitFor({ EditorBridge.anyDocument() != nil }, seconds: 15)
        try? await Task.sleep(for: .seconds(1))          // the raise happens twice: right away and again after layout
        let front = EditorBridge.editorIsFrontAndKey
        Probe.log("\(tag) editorOpened=\(editor) editorInFront=\(front) appActive=\(NSApp.isActive) editorPackage=\(EditorBridge.anyDocument()?.project.packageURL.lastPathComponent ?? "-")")
    }

    /// Display / window / area: show the overlay, then press Start recording the way a click would.
    private static func startThroughOverlay(_ source: String, settings: AppSettings, tag: String) async -> Bool {
        switch source {
        case "display":
            SourceOverlay.shared.show(.display)
            try? await Task.sleep(for: .seconds(1.5))
            Probe.log("\(tag) overlay shown: windows=\(SourceOverlay.shared.windowCountForTesting)")
            SourceOverlay.shared.startForTesting()
        case "window":
            SourceOverlay.shared.show(.window)
            try? await Task.sleep(for: .seconds(1))
            let me = ProcessInfo.processInfo.processIdentifier
            guard let row = WindowHit.onScreenRows().first(where: { $0.layer == 0 && $0.pid != me && $0.bounds.width >= 200 && $0.bounds.height >= 150 }) else {
                Probe.log("\(tag) failed no window to record"); return false
            }
            SourceOverlay.shared.setHoverForTesting(row)
            try? await Task.sleep(for: .seconds(1))
            Probe.log("\(tag) overlay shown: windows=\(SourceOverlay.shared.windowCountForTesting) highlighting \(row.app) “\(row.title)” \(Int(row.bounds.width))x\(Int(row.bounds.height))")
            SourceOverlay.shared.startForTesting(windowRow: row)
        case "area":
            settings.areaRect = CGRect(x: 200, y: 150, width: 800, height: 500)
            AreaPicker.begin()
            try? await Task.sleep(for: .seconds(1.5))
            Probe.log("\(tag) area overlay shown: active=\(AreaSelector.shared.isActive)")
            AreaSelector.shared.confirmForTesting()
        default:
            Probe.log("\(tag) failed unknown --source \(source) (use display, window or area)"); return false
        }
        return true
    }

    /// Posts the scripted events and logs each with the host-clock ns the capture layer also uses.
    private static func drive(display: DisplayInfo, duration: Double, tag: String) async {
        let script = inputScript(display: CGRect(origin: .zero, size: display.frame.size), duration: duration)
        let begun = Date()
        await post(script, on: display, tag: tag)
        let remaining = duration - Date().timeIntervalSince(begun)
        if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
    }

    /// Posts `script` (display-local top-left points) and logs each event with the capture host clock.
    private static func post(_ script: [ScriptedEvent], on display: DisplayInfo, tag: String) async {
        let start = Date()
        Probe.log("\(tag) script events=\(script.count) displayPoints=\(Int(display.frame.width))x\(Int(display.frame.height)) hostNsAtScriptStart=\(hostNs())")
        for ev in script {
            let wait = ev.at - Date().timeIntervalSince(start)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            // Display-local top-left → global CG coordinates (origin of the main display is top-left).
            let global = CGPoint(x: display.frame.minX + ev.x, y: (NSScreen.screens.first?.frame.maxY ?? display.frame.maxY) - display.frame.maxY + ev.y)
            let hostBefore = hostNs()
            switch ev.kind {
            case .move:
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: global, mouseButton: .left)?.post(tap: .cghidEventTap)
            case .click:
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: global, mouseButton: .left)?.post(tap: .cghidEventTap)
                try? await Task.sleep(for: .milliseconds(40))
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: global, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            Probe.log("\(tag) event \(ev.kind.rawValue) x=\(Int(ev.x)) y=\(Int(ev.y)) hostNs=\(hostBefore)")
        }
    }

    /// Same clock the capture layer stamps events with (CMClockGetHostTimeClock, nanoseconds).
    static func hostNs() -> Int64 {
        let t = CMClockGetTime(CMClockGetHostTimeClock())
        return CMTimeConvertScale(t, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
    }

    private static func waitFor(_ cond: @MainActor () -> Bool, seconds: Double) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
        return cond()
    }

    private static func newestPackage(in dir: URL) -> URL? {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return urls.filter { $0.pathExtension == "yapcam" }.max { date($0) < date($1) }
    }
}
