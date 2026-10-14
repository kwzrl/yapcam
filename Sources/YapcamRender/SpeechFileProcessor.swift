@preconcurrency import AVFoundation
import Foundation

private final class SpeechReadCancellation: @unchecked Sendable {
    private let lock=NSLock()
    private var reader: AVAssetReader?
    private var cancelled=false
    func attach(_ reader: AVAssetReader) throws { try lock.withLock { if cancelled { throw CancellationError() }; self.reader=reader } }
    func check() throws { try Task.checkCancellation(); if lock.withLock({ cancelled }) { throw CancellationError() } }
    func cancel() { let reader=lock.withLock { cancelled=true; return self.reader }; reader?.cancelReading() }
}
private final class SpeechSourceTrack: @unchecked Sendable {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let channels: Int
    let endFrame: Int64
    init(asset: AVURLAsset,track: AVAssetTrack,channels: Int,endFrame: Int64) { self.asset=asset; self.track=track; self.channels=channels; self.endFrame=endFrame }
}

public extension SpeechEnhancer {
    /// Offline, streamed mono/stereo processing to lossless 48kHz Float32 CAF/WAV.
    /// Keeps file-local sample positions, including gaps; never overwrites input or destination.
    /// Native compressed decoders may be unavailable under restricted execution: explicit error.
    static func processFile(_ source: URL,to destination: URL,settings: SpeechEnhancementSettings = .init(),progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> SpeechEnhancementReport {
        try settings.validate(); try Task.checkCancellation()
        guard source.isFileURL,destination.isFileURL,["caf","wav"].contains(destination.pathExtension.lowercased()) else { throw RenderError.invalidSettings("Speech output must be a local CAF or WAV file") }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw RenderError.write("Speech output already exists") }
        let asset=AVURLAsset(url: source)
        guard let track=try await asset.loadTracks(withMediaType: .audio).first else { throw RenderError.decode("Speech input has no audio track") }
        let descriptions=try await track.load(.formatDescriptions)
        guard let description=descriptions.first,let format=CMAudioFormatDescriptionGetStreamBasicDescription(description) else { throw RenderError.decode("Speech input audio format is unavailable") }
        let channels=Int(format.pointee.mChannelsPerFrame)
        guard (1...2).contains(channels) else { throw RenderError.unavailable("Offline speech processing supports mono/stereo inputs") }
        let timeRange=try await track.load(.timeRange)
        let end=CMTimeConvertScale(timeRange.end,timescale: 48_000,method: .roundHalfAwayFromZero)
        guard end.isNumeric,end.value>0 else { throw RenderError.decode("Speech input has invalid duration") }
        let context=SpeechSourceTrack(asset: asset,track: track,channels: channels,endFrame: end.value)
        let cancellation=SpeechReadCancellation()
        let task=Task.detached(priority: .userInitiated) { try processFile(context,to: destination,settings: settings,cancellation: cancellation,progress: progress) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { cancellation.cancel(); task.cancel() }
    }
    private static func processFile(_ source: SpeechSourceTrack,to destination: URL,settings: SpeechEnhancementSettings,cancellation: SpeechReadCancellation,progress: @Sendable (Double) -> Void) throws -> SpeechEnhancementReport {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-speech-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let intermediate=directory.appendingPathComponent("processed.caf")
        let partial=destination.deletingLastPathComponent().appendingPathComponent(".yapcam-speech-\(UUID().uuidString).\(destination.pathExtension)")
        defer { try? FileManager.default.removeItem(at: partial) }
        let channels=source.channels
        let format=AVAudioFormat(commonFormat: .pcmFormatFloat32,sampleRate: 48_000,channels: AVAudioChannelCount(channels),interleaved: false)!
        let reader=try AVAssetReader(asset: source.asset)
        let output=AVAssetReaderTrackOutput(track: source.track,outputSettings: [AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:48_000,AVNumberOfChannelsKey:channels,AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsBigEndianKey:false,AVLinearPCMIsNonInterleaved:false])
        output.alwaysCopiesSampleData=false
        guard reader.canAdd(output) else { throw RenderError.decode("Speech PCM decoder is unavailable") }
        reader.add(output); try cancellation.attach(reader); try cancellation.check()
        guard reader.startReading() else { throw RenderError.unavailable(reader.error?.localizedDescription ?? "Speech decoder unavailable") }
        defer { reader.cancelReading() }
        var processor=try SpeechProcessor48k(channels: channels,settings: settings)
        var meter=try LoudnessMeter48k(channels: channels), written: Int64=0
        try autoreleasepool {
            let file=try AVAudioFile(forWriting: intermediate,settings: format.settings,commonFormat: .pcmFormatFloat32,interleaved: false)
            func write(_ samples: [Float]) throws {
                let processed=try processor.process(samples)
                try meter.process(interleaved: processed)
                try writePCM(processed,channels: channels,format: format,to: file)
                written+=Int64(processed.count/channels)
            }
            while let sample=output.copyNextSampleBuffer() {
                try cancellation.check()
                guard let block=CMSampleBufferGetDataBuffer(sample) else { throw RenderError.decode("Speech sample has no PCM data") }
                let length=CMBlockBufferGetDataLength(block)
                guard length%(channels*4)==0 else { throw RenderError.decode("Speech PCM layout is invalid") }
                var pcm=[Float](repeating: 0,count: length/4)
                let status=pcm.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset: 0,dataLength: length,destination: $0.baseAddress!) }
                guard status==kCMBlockBufferNoErr else { throw RenderError.decode("Cannot read speech PCM") }
                let time=CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample),timescale: 48_000,method: .roundHalfAwayFromZero)
                guard time.isNumeric else { throw RenderError.decode("Speech sample has invalid timestamp") }
                let start=max(0,time.value)
                while written<min(start,source.endFrame) {
                    try cancellation.check(); try write([Float](repeating: 0,count: Int(min(4096,min(start,source.endFrame)-written))*channels))
                }
                let skip=Int(min(Int64(pcm.count/channels),max(0,written-time.value)))
                let count=Int(min(Int64(pcm.count/channels-skip),max(0,source.endFrame-written)))
                if count>0 { try write(Array(pcm[skip*channels..<(skip+count)*channels])) }
                progress(min(0.5,Double(written)/Double(source.endFrame)*0.5))
            }
            try cancellation.check()
            guard reader.status == .completed else { throw RenderError.decode(reader.error?.localizedDescription ?? "Speech decoder stopped") }
            while written<source.endFrame { try cancellation.check(); try write([Float](repeating: 0,count: Int(min(4096,source.endFrame-written))*channels)) }
        }
        let before=meter.integratedLUFS
        var gainDB=settings.normalizeLoudness ? before.map { min(24,settings.targetLUFS-$0) } ?? 0 : 0
        var final: Double?, finalPeak=0.0, limited=false
        for attempt in 0..<4 {
            try cancellation.check()
            var result=try LoudnessMeter48k(channels: channels), limiter=SpeechPeakLimiter(channels: channels,ceilingDBFS: settings.peakCeilingDBFS)
            try autoreleasepool {
                let input=try AVAudioFile(forReading: intermediate,commonFormat: .pcmFormatFloat32,interleaved: false)
                let output=try AVAudioFile(forWriting: partial,settings: format.settings,commonFormat: .pcmFormatFloat32,interleaved: false)
                guard let buffer=AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 4096) else { throw RenderError.write("Cannot allocate speech buffer") }
                var frames: Int64=0
                while frames<written {
                    try cancellation.check(); try input.read(into: buffer,frameCount: AVAudioFrameCount(min(4096,written-frames)))
                    guard buffer.frameLength>0,let data=buffer.floatChannelData else { throw RenderError.decode("Processed speech file ended early") }
                    var pcm=[Float](repeating: 0,count: Int(buffer.frameLength)*channels)
                    for frame in 0..<Int(buffer.frameLength) { for channel in 0..<channels { pcm[frame*channels+channel]=data[channel][frame] } }
                    let normalized=limiter.process(pcm,normalizationGain: pow(10,gainDB/20))
                    try result.process(interleaved: normalized); try writePCM(normalized,channels: channels,format: format,to: output)
                    frames+=Int64(buffer.frameLength)
                    // Extra normalization attempts retain monotonic progress.
                    if attempt==0 { progress(0.5+Double(frames)/Double(written)*0.45) }
                }
            }
            final=result.integratedLUFS; finalPeak=limiter.peak; limited=limiter.limited
            guard attempt<3,settings.normalizeLoudness,let final,abs(final-settings.targetLUFS)>=0.2,gainDB<24 else { break }
            gainDB=min(24,gainDB+settings.targetLUFS-final)
            try FileManager.default.removeItem(at: partial)
        }
        try cancellation.check()
        let verified=try AVAudioFile(forReading: partial)
        guard verified.length==written,verified.fileFormat.sampleRate==48_000,Int(verified.fileFormat.channelCount)==channels else { throw RenderError.verification("Speech output timing/format verification failed") }
        try FileManager.default.moveItem(at: partial,to: destination); progress(1)
        return SpeechEnhancementReport(frames: written,channels: channels,targetLUFS: settings.targetLUFS,processedLUFS: before,outputLUFS: final,normalizationGainDB: gainDB,samplePeakDBFS: finalPeak>0 ? 20*log10(finalPeak) : nil,peakLimited: limited)
    }
    private static func writePCM(_ samples: [Float],channels: Int,format: AVAudioFormat,to file: AVAudioFile) throws {
        guard let buffer=AVAudioPCMBuffer(pcmFormat: format,frameCapacity: AVAudioFrameCount(samples.count/channels)),let data=buffer.floatChannelData else { throw RenderError.write("Cannot allocate speech output PCM") }
        buffer.frameLength=AVAudioFrameCount(samples.count/channels)
        for frame in 0..<Int(buffer.frameLength) { for channel in 0..<channels { data[channel][frame]=samples[frame*channels+channel] } }
        try file.write(from: buffer)
    }
}
