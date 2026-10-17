import SwiftUI
@preconcurrency import AVFoundation
import YapcamCore

/// One loudness sample of the edited timeline (peak of a 20 ms window of the microphone, 0…1).
public struct WavePoint: Equatable, Sendable { public var tlNs: Int64; public var amp: Float }

/// Peak envelope of an audio file, 20 ms windows from the start of the file. Own code (AVAssetReader + Accelerate-free max scan).
enum WaveformAnalysis {
    static let windowNs: Int64 = 20_000_000

    static func peaks(of url: URL) async throws -> [Float] {
        try await Task.detached(priority: .utility) { () throws -> [Float] in
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 8_000, AVNumberOfChannelsKey: 1])
            guard reader.canAdd(output) else { return [] }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CoreError.status(4, "Cannot decode audio") }
            defer { reader.cancelReading() }
            var windows: [Float] = []
            let perWindow = 8_000 * Int(windowNs) / 1_000_000_000          // 160 samples
            var index = 0
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                guard length > 0, length % MemoryLayout<Float>.size == 0 else { continue }
                var floats = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                guard floats.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }) == kCMBlockBufferNoErr else { continue }
                let pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), timescale: 8_000, method: .roundHalfAwayFromZero).value
                var i = 0
                while i < floats.count {
                    let absolute = Int(pts) + i, w = absolute / perWindow
                    let n = min(floats.count - i, (w + 1) * perWindow - absolute)
                    var m: Float = 0
                    for k in i..<(i + n) { m = max(m, abs(floats[k])) }
                    if w >= windows.count { windows.append(contentsOf: [Float](repeating: 0, count: w - windows.count + 1)) }
                    windows[w] = max(windows[w], m)
                    i += n; index = w
                }
            }
            _ = index
            return windows
        }.value
    }

    /// Maps per-file peaks onto the edited timeline through the `audio_ranges` rows (cuts, speed and repeats included).
    static func timelinePoints(rows: [(path: String, fileStartNs: Int64, fileEndNs: Int64, tlStartNs: Int64, tlEndNs: Int64)],
                               peaks: [String: [Float]]) -> [WavePoint] {
        var out: [WavePoint] = []
        for r in rows {
            guard let p = peaks[r.path], r.fileEndNs > r.fileStartNs, r.tlEndNs > r.tlStartNs else { continue }
            let fileLen = Double(r.fileEndNs - r.fileStartNs), tlLen = Double(r.tlEndNs - r.tlStartNs)
            let first = Int(r.fileStartNs / windowNs), last = min(p.count - 1, Int((r.fileEndNs - 1) / windowNs))
            guard first <= last else { continue }
            for w in first...last {
                let mid = Double(Int64(w) * windowNs + windowNs / 2 - r.fileStartNs).clamped(0, fileLen)
                out.append(WavePoint(tlNs: r.tlStartNs + Int64(mid / fileLen * tlLen), amp: p[w]))
            }
        }
        return out.sorted { $0.tlNs < $1.tlNs }
    }
}
private extension Double { func clamped(_ lo: Double, _ hi: Double) -> Double { min(max(self, lo), hi) } }

extension EditorModel {
    /// Rebuilds the waveform for the current timeline (peaks are cached per file; only the mapping is redone).
    public func refreshWaveform() async {
        guard showWaveform, !isClosed else { return }
        let started = revision
        guard let points = try? await project.waveformPoints(), !isClosed, revision == started || true else { return }
        if points != waveform { waveform = points }
    }
    public func setShowWaveform(_ on: Bool) {
        showWaveform = on; defaults.set(on, forKey: "editor.showWaveform")
        if on { Task { await refreshWaveform() } } else { waveform = [] }
    }
}

/// Mirrored bars of the microphone level across the clip track (drawn per pixel column, max of the points in it).
struct WaveformLayer: View {
    let points: [WavePoint]
    let geometry: TimelineGeometry
    let width: CGFloat, height: CGFloat
    var body: some View {
        Canvas { ctx, size in
            guard !points.isEmpty else { return }
            let columns = max(Int(size.width / 2), 1), step = size.width / CGFloat(columns)
            var peaks = [Float](repeating: 0, count: columns + 1)
            for p in points {
                let c = Int(geometry.x(forNs: p.tlNs) / step)
                if c >= 0 && c <= columns { peaks[c] = max(peaks[c], p.amp) }
            }
            var path = Path()
            let mid = size.height / 2
            for (c, a) in peaks.enumerated() where a > 0.002 {
                // Perceptual curve so quiet speech is still visible.
                let h = max(CGFloat(pow(a, 0.5)) * (size.height - 10) / 2, 0.5)
                path.addRoundedRect(in: CGRect(x: CGFloat(c) * step, y: mid - h, width: max(step - 0.8, 0.8), height: h * 2), cornerSize: CGSize(width: 0.5, height: 0.5))
            }
            ctx.fill(path, with: .color(.white.opacity(0.5)))
        }
        .frame(width: width, height: height).allowsHitTesting(false).accessibilityHidden(true)
    }
}
