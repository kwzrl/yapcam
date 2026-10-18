@preconcurrency import AVFoundation
import Foundation

public struct AudioScrubGrain: Sendable, Equatable {
    public let timelineNs: Int64
    public let velocity: Double
    public let channels: Int
    public let sampleRate: Double
    /// Interleaved Float32 PCM with short edge fades already applied.
    public let samples: [Float]

    public init(timelineNs: Int64,velocity: Double,channels: Int,sampleRate: Double,samples: [Float]) throws {
        guard timelineNs>=0,velocity.isFinite,channels>0,sampleRate.isFinite,sampleRate>0,
              samples.count%channels==0,samples.allSatisfy(\.isFinite) else {
            throw RenderError.invalidSettings("Invalid audio scrub grain")
        }
        self.timelineNs=timelineNs; self.velocity=velocity; self.channels=channels
        self.sampleRate=sampleRate
        self.samples=Self.directional(samples,channels: channels,velocity: velocity,sampleRate: sampleRate)
    }

    static func directional(_ input: [Float],channels: Int,velocity: Double,sampleRate: Double) -> [Float] {
        guard abs(velocity)>0.001,!input.isEmpty else { return [] }
        let frames=input.count/channels
        var output=[Float](repeating: 0,count: input.count)
        let fadeFrames=max(1,min(frames/2,Int((sampleRate*0.005).rounded())))
        for outputFrame in 0..<frames {
            let sourceFrame=velocity<0 ? frames-1-outputFrame : outputFrame
            let fadeIn=min(1,Float(outputFrame+1)/Float(fadeFrames))
            let fadeOut=min(1,Float(frames-outputFrame)/Float(fadeFrames))
            let gain=min(fadeIn,fadeOut)
            for channel in 0..<channels {
                output[outputFrame*channels+channel]=input[sourceFrame*channels+channel]*gain
            }
        }
        return output
    }
}

/// Reads short grains from the exact mixed preview/export timeline. The editor
/// calls `scrub` while dragging and `silence` after 80 ms without pointer motion.
/// AVAudioUnitTimePitch changes drag rate without changing pitch; reverse motion
/// reverses complete sample frames before scheduling.
@MainActor public final class AudioScrubber {
    public static let grainDurationNs: Int64 = 40_000_000
    public var onGrain: (@MainActor @Sendable (AudioScrubGrain) -> Void)?

    private let timeline: AudioTimeline
    private let durationNs: Int64
    private let engine=AVAudioEngine()
    private let player=AVAudioPlayerNode()
    private let timePitch=AVAudioUnitTimePitch()
    private let format: AVAudioFormat
    private var generation=0

    private init(timeline: AudioTimeline,durationNs: Int64) throws {
        self.timeline=timeline; self.durationNs=durationNs
        guard let format=AVAudioFormat(standardFormatWithSampleRate: 48_000,channels: 2) else {
            throw RenderError.unavailable("Audio scrub playback format is unavailable")
        }
        self.format=format
        engine.attach(player); engine.attach(timePitch)
        engine.connect(player,to: timePitch,format: format)
        engine.connect(timePitch,to: engine.mainMixerNode,format: format)
        engine.prepare()
    }

    public static func prepare(project: any RenderProjectSource,
                               speechEnhancement: SpeechEnhancementSettings? = nil) async throws -> AudioScrubber {
        let source=try project.renderSnapshot()
        guard source.durationNs>0 else { throw RenderError.invalidSettings("Cannot prepare audio scrubbing for an empty timeline") }
        let timeline=try await AudioTimeline.prepare(project: source,range: 0..<source.durationNs,
                                                     speechEnhancement: speechEnhancement)
        return try await MainActor.run { try AudioScrubber(timeline: timeline,durationNs: source.durationNs) }
    }

    public func scrub(toNs requestedNs: Int64,velocity: Double) {
        generation+=1
        let current=generation
        guard velocity.isFinite,abs(velocity)>0.001,durationNs>0,timeline.hasAudio else { silence(); return }
        let timelineNs=min(max(0,requestedNs),max(0,durationNs-1))
        let timeline=timeline
        let grainDurationNs=Self.grainDurationNs
        Task { [weak self] in
            do {
                let pcm=try await Task.detached(priority: .userInitiated) {
                    try Self.read(timeline: timeline,atNs: timelineNs,durationNs: grainDurationNs)
                }.value
                guard let self,self.generation==current else { return }
                let grain=try AudioScrubGrain(timelineNs: timelineNs,velocity: velocity,channels: 2,sampleRate: 48_000,samples: pcm)
                guard !grain.samples.isEmpty else { self.silence(); return }
                try self.play(grain)
                self.onGrain?(grain)
            } catch {
                guard let self,self.generation==current else { return }
                self.silence()
            }
        }
    }

    public func silence() {
        generation+=1
        player.stop()
    }

    private func play(_ grain: AudioScrubGrain) throws {
        if !engine.isRunning { try engine.start() }
        let frames=grain.samples.count/grain.channels
        guard let buffer=AVAudioPCMBuffer(pcmFormat: format,frameCapacity: AVAudioFrameCount(frames)),
              let channels=buffer.floatChannelData else { throw RenderError.unavailable("Cannot allocate audio scrub buffer") }
        buffer.frameLength=AVAudioFrameCount(frames)
        for frame in 0..<frames {
            for channel in 0..<grain.channels { channels[channel][frame]=grain.samples[frame*grain.channels+channel] }
        }
        timePitch.rate=Float(min(4,max(0.25,abs(grain.velocity))))
        player.stop(); player.scheduleBuffer(buffer,at: nil,options: .interrupts); player.play()
    }

    nonisolated private static func read(timeline: AudioTimeline,atNs: Int64,durationNs: Int64) throws -> [Float] {
        let reader=try AVAssetReader(asset: timeline.composition)
        reader.timeRange=CMTimeRange(start: CMTime(value: atNs,timescale: 1_000_000_000),
                                     duration: CMTime(value: durationNs,timescale: 1_000_000_000))
        let settings: [String:Any]=[
            AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:48_000,AVNumberOfChannelsKey:2,
            AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsBigEndianKey:false,
            AVLinearPCMIsNonInterleaved:false
        ]
        let output=AVAssetReaderAudioMixOutput(audioTracks: timeline.composition.tracks(withMediaType: .audio),audioSettings: settings)
        output.audioMix=timeline.mix
        guard reader.canAdd(output) else { throw RenderError.decode("Cannot add audio scrub reader") }
        reader.add(output)
        guard reader.startReading() else { throw RenderError.decode(reader.error?.localizedDescription ?? "Cannot start audio scrub reader") }
        var result: [Float]=[]
        while let sample=output.copyNextSampleBuffer() {
            guard let block=CMSampleBufferGetDataBuffer(sample) else { continue }
            let length=CMBlockBufferGetDataLength(block)
            guard length%MemoryLayout<Float>.stride==0 else { throw RenderError.decode("Invalid audio scrub PCM layout") }
            if length==0 { continue }
            var values=[Float](repeating: 0,count: length/MemoryLayout<Float>.stride)
            let status=values.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block,atOffset: 0,dataLength: length,destination: bytes.baseAddress!)
            }
            guard status==kCMBlockBufferNoErr else { throw RenderError.decode("Cannot read audio scrub PCM") }
            result.append(contentsOf: values)
        }
        guard reader.status == .completed else { throw RenderError.decode(reader.error?.localizedDescription ?? "Audio scrub reader stopped") }
        return result
    }
}
