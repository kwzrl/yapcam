import Foundation
@preconcurrency import AVFoundation
import YapcamCore
@testable import YapcamRender

/// Bounded-memory fixture: streamed mono PCM and an optional looping decoded clip.
/// 10-minute sync isolates mux clocks; soak/preview also decode real IOSurfaces.
final class LongRunSource: RenderProjectSource, @unchecked Sendable {
    let packageURL: URL
    let durationNs: Int64
    let pulses: [Int64]
    let decodedVideo: Bool
    init(package: URL,durationSeconds: Int,pulses: [Int64],decodedVideo: Bool) throws {
        packageURL=package; durationNs=Int64(durationSeconds)*1_000_000_000
        self.pulses=pulses; self.decodedVideo=decodedVideo
        let files=FileManager.default
        let recording=package.appendingPathComponent("recording",isDirectory: true)
        try files.createDirectory(at: recording,withIntermediateDirectories: true)
        if decodedVideo {
            let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam/recording/seg-000/screen.mov")
            try files.copyItem(at: fixture,to: recording.appendingPathComponent("screen.mov"))
        }
        let segments: [[String: Any]]=decodedVideo ? [["index":0,"dir":"","src_start_ns":0,"duration_ns":durationNs,"files":["screen":"screen.mov"],"track_start_ns":[:]]] : []
        try JSONSerialization.data(withJSONObject: ["segments":segments]).write(to: recording.appendingPathComponent("session.json"))
        try writeAudio(to: recording.appendingPathComponent("signal.caf"),seconds: durationSeconds)
    }
    func frame(atNs ns: Int64) throws -> YcFrame {
        var f=YcFrame(); f.tl_ns=ns; f.canvas_w=1920; f.canvas_h=1080; f.click_progress = -1
        let flash=pulses.contains { ns >= $0 && ns < $0+33_333_333 }
        let color: Float=flash ? 1 : 0
        f.background_color=(color,color,color,1); f.system_gain=1
        if decodedVideo && !flash {
            f.screen.present=1; f.screen.segment=0; f.screen.src_ns=ns
            f.screen.file_ns=ns%3_000_000_000
            f.screen_dest = .init(x: 192,y: 60,w: 1536,h: 960)
            let zoom=1-0.25*(sin(Double(ns)/1e9*Double.pi)*0.5+0.5)
            f.screen_crop = .init(x: (1-zoom)/2,y: (1-zoom)/2,w: zoom,h: zoom)
            f.screen_corner_radius=24; f.shadow_radius=32; f.shadow_opacity=0.25
            f.motion_blur=0.3
        }
        return f
    }
    func renderSnapshot() throws -> any RenderProjectSource { self }
    func renderClips() throws -> [RenderClip] { [] }
    func renderBackgroundAsset(index: UInt32) throws -> URL { throw RenderError.missingMedia("No background in benchmark") }
    func renderAudioRanges() throws -> [RenderAudioRange]? {
        [.init(track: .systemAudio,path: "recording/signal.caf",fileStartNs: 0,fileEndNs: durationNs,tlStartNs: 0,tlEndNs: durationNs,gainStart: 1,gainEnd: 1)]
    }
    private func writeAudio(to url: URL,seconds: Int) throws {
        guard let format=AVAudioFormat(standardFormatWithSampleRate: 48_000,channels: 1),
              let buffer=AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 48_000),let channel=buffer.floatChannelData?[0] else { throw RenderError.write("Cannot allocate benchmark audio buffer") }
        let file=try AVAudioFile(forWriting: url,settings: format.settings)
        buffer.frameLength=48_000
        // One reusable second plus a short pulse; fixture generation never scales
        // resident memory or per-sample transcendental work with media duration.
        let quiet=(0..<48_000).map { Float((decodedVideo ? 0.01 : 0)*sin(2*Double.pi*1000*Double($0)/48_000)) }
        let loud=(0..<2400).map { Float(0.5*sin(2*Double.pi*1000*Double($0)/48_000)) }
        let pulseFrames=pulses.map { $0*48_000/1_000_000_000 }
        for second in 0..<seconds {
            try Task.checkCancellation()
            quiet.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!,count: 48_000) }
            let blockStart=Int64(second)*48_000, blockEnd=blockStart+48_000
            for pulse in pulseFrames {
                let start=max(blockStart,pulse), end=min(blockEnd,pulse+2400)
                if end>start {
                    for i in start..<end { channel[Int(i-blockStart)]=loud[Int(i-pulse)] }
                }
            }
            try file.write(from: buffer)
        }
    }
}
