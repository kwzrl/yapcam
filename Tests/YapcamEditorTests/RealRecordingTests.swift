import SwiftUI
import Testing
import Foundation
import AVFoundation
import AppKit
import YapcamCore
@testable import YapcamEditor

/// Runs against a real ScreenCaptureKit recording. YAPCAM_REAL_PKG=<package> (copied first, never modified);
/// optional YAPCAM_SNAPSHOT_DIR=<dir> keeps PNGs of the evaluated frames. Skipped when unset.
@MainActor @Suite(.serialized) struct RealRecordingTests {
    private func pixels(_ png: Data) -> (w: Int, h: Int, bytes: [UInt8]) {
        let rep = NSBitmapImageRep(data: png)!
        var out = [UInt8](repeating: 0, count: rep.pixelsWide * rep.pixelsHigh * 4)
        let ctx = CGContext(data: &out, width: rep.pixelsWide, height: rep.pixelsHigh, bitsPerComponent: 8, bytesPerRow: rep.pixelsWide * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        return (rep.pixelsWide, rep.pixelsHigh, out)
    }
    private func distinctColors(_ p: (w: Int, h: Int, bytes: [UInt8])) -> Int {
        var set = Set<UInt32>()
        var i = 0
        while i < p.bytes.count { set.insert(UInt32(p.bytes[i]) << 16 | UInt32(p.bytes[i + 1]) << 8 | UInt32(p.bytes[i + 2])); i += 4 * 97 }
        return set.count
    }
    private func meanAbsDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var sum = 0.0, n = 0, i = 0
        while i < min(a.count, b.count) { sum += abs(Double(a[i]) - Double(b[i])); n += 1; i += 4 * 53 }
        return sum / Double(max(n, 1))
    }

    @Test func openPreviewZoomAndExportARealRecording() async throws {
        try await exercise(includeAudio: false)
    }

    /// KNOWN FAILING on real recordings (render AudioTimeline silence-pad track makes AVAssetReader fail, -12842;
    /// see docs/status/editor.md). Kept so the fix can be verified with YAPCAM_REAL_PKG.
    @Test func realRecordingExportsWithSystemAudio() async throws {
        try await exercise(includeAudio: true)
    }

    private func exercise(includeAudio: Bool) async throws {
        guard let path = ProcessInfo.processInfo.environment["YAPCAM_REAL_PKG"] else { return }
        let keep = includeAudio ? nil : ProcessInfo.processInfo.environment["YAPCAM_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("real-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: work); defer { try? FileManager.default.removeItem(at: work) }
        try? FileManager.default.removeItem(at: work.appendingPathComponent("recording/.capture.lock"))
        let doc = try EditorDocument(package: work); let m = doc.model
        let dur = m.durationNs
        print("REAL duration \(Double(dur) / 1e9) s, clicks \(m.project.clickTimesNs.count), clips \(m.clips.count)")
        #expect(dur > 1_000_000_000)

        // Preview frames come from the real HEVC screen track.
        let source = ProjectRenderSource(doc.project)
        let f0 = try FrameSnapshot.png(source: source, atNs: 500_000_000)
        let p0 = pixels(f0)
        print("REAL frame 0.5 s: \(p0.w)×\(p0.h), distinct sampled colors \(distinctColors(p0))")
        #expect(p0.w == 1920 && p0.h == 1080 && distinctColors(p0) > 50)          // real screen content, not a flat color
        if let keep { try f0.write(to: keep.appending(path: "real-frame-0.png")) }

        // Zoom on the real recording: focus on the lower-left, check the evaluated crop and the picture.
        m.seek(toNs: 2_000_000_000); m.addZoomAtPlayhead()
        let z = m.zooms[0]
        m.setZoomFocus(id: z.id, x: 0.3, y: 0.7); m.setZoomScale(id: z.id, 2.5)
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        let mid = (m.zooms[0].startNs + m.zooms[0].endNs) / 2
        let g = try #require(m.project.frameGeometry(atNs: mid))
        print("REAL zoom crop at mid: \(g.crop)")
        #expect(g.crop.width < 0.5 && g.crop.width > 0.3)                          // 2.5× zoom
        #expect(abs(g.crop.midX - 0.3) < 0.1 || g.crop.minX <= 0.001)               // centred on the focus (or clamped to the left edge)
        let zoomed = try FrameSnapshot.png(source: source, atNs: mid)
        let before = try FrameSnapshot.png(source: source, atNs: 500_000_000)
        let diff = meanAbsDiff(pixels(zoomed).bytes, pixels(before).bytes)
        print("REAL mean abs pixel diff zoomed vs unzoomed: \(diff)")
        #expect(diff > 3)
        if let keep { try zoomed.write(to: keep.appending(path: "real-frame-zoom.png")) }

        // Look settings on a real recording.
        m.set("canvas.padding", number: 80); m.set("canvas.radius", number: 24)
        m.set("canvas.background.kind", string: "gradient")
        #expect(m.lastError == nil, "\(m.lastError ?? "")")
        let styled = try FrameSnapshot.png(source: source, atNs: 500_000_000)
        if let keep { try styled.write(to: keep.appending(path: "real-frame-styled.png")) }
        #expect(meanAbsDiff(pixels(styled).bytes, pixels(before).bytes) > 3)

        // Export 1080p30 with the real system audio, then inspect the written file.
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("real-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        doc.export.height = 1080; doc.export.fps = 30; doc.export.includeAudio = includeAudio
        let t0 = ContinuousClock.now
        doc.export.start(to: out); await doc.export.waitUntilFinished()
        let secs = Double((ContinuousClock.now - t0).components.seconds) + Double((ContinuousClock.now - t0).components.attoseconds) / 1e18
        #expect(doc.export.state == .done(out), "\(doc.export.state)")
        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video), audio = try await asset.loadTracks(withMediaType: .audio)
        let size = try await video[0].load(.naturalSize)
        print("REAL export: \(String(format: "%.1f", secs)) s for \(Double(dur) / 1e9) s of media, file duration \(duration), video \(video.count) audio \(audio.count) size \(size)")
        #expect(abs(duration - Double(dur) / 1e9) < 0.1 && video.count == 1 && audio.count == (includeAudio ? 1 : 0) && Int(size.height) == 1080)
        if let keep {
            let gen = AVAssetImageGenerator(asset: asset); gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
            let cg = try await gen.image(at: CMTime(value: mid, timescale: 1_000_000_000)).image
            let rep = NSBitmapImageRep(cgImage: cg)
            try rep.representation(using: .png, properties: [:])!.write(to: keep.appending(path: "real-export-zoom-frame.png"))
        }
        // The exported frame at the zoom midpoint must match what the editor evaluates there.
        let gen = AVAssetImageGenerator(asset: asset); gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let exported = NSBitmapImageRep(cgImage: try await gen.image(at: CMTime(value: mid, timescale: 1_000_000_000)).image)
        let expDiff = meanAbsDiff(pixels(exported.representation(using: .png, properties: [:])!).bytes, pixels(try FrameSnapshot.png(source: source, atNs: mid)).bytes)
        print("REAL exported-vs-editor frame mean abs diff at zoom mid: \(expDiff)")
        #expect(expDiff < 12)
    }
}

