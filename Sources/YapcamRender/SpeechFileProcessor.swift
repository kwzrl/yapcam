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
    let track: AVAssetTrack?
    let channels: Int
    let endFrame: Int64
    init(asset: AVURLAsset,track: AVAssetTrack?,channels: Int,endFrame: Int64) { self.asset=asset; self.track=track; self.channels=channels; self.endFrame=endFrame }
}

/// AVAudioFile handles PCM locally without requiring AVAssetReader codec services.
private final class SpeechPCMReader: @unchecked Sendable {
    let file: AVAudioFile
    let format: AVAudioFormat
    let converter: AVAudioConverter?
    private var failure: Error?
    init(url: URL,format: AVAudioFormat) throws {
        file=try AVAudioFile(forReading: url,commonFormat: .pcmFormatFloat32,interleaved: false)
        self.format=format
        if file.processingFormat.sampleRate != 48_000 {
            guard let converter=AVAudioConverter(from: file.processingFormat,to: format) else { throw RenderError.unavailable("PCM sample-rate conversion unavailable") }
            converter.primeMethod = .none; self.converter=converter
        } else { converter=nil }
    }
    func next() throws -> [Float]? {
        if converter==nil && file.framePosition>=file.length { return nil }
        guard let buffer=AVAudioPCMBuffer(pcmFormat: format,frameCapacity: 4096) else { throw RenderError.write("Cannot allocate speech PCM") }
        if let converter {
            var error: NSError?
            let status=converter.convert(to: buffer,error: &error) { [self] count,status in
                if file.framePosition>=file.length { status.pointee = .endOfStream; return nil }
                do {
                    guard let input=AVAudioPCMBuffer(pcmFormat: file.processingFormat,frameCapacity: max(1,min(count,4096))) else { throw RenderError.write("Cannot allocate resampler input") }
                    try file.read(into: input)
                    status.pointee=input.frameLength>0 ? .haveData : .endOfStream
                    return input.frameLength>0 ? input : nil
                } catch { failure=error; status.pointee = .noDataNow; return nil }
            }
            if let failure { throw failure }; if let error { throw error }
            if status == .error { throw RenderError.decode("Speech resampling failed") }
        } else { try file.read(into: buffer) }
        guard buffer.frameLength>0 else { return nil }
        guard let data=buffer.floatChannelData else { throw RenderError.decode("Speech PCM has no channel data") }
        let channels=Int(format.channelCount)
        var pcm=[Float](repeating: 0,count: Int(buffer.frameLength)*channels)
        for frame in 0..<Int(buffer.frameLength) { for channel in 0..<channels { pcm[frame*channels+channel]=data[channel][frame] } }
        return pcm
    }
}

