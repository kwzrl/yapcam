import AppKit
import ApplicationServices
import CoreMedia
import YapcamCapture

/// Launch-flag self-tests for QA and CI. All results go to ~/Library/Logs/Yapcam/probe.log.
///
///   --capture-selftest <sec> [--target window:<id>|area:x,y,w,h] [--pause-after <sec>]
///   --ui-record-selftest <sec>     toolbar + HUD, recording through RecordingController
///   --drive-input-selftest <sec>   same, plus scripted CGEvent moves/clicks from inside the app
@MainActor enum SelfTests {
    // MARK: Argument parsing (pure, unit-tested)

    enum TargetSpec: Equatable {
        case window(UInt32)
        case area(CGRect)
    }

    struct CaptureArgs: Equatable {
        var seconds: Double
        var target: TargetSpec?
        var pauseAfter: Double?
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
            if v.hasPrefix("window:") {
                guard let id = UInt32(v.dropFirst(7)), id != 0 else { error = "bad window id in \(v)"; return nil }
                out.target = .window(id)
            } else if v.hasPrefix("area:") {
                let p = v.dropFirst(5).split(separator: ",").compactMap { Double($0) }
                guard p.count == 4, p[2] >= 16, p[3] >= 16, p[0] >= 0, p[1] >= 0 else { error = "area needs x,y,w,h (w,h ≥ 16): \(v)"; return nil }
                out.target = .area(CGRect(x: p[0], y: p[1], width: p[2], height: p[3]))
            } else { error = "unknown --target \(v) (use window:<id> or area:x,y,w,h)"; return nil }
        }
        if let a = args.firstIndex(of: "--pause-after") {
            guard args.indices.contains(a + 1), let s = Double(args[a + 1]), s > 0 else { error = "--pause-after needs seconds"; return nil }
            guard s < out.seconds else { error = "--pause-after must be shorter than the recording"; return nil }
            out.pauseAfter = s
        }
        return out
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
        case .window(let id)?: target = .window(CGWindowID(id))
        case .area(let r)?:
            guard let d = Displays.resolve(0) else { Probe.log("capture-selftest failed no display"); return }
            target = .area(display: d.id, rect: r)
        case nil: break
        }
        Probe.log("capture-selftest start seconds=\(parsed.seconds) target=\(String(describing: target)) pauseAfter=\(String(describing: parsed.pauseAfter))")
        do {
            let url = try await CaptureSelfTest.run(seconds: parsed.seconds, target: target, pauseAfter: parsed.pauseAfter)
            Probe.log("capture-selftest ok \(url.path)")
        } catch { Probe.log("capture-selftest failed \(UserMessage.describe(error)) | \(error)") }
    }

    // MARK: --ui-record-selftest / --drive-input-selftest

    /// Records through the same `RecordingController` path as the Record button, with the toolbar and HUD
    /// on screen. `driveInput` additionally posts scripted CGEvents while recording.
    static func runUIRecord(seconds: Double, driveInput: Bool) async {
        let tag = driveInput ? "drive-input-selftest" : "ui-record-selftest"
        guard seconds > 0, seconds <= 3600 else { Probe.log("\(tag) failed seconds must be in (0, 3600]"); return }
        let settings = AppSettings.shared, rec = RecordingController.shared
        // Run with fixed settings but leave the user's preferences as they were.
        let saved = (settings.countdown, settings.openEditorAfterRecording, settings.sourceMode)
        defer { (settings.countdown, settings.openEditorAfterRecording, settings.sourceMode) = saved }
        settings.sourceMode = .display
        settings.openEditorAfterRecording = false
        ToolbarPanelController.shared.show()
        try? await Task.sleep(for: .seconds(1))
        let trusted = AXIsProcessTrusted()
        Probe.log("\(tag) start seconds=\(seconds) accessibility=\(trusted) inputMonitoring=\(CGPreflightListenEventAccess()) countdown=\(settings.countdown)")
        rec.begin()
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
        rec.stop()
        _ = await waitFor({ rec.phase == .idle }, seconds: 60)
        if let a = rec.alert { Probe.log("\(tag) alert \(a.title): \(a.message)") }
        let pkg = newestPackage(in: settings.storageDirectory)
        Probe.log("\(tag) \(pkg == nil ? "failed no package" : "ok") \(pkg?.path ?? "")")
    }

    /// Posts the scripted events and logs each with the host-clock ns the capture layer also uses.
    private static func drive(display: DisplayInfo, duration: Double, tag: String) async {
        let script = inputScript(display: CGRect(origin: .zero, size: display.frame.size), duration: duration)
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
        let remaining = duration - Date().timeIntervalSince(start)
        if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
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