@MainActor @Suite(.serialized) struct RealRecordingPlaybackTests {
    /// Does the real preview player play a real recording (audio preparation uses the same timeline as export)?
    @Test func previewPlaysARealRecording() async throws {
        guard let path = ProcessInfo.processInfo.environment["YAPCAM_REAL_PKG"] else { return }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("realplay-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: work); defer { try? FileManager.default.removeItem(at: work) }
        try? FileManager.default.removeItem(at: work.appendingPathComponent("recording/.capture.lock"))
        let doc = try EditorDocument(package: work)
        try await Task.sleep(for: .seconds(2))                                    // audio preparation runs asynchronously
        print("REAL player error: \(String(describing: doc.player.error))")
        doc.model.togglePlay()
        try await Task.sleep(for: .milliseconds(500))
        print("REAL isPlaying after togglePlay: \(doc.model.isPlaying), currentNs \(doc.player.currentNs)")
        #expect(doc.player.error == nil, "\(doc.player.error ?? "")")
        #expect(doc.model.isPlaying || doc.model.playheadNs > 0)
        doc.model.pause()
    }
}

@MainActor @Suite(.serialized) struct RealRecordingLiveWindowTests {
    /// Real window + MTKView + display link on a real recording: playback must advance in real time and render at display rate.
    @Test func livePlaybackOfARealRecording() async throws {
        guard let path = ProcessInfo.processInfo.environment["YAPCAM_REAL_PKG"] else { return }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("reallive-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: work); defer { try? FileManager.default.removeItem(at: work) }
        try? FileManager.default.removeItem(at: work.appendingPathComponent("recording/.capture.lock"))
        _ = NSApplication.shared
        let doc = try EditorDocument(package: work)
        let host = NSHostingView(rootView: EditorView(document: doc))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1280, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .seconds(2))
        doc.model.seek(toNs: 0)
        let t0 = ContinuousClock.now
        doc.model.togglePlay()
        try await Task.sleep(for: .seconds(4))
        let wall = Double((ContinuousClock.now - t0).components.seconds) + Double((ContinuousClock.now - t0).components.attoseconds) / 1e18
        let advanced = Double(doc.player.currentNs) / 1e9
        let m = doc.player.metrics
        print("REAL live playback: wall \(String(format: "%.2f", wall)) s, timeline advanced \(String(format: "%.2f", advanced)) s, rendered \(m.renderedFrames) frames, \(String(format: "%.1f", m.framesPerSecond)) fps, dropped \(m.droppedFrames), playing \(doc.model.isPlaying), error \(String(describing: doc.player.error))")
        #expect(doc.player.error == nil)
        #expect(abs(advanced - min(wall, Double(doc.model.durationNs) / 1e9)) < 0.7)      // clock follows real time (or stopped at the end)
        doc.model.pause()
        // Scrub on the real recording and confirm the displayed frame time follows.
        doc.model.seek(toNs: 5_000_000_000, precise: true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(abs(Double(doc.player.currentNs) / 1e9 - 5.0) < 0.1)
        window.orderOut(nil)
    }
}
