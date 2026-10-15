import AppKit
import ScreenCaptureKit
import YapcamCore
import YapcamEditor
import AVFoundation
import YapcamRender

/// `Yapcam --live-e2e <dir>`: drives the real app path (toolbar → countdown → record → stop → editor
/// → export) through the same controller the buttons use, taking a screenshot of the whole display at
/// each step. Needs Screen Recording permission. Results are logged to probe.log and `<dir>/result.txt`.
@MainActor enum LiveE2E {
    static func run(into dir: URL, recordSeconds: Double = 5) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var report: [String] = []
        func log(_ s: String) { report.append(s); Probe.log("live-e2e \(s)") }

        let settings = AppSettings.shared
        let rec = RecordingController.shared
        settings.countdown = 3
        settings.sourceMode = .display
        settings.openEditorAfterRecording = true
        ToolbarPanelController.shared.show()
        try? await Task.sleep(for: .seconds(1))
        await shot(dir, "01-idle", log)

        rec.begin()
        try? await Task.sleep(for: .milliseconds(1500))
        await shot(dir, "02-countdown", log)
        guard await waitFor({ rec.phase == .recording }, seconds: 15) else {
            log("FAIL never reached recording; phase=\(rec.phase) alert=\(rec.alert?.message ?? "-")")
            return finish(dir, report)
        }
        try? await Task.sleep(for: .seconds(1.5))
        // Some cursor motion so the event track has content.
        for i in 0..<20 {
            CGWarpMouseCursorPosition(CGPoint(x: 300 + Double(i) * 30, y: 400 + sin(Double(i) / 3) * 80))
            try? await Task.sleep(for: .milliseconds(60))
        }
        await shot(dir, "03-recording", log)
        try? await Task.sleep(for: .seconds(max(0, recordSeconds - 3)))
        rec.stop()
        guard await waitFor({ rec.phase == .idle }, seconds: 30) else { log("FAIL stop did not finish; phase=\(rec.phase)"); return finish(dir, report) }
        if let a = rec.alert { log("ALERT after stop: \(a.title) — \(a.message)") }

        let package = newestPackage(in: settings.storageDirectory)
        log("package \(package?.path ?? "none")")
        try? await Task.sleep(for: .seconds(3))
        await shot(dir, "04-editor", log)

        guard let doc = EditorBridge.anyDocument() else { log("FAIL no editor window opened"); return finish(dir, report) }
        log("editor opened: \(doc.title), duration \(doc.project.durationNs / 1_000_000) ms")
        let out = dir.appending(path: "export.mp4")
        doc.export.height = 1080
        doc.export.start(to: out)
        await doc.export.waitUntilFinished()
        log("export state: \(doc.export.state)")
        if case .failed = doc.export.state {
            // Re-run through render directly to get the unwrapped error.
            do {
                let direct = dir.appending(path: "export-direct.mp4")
                let ex = try Exporter(project: doc.project, settings: ExportSettings(format: .mp4, codec: .h264, outputHeight: 1080, fps: 30, quality: 0.8, includeAudio: true), destination: direct)
                _ = try await ex.run(progress: { _ in })
                log("direct exporter OK \(direct.path)")
            } catch { let ns = error as NSError; log("direct exporter error: \(error) | \(ns.domain) \(ns.code) \(ns.userInfo)") }
        }
        if case .failed = doc.export.state {
            // Isolate: audio off, then the raw video reader.
            do {
                let ex = try Exporter(project: doc.project, settings: ExportSettings(format: .mp4, codec: .h264, outputHeight: 1080, fps: 30, quality: 0.8, includeAudio: false), destination: dir.appending(path: "export-noaudio.mp4"))
                _ = try await ex.run(progress: { _ in })
                log("export WITHOUT audio OK")
            } catch { log("export without audio also fails: \(error)") }
            if let rows = try? doc.project.query("{\"q\":\"audio_ranges\"}", as: JSONValue.self) { log("audio_ranges \(rows)") }
            if let pkg = package {
                for rel in ["recording/seg-000/screen.mov", "recording/seg-000/system.m4a"] {
                    let asset = AVURLAsset(url: pkg.appending(path: rel))
                    let type: AVMediaType = rel.hasSuffix("mov") ? .video : .audio
                    do {
                        let track = try await asset.loadTracks(withMediaType: type).first
                        let r = try AVAssetReader(asset: asset)
                        let out = AVAssetReaderTrackOutput(track: track!, outputSettings: type == .video ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] : [AVFormatIDKey: kAudioFormatLinearPCM])
                        r.add(out); r.startReading()
                        var n = 0
                        while out.copyNextSampleBuffer() != nil { n += 1 }
                        let dur = try await asset.load(.duration)
                        let tr = try await track!.load(.timeRange)
                        log("asset \(rel) duration \(dur.seconds) trackRange \(tr.start.seconds)+\(tr.duration.seconds)")
                        log("reader \(rel): status \(r.status.rawValue) samples \(n) error \(String(describing: r.error as NSError?))")
                    } catch { log("reader \(rel) setup failed: \(error as NSError)") }
                }
            }
        }
        if case .failed = doc.export.state {
            // Hypothesis: the project's audio range is longer than the real m4a (5.028 s vs 4.98 s). Trim 100 ms off the end and retry with audio.
            do {
                let d = doc.project.durationNs
                try doc.project.apply(.deleteRange(startNs: d - 100_000_000, endNs: d))
                let ex = try Exporter(project: doc.project, settings: ExportSettings(format: .mp4, codec: .h264, outputHeight: 1080, fps: 30, quality: 0.8, includeAudio: true), destination: dir.appending(path: "export-trimmed.mp4"))
                _ = try await ex.run(progress: { _ in })
                log("HYPOTHESIS CONFIRMED: export with audio succeeds after trimming the tail 100 ms")
            } catch { log("hypothesis not confirmed: \(error)") }
        }
        try? await Task.sleep(for: .seconds(1))
        await shot(dir, "05-after-export", log)
        finish(dir, report)
    }

    private static func finish(_ dir: URL, _ report: [String]) {
        try? report.joined(separator: "\n").write(to: dir.appending(path: "result.txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private static func waitFor(_ cond: @MainActor () -> Bool, seconds: Double) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
        return cond()
    }

    private static func newestPackage(in dir: URL) -> URL? {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "yapcam" }
            .max { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast
                 < (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
    }

    /// Full-display screenshot including Yapcam's own windows (nothing excluded).
    private static func shot(_ dir: URL, _ name: String, _ log: (String) -> Void) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let d = content.displays.first else { log("shot \(name): no display"); return }
            let cfg = SCStreamConfiguration()
            cfg.width = Int(d.width); cfg.height = Int(d.height); cfg.showsCursor = true
            let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg)
            let rep = NSBitmapImageRep(cgImage: img)
            try rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(name).png"))
            log("shot \(name) ok")
        } catch { log("shot \(name) failed: \(error.localizedDescription)") }
    }
}