public extension SpeechEnhancer {
    /// Offline, streamed mono/stereo processing to lossless 48kHz Float32 CAF/WAV.
    /// Keeps file-local sample positions, including gaps; never overwrites input or destination.
    /// Native compressed decoders may be unavailable under restricted execution: explicit error.
    static func processFile(_ source: URL,to destination: URL,settings: SpeechEnhancementSettings = .init(),progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> SpeechEnhancementReport {
        guard let report=try await prepareMicrophoneFile(source,to: destination,settings: settings,mono: false,progress: progress) else { throw RenderError.verification("Speech processing did not return a report") }
        return report
    }
    internal static func prepareMicrophoneFile(_ source: URL,to destination: URL,settings: SpeechEnhancementSettings?,mono: Bool,progress: @escaping @Sendable (Double) -> Void) async throws -> SpeechEnhancementReport? {
        try settings?.validate(); try Task.checkCancellation()
        guard source.isFileURL,destination.isFileURL,["caf","wav"].contains(destination.pathExtension.lowercased()) else { throw RenderError.invalidSettings("Speech output must be a local CAF or WAV file") }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw RenderError.write("Speech output already exists") }
        let asset=AVURLAsset(url: source)
        if ["wav","caf","aif","aiff"].contains(source.pathExtension.lowercased()) {
            let file=try AVAudioFile(forReading: source,commonFormat: .pcmFormatFloat32,interleaved: false)
            let channels=Int(file.processingFormat.channelCount), frames=Double(file.length)*48_000/file.processingFormat.sampleRate
            guard (1...2).contains(channels),frames.isFinite,frames>0,frames<Double(Int64.max) else { throw RenderError.invalidSettings("Speech PCM input must be nonempty mono/stereo") }
            if settings==nil && channels==1 { return nil }
            return try await processSource(SpeechSourceTrack(asset: asset,track: nil,channels: channels,endFrame: Int64(frames.rounded())),to: destination,settings: settings,mono: mono,progress: progress)
        }
        guard let track=try await asset.loadTracks(withMediaType: .audio).first else { throw RenderError.decode("Speech input has no audio track") }
        let descriptions=try await track.load(.formatDescriptions)
        guard let description=descriptions.first,let format=CMAudioFormatDescriptionGetStreamBasicDescription(description) else { throw RenderError.decode("Speech input audio format is unavailable") }
        let channels=Int(format.pointee.mChannelsPerFrame)
        guard (1...2).contains(channels) else { throw RenderError.unavailable("Offline speech processing supports mono/stereo inputs") }
        if settings==nil && channels==1 { return nil }
        let timeRange=try await track.load(.timeRange)
        let end=CMTimeConvertScale(timeRange.end,timescale: 48_000,method: .roundHalfAwayFromZero)
        guard end.isNumeric,end.value>0 else { throw RenderError.decode("Speech input has invalid duration") }
        let context=SpeechSourceTrack(asset: asset,track: track,channels: channels,endFrame: end.value)
        return try await processSource(context,to: destination,settings: settings,mono: mono,progress: progress)
    }
    private static func processSource(_ context: SpeechSourceTrack,to destination: URL,settings: SpeechEnhancementSettings?,mono: Bool,progress: @escaping @Sendable (Double) -> Void) async throws -> SpeechEnhancementReport? {
        let cancellation=SpeechReadCancellation()
        let task=Task.detached(priority: .userInitiated) {
            do { return try processFile(context,to: destination,settings: settings,mono: mono,cancellation: cancellation,progress: progress) }
            catch is CancellationError { throw CancellationError() }
            catch let error as RenderError { throw error }
            catch { throw RenderError.write("Offline speech file IO failed: \(error as NSError)") }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { cancellation.cancel(); task.cancel() }
    }
    private static func processFile(_ source: SpeechSourceTrack,to destination: URL,settings: SpeechEnhancementSettings?,mono: Bool,cancellation: SpeechReadCancellation,progress: @Sendable (Double) -> Void) throws -> SpeechEnhancementReport? {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-speech-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let intermediate=directory.appendingPathComponent("processed.caf")
        let partial=destination.deletingLastPathComponent().appendingPathComponent(".yapcam-speech-\(UUID().uuidString).\(destination.pathExtension)")
        defer { try? FileManager.default.removeItem(at: partial) }
        let inputChannels=source.channels, channels=mono ? 1 : source.channels
        let format=AVAudioFormat(commonFormat: .pcmFormatFloat32,sampleRate: 48_000,channels: AVAudioChannelCount(channels),interleaved: false)!
        let inputFormat=AVAudioFormat(commonFormat: .pcmFormatFloat32,sampleRate: 48_000,channels: AVAudioChannelCount(inputChannels),interleaved: false)!
        var fileSettings=format.settings; fileSettings[AVLinearPCMIsNonInterleaved]=false
        var reader: AVAssetReader?, nativeOutput: AVAssetReaderTrackOutput?
        if let track=source.track {
            let value=try AVAssetReader(asset: source.asset)
            let output=AVAssetReaderTrackOutput(track: track,outputSettings: [AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:48_000,AVNumberOfChannelsKey:inputChannels,AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsBigEndianKey:false,AVLinearPCMIsNonInterleaved:false])
            output.alwaysCopiesSampleData=false
            guard value.canAdd(output) else { throw RenderError.decode("Speech PCM decoder is unavailable") }
            value.add(output); try cancellation.attach(value); try cancellation.check()
            guard value.startReading() else { throw RenderError.unavailable(value.error.map { String(describing: $0 as NSError) } ?? "Speech decoder unavailable") }
            reader=value; nativeOutput=output
        }
        defer { reader?.cancelReading() }
        var processor=try settings.map { try SpeechProcessor48k(channels: channels,settings: $0) }
        var meter=try LoudnessMeter48k(channels: channels), written: Int64=0, decodedFrames: Int64=0
        try autoreleasepool {
            let file=try AVAudioFile(forWriting: intermediate,settings: fileSettings,commonFormat: .pcmFormatFloat32,interleaved: false)
            func write(_ samples: [Float]) throws {
                let selected: [Float]
                if mono && inputChannels==2 {
                    selected=stride(from: 0,to: samples.count,by: 2).map { samples[$0]*0.5+samples[$0+1]*0.5 }
                } else { selected=samples }
                guard selected.allSatisfy(\.isFinite) else { throw RenderError.decode("Microphone PCM contains nonfinite samples") }
                let processed=try processor?.process(selected) ?? selected
                if settings != nil { try meter.process(interleaved: processed) }
                try writePCM(processed,channels: channels,format: format,to: file)
                written+=Int64(processed.count/channels)
            }
            if let output=nativeOutput {
            while let sample=output.copyNextSampleBuffer() {
                try cancellation.check()
                guard let block=CMSampleBufferGetDataBuffer(sample) else { throw RenderError.decode("Speech sample has no PCM data") }
                let length=CMBlockBufferGetDataLength(block)
                if length==0 { continue }
                guard length%(inputChannels*4)==0 else { throw RenderError.decode("Speech PCM layout is invalid") }
                var pcm=[Float](repeating: 0,count: length/4)
                let status=pcm.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset: 0,dataLength: length,destination: $0.baseAddress!) }
                guard status==kCMBlockBufferNoErr else { throw RenderError.decode("Cannot read speech PCM") }
                decodedFrames+=Int64(pcm.count/inputChannels)
                let time=CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample),timescale: 48_000,method: .roundHalfAwayFromZero)
                guard time.isNumeric else { throw RenderError.decode("Speech sample has invalid timestamp") }
                let start=max(0,time.value)
                while written<min(start,source.endFrame) {
                    try cancellation.check(); try write([Float](repeating: 0,count: Int(min(4096,min(start,source.endFrame)-written))*inputChannels))
                }
                let skip=Int(min(Int64(pcm.count/inputChannels),max(0,written-time.value)))
                let count=Int(min(Int64(pcm.count/inputChannels-skip),max(0,source.endFrame-written)))
                if count>0 { try write(Array(pcm[skip*inputChannels..<(skip+count)*inputChannels])) }
                progress(min(0.5,Double(written)/Double(source.endFrame)*0.5))
            }
            try cancellation.check()
            guard reader?.status == .completed else { throw RenderError.decode(reader?.error?.localizedDescription ?? "Speech decoder stopped") }
            } else {
                let input=try SpeechPCMReader(url: source.asset.url,format: inputFormat)
                while let pcm=try input.next() {
                    try cancellation.check(); decodedFrames+=Int64(pcm.count/inputChannels)
                    let count=Int(min(Int64(pcm.count/inputChannels),max(0,source.endFrame-written)))
                    if count>0 { try write(Array(pcm.prefix(count*inputChannels))) }
                    progress(min(0.5,Double(written)/Double(source.endFrame)*0.5))
                }
            }
            guard decodedFrames>0 else { throw RenderError.decode("Speech decoder returned no audio samples") }
            while written<source.endFrame { try cancellation.check(); try write([Float](repeating: 0,count: Int(min(4096,source.endFrame-written))*inputChannels)) }
        }
        guard let settings else {
            try cancellation.check()
            let verified=try AVAudioFile(forReading: intermediate)
            guard verified.length==written,verified.fileFormat.sampleRate==48_000,Int(verified.fileFormat.channelCount)==channels else { throw RenderError.verification("Microphone channel conversion changed timing/format") }
            try FileManager.default.moveItem(at: intermediate,to: destination); progress(1)
            return nil // Channel conversion alone must not claim enhancement or normalization.
        }
        let before=meter.integratedLUFS
        var gainDB=settings.normalizeLoudness ? before.map { min(60,settings.targetLUFS-$0) } ?? 0 : 0
        var final: Double?, finalPeak=0.0, limited=false
        for attempt in 0..<4 {
            try cancellation.check()
            var result=try LoudnessMeter48k(channels: channels), limiter=SpeechPeakLimiter(channels: channels,ceilingDBFS: settings.peakCeilingDBFS)
            try autoreleasepool {
                let input=try AVAudioFile(forReading: intermediate,commonFormat: .pcmFormatFloat32,interleaved: false)
                let output=try AVAudioFile(forWriting: partial,settings: fileSettings,commonFormat: .pcmFormatFloat32,interleaved: false)
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
            guard attempt<3,settings.normalizeLoudness,let final,abs(final-settings.targetLUFS)>=0.2,gainDB<60 else { break }
            gainDB=min(60,gainDB+settings.targetLUFS-final)
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
