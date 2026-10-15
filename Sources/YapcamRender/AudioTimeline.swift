@preconcurrency import AVFoundation
import Foundation

final class AudioTimeline: @unchecked Sendable {
    let composition = AVMutableComposition()
    let mix = AVMutableAudioMix()
    private var generatedDirectory: URL?
    private let speechPreparation: SpeechAudioPreparation?
    var speechReports: [SpeechEnhancementReport] { speechPreparation?.reports ?? [] }
    var processedMicrophoneFiles: [URL: URL] { speechPreparation?.files ?? [:] }
    private func microphoneURL(_ original: URL) -> URL { speechPreparation?.files[original] ?? original }
    deinit { if let generatedDirectory { try? FileManager.default.removeItem(at: generatedDirectory) } }
    var hasAudio: Bool { !composition.tracks(withMediaType: .audio).isEmpty }
    init(project: any RenderProjectSource, range: Range<Int64>,speechPreparation: SpeechAudioPreparation? = nil) throws {
        self.speechPreparation=speechPreparation
        try Task.checkCancellation()
        let manifest = try RecordingManifest.load(package: project.packageURL)
        let clips = try project.renderClips()
        guard clips.allSatisfy({ $0.srcStartNs >= 0 && $0.srcEndNs > $0.srcStartNs && $0.speed.isFinite && $0.speed > 0 }) else { throw RenderError.invalidSettings("Invalid audio clip mapping") }
        var parameters: [AVAudioMixInputParameters] = []
        if let ranges=try project.renderAudioRanges() {
            try addRecordingRanges(ranges,project: project,range: range,parameters: &parameters)
        } else {
        for kind in ["mic", "system_audio"] {
            var destination: AVMutableCompositionTrack?
            var timelineStart = 0.0
            for clip in clips {
                try Task.checkCancellation()
                let clipDuration = Double(clip.srcEndNs - clip.srcStartNs) / clip.speed
                guard clipDuration.isFinite, timelineStart + clipDuration < Double(Int64.max) else { throw RenderError.invalidSettings("Audio clip duration overflows the timeline") }
                for segment in manifest.segments {
                    guard let relative = segment.files[kind] else { continue }
                    let trackStart = segment.srcStartNs + (segment.trackStartNs[kind] ?? 0)
                    let sourceStart = max(clip.srcStartNs, trackStart)
                    let sourceEnd = min(clip.srcEndNs, segment.srcStartNs + segment.durationNs)
                    guard sourceEnd > sourceStart else { continue }
                    let tlStart = Int64((timelineStart + Double(sourceStart - clip.srcStartNs) / clip.speed).rounded())
                    let tlEnd = Int64((timelineStart + Double(sourceEnd - clip.srcStartNs) / clip.speed).rounded())
                    let start = max(tlStart, range.lowerBound), end = min(tlEnd, range.upperBound)
                    guard end > start else { continue }
                    let original=try packageMediaURL(relative,root: project.packageURL.appendingPathComponent("recording"))
                    let asset=AVURLAsset(url: kind=="mic" ? microphoneURL(original) : original)
                    guard let source = asset.tracks(withMediaType: .audio).first else { throw RenderError.decode("No audio track in \(relative)") }
                    let fileStart = Double(sourceStart - trackStart) / 1e9 + Double(start - tlStart) / 1e9 * clip.speed
                    let sourceDuration = Double(end - start) / 1e9 * clip.speed
                    let available = max(0, source.timeRange.end.seconds - fileStart)
                    let actual = min(sourceDuration, available)
                    guard actual > 0 else { continue }
                    if destination == nil { destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
                    guard let destination else { throw RenderError.write("Cannot create audio composition track") }
                    let position = CMTime(value: start - range.lowerBound, timescale: 1_000_000_000)
                    let inserted = CMTime(seconds: actual, preferredTimescale: 1_000_000_000)
                    try destination.insertTimeRange(CMTimeRange(start: CMTime(seconds: fileStart, preferredTimescale: 1_000_000_000), duration: inserted), of: source, at: position)
                    destination.scaleTimeRange(CMTimeRange(start: position, duration: inserted), toDuration: CMTime(seconds: actual / clip.speed, preferredTimescale: 1_000_000_000))
                }
                timelineStart += clipDuration
            }
            if let destination {
                let parameter = AVMutableAudioMixInputParameters(track: destination)
                // Gains come from the exact evaluator used for pixels, including clip cuts.
                var t = range.lowerBound
                while t < range.upperBound {
                    try Task.checkCancellation()
                    let next = t + min(20_000_000, range.upperBound - t)
                    let a = try project.frame(atNs: t), b = try project.frame(atNs: min(next, range.upperBound - 1))
                    let gainA = kind == "mic" ? a.mic_gain : a.system_gain
                    let gainB = kind == "mic" ? b.mic_gain : b.system_gain
                    guard gainA.isFinite, gainB.isFinite, gainA >= 0, gainB >= 0 else { throw RenderError.invalidSettings("Invalid audio gain") }
                    parameter.setVolumeRamp(fromStartVolume: gainA, toEndVolume: gainB, timeRange: CMTimeRange(start: CMTime(value: t - range.lowerBound, timescale: 1_000_000_000), duration: CMTime(value: next - t, timescale: 1_000_000_000)))
                    t = next
                }
                parameters.append(parameter)
            }
        }
        }
        try addOverlays(project: project, range: range, parameters: &parameters)
        mix.inputParameters = parameters
        let requested = CMTime(value: Int64(range.count),timescale: 1_000_000_000)
        if hasAudio && composition.duration < requested {
            // Trailing empty edits are discarded by AVFoundation. A real digital-silence
            // sample at the endpoint keeps the audio clock alive after a device is lost.
            let url = try temporaryDirectory().appendingPathComponent("silence.wav")
            try ProceduralAudio.wav([0]).write(to: url)
            let asset = AVURLAsset(url: url)
            guard let source = asset.tracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio,preferredTrackID: kCMPersistentTrackID_Invalid) else { throw RenderError.write("Cannot pad the audio clock") }
            let length = min(requested,CMTime(value: 1,timescale: 48_000))
            try track.insertTimeRange(CMTimeRange(start: .zero,duration: length),of: source,at: requested-length)
        }
    }
    private func addRecordingRanges(_ ranges: [RenderAudioRange],project: any RenderProjectSource,range: Range<Int64>,parameters: inout [AVAudioMixInputParameters]) throws {
        for row in ranges { try row.validate() }
        // Retain the owning asset and track together while building the composition.
        var assets: [String: (AVURLAsset,AVAssetTrack)] = [:]
        for kind in [RenderAudioRange.Track.mic,.systemAudio] {
            var destination: AVMutableCompositionTrack?
            var parameter: AVMutableAudioMixInputParameters?
            var previousEnd: Int64=0
            for row in ranges.filter({ $0.track==kind }).sorted(by: { $0.tlStartNs<$1.tlStartNs }) {
                try Task.checkCancellation()
                guard row.tlStartNs>=previousEnd else { throw RenderError.invalidSettings("Overlapping recording audio intervals") }
                previousEnd=row.tlEndNs
                guard row.fileEndNs>row.fileStartNs else { continue }
                let start=max(row.tlStartNs,range.lowerBound), end=min(row.tlEndNs,range.upperBound)
                guard end>start else { continue }
                let key="\(kind.rawValue):\(row.path)"
                if assets[key]==nil {
                    let original=try packageMediaURL(row.path,root: project.packageURL)
                    let asset=AVURLAsset(url: kind == .mic ? microphoneURL(original) : original)
                    guard let source=asset.tracks(withMediaType: .audio).first else { throw RenderError.decode("No audio track in \(row.path)") }
                    assets[key]=(asset,source)
                }
                let source=assets[key]!.1
                let mediaRange=source.timeRange
                guard mediaRange.start.isNumeric, mediaRange.end.isNumeric else { throw RenderError.decode("Audio media has invalid timing") }
                let mediaStart=CMTimeConvertScale(mediaRange.start,timescale: 1_000_000_000,method: .roundHalfAwayFromZero).value
                let mediaEnd=CMTimeConvertScale(mediaRange.end,timescale: 1_000_000_000,method: .roundHalfAwayFromZero).value
                let requestedStart=row.fileNs(atTimelineNs: start), requestedEnd=row.fileNs(atTimelineNs: end)
                let fileStart=max(requestedStart,mediaStart), fileEnd=min(requestedEnd,mediaEnd)
                guard fileEnd>fileStart else { continue } // Explicit silence through missing device tails.
                let outputStart=fileStart==requestedStart ? start : row.timelineNs(atFileNs: fileStart)
                let outputEnd=fileEnd==requestedEnd ? end : row.timelineNs(atFileNs: fileEnd)
                guard outputEnd>outputStart else { continue }
                if destination==nil {
                    destination=composition.addMutableTrack(withMediaType: .audio,preferredTrackID: kCMPersistentTrackID_Invalid)
                    guard let destination else { throw RenderError.write("Cannot create recording audio track") }
                    parameter=AVMutableAudioMixInputParameters(track: destination)
                }
                let position=CMTime(value: outputStart-range.lowerBound,timescale: 1_000_000_000)
                let inserted=CMTime(value: fileEnd-fileStart,timescale: 1_000_000_000)
                try destination!.insertTimeRange(CMTimeRange(start: CMTime(value: fileStart,timescale: 1_000_000_000),duration: inserted),of: source,at: position)
                destination!.scaleTimeRange(CMTimeRange(start: position,duration: inserted),toDuration: CMTime(value: outputEnd-outputStart,timescale: 1_000_000_000))
                // AVAudioMix ramps amplitude linearly; short segments approximate the dB curve.
                // Restart at every Core boundary to preserve abrupt mute/automation changes.
                var time=outputStart
                while time<outputEnd {
                    try Task.checkCancellation()
                    let next=time+min(20_000_000,outputEnd-time)
                    parameter!.setVolumeRamp(fromStartVolume: row.gain(atTimelineNs: time),toEndVolume: row.gain(atTimelineNs: next),timeRange: CMTimeRange(start: CMTime(value: time-range.lowerBound,timescale: 1_000_000_000),duration: CMTime(value: next-time,timescale: 1_000_000_000)))
                    time=next
                }
            }
            if let parameter { parameters.append(parameter) }
        }
    }
    private func temporaryDirectory() throws -> URL {
        if let generatedDirectory { return generatedDirectory }
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        generatedDirectory=directory; return directory
    }
    private func addOverlays(project: any RenderProjectSource, range: Range<Int64>, parameters: inout [AVAudioMixInputParameters]) throws {
        let overlays = try project.renderAudioOverlays().sorted { $0.startNs < $1.startNs }
        var generated: [String: URL] = [:]
        var lanes: [(AVMutableCompositionTrack, AVMutableAudioMixInputParameters, Int64)] = []
        for overlay in overlays {
            try overlay.validate()
            let start=max(overlay.startNs,range.lowerBound), end=min(overlay.endNs,range.upperBound)
            guard end>start else { continue }
            let url: URL
            switch overlay.source {
            case .media(let relative): url=try packageMediaURL(relative,root: project.packageURL)
            default:
                let key=String(describing: overlay.source)
                if let existing=generated[key] { url=existing }
                else {
                    url=try temporaryDirectory().appendingPathComponent("sound-\(generated.count).wav")
                    try ProceduralAudio.wav(ProceduralAudio.samples(for: overlay.source)).write(to: url)
                    generated[key]=url
                }
            }
            let asset=AVURLAsset(url: url)
            guard let source=asset.tracks(withMediaType: .audio).first else { throw RenderError.decode("Audio overlay has no audio track") }
            let sourceDuration=min(source.timeRange.duration.seconds,overlay.sourceDurationNs.map { Double($0)/1e9 } ?? .infinity)
            guard sourceDuration.isFinite, sourceDuration>0 else { throw RenderError.decode("Empty audio overlay") }
            guard sourceDuration>=1.0/48_000 else { throw RenderError.invalidSettings("Audio loop is shorter than one mixed PCM frame") }
            let laneIndex: Int
            if let available=lanes.firstIndex(where: { $0.2<=start }) { laneIndex=available }
            else {
                guard let track=composition.addMutableTrack(withMediaType: .audio,preferredTrackID: kCMPersistentTrackID_Invalid) else { throw RenderError.write("Cannot add audio overlay track") }
                laneIndex=lanes.count; lanes.append((track,AVMutableAudioMixInputParameters(track: track),0))
            }
            let track=lanes[laneIndex].0, parameter=lanes[laneIndex].1
            var position=Double(start-range.lowerBound)/1e9
            let outputEnd=Double(end-range.lowerBound)/1e9
            var sourcePosition=Double(overlay.sourceStartNs)/1e9+Double(start-overlay.startNs)/1e9
            if overlay.loops { sourcePosition=sourcePosition.truncatingRemainder(dividingBy: sourceDuration) }
            while position<outputEnd-0.000_000_001 && sourcePosition<sourceDuration {
                try Task.checkCancellation()
                let duration=min(sourceDuration-sourcePosition,outputEnd-position)
                guard position+duration>position else { throw RenderError.invalidSettings("Audio loop cannot advance its timeline clock") }
                try track.insertTimeRange(CMTimeRange(start: CMTime(seconds: sourcePosition,preferredTimescale: 1_000_000_000),duration: CMTime(seconds: duration,preferredTimescale: 1_000_000_000)),of: source,at: CMTime(seconds: position,preferredTimescale: 1_000_000_000))
                position+=duration
                if !overlay.loops { break }; sourcePosition=0
            }
            lanes[laneIndex].2=end
            let envelopeDuration=overlay.envelopeEnd-overlay.envelopeStart
            let fadeInEnd=overlay.envelopeStart+min(overlay.fadeInNs,envelopeDuration)
            let fadeOutStart=overlay.envelopeEnd-min(overlay.fadeOutNs,envelopeDuration)
            var boundaries=[start,end]
            if fadeInEnd>start && fadeInEnd<end { boundaries.append(fadeInEnd) }
            if fadeOutStart>start && fadeOutStart<end { boundaries.append(fadeOutStart) }
            if !overlay.multiplyFades && overlay.fadeInNs>0 && overlay.fadeOutNs>0 {
                let sum=Double(overlay.fadeInNs)+Double(overlay.fadeOutNs)
                let crossing: Int64
                if overlay.fadeInNs<=overlay.fadeOutNs {
                    crossing=overlay.envelopeStart+Int64((Double(envelopeDuration)*(Double(overlay.fadeInNs)/sum)).rounded())
                } else {
                    crossing=overlay.envelopeEnd-Int64((Double(envelopeDuration)*(Double(overlay.fadeOutNs)/sum)).rounded())
                }
                if crossing>start && crossing<end && crossing<fadeInEnd && crossing>fadeOutStart { boundaries.append(crossing) }
            }
            boundaries=Array(Set(boundaries)).sorted()
            // Short amplitude ramps approximate dB ducking and the product of overlapping fades.
            // Envelope anchors and source clock remain those of the unsplit music record.
            for (a,b) in zip(boundaries,boundaries.dropFirst()) {
                var time=a
                while time<b {
                    try Task.checkCancellation()
                    let next=time+min(20_000_000,b-time)
                    parameter.setVolumeRamp(fromStartVolume: overlay.gain(atTimelineNs: time),toEndVolume: overlay.gain(atTimelineNs: next),timeRange: CMTimeRange(start: CMTime(value: time-range.lowerBound,timescale: 1_000_000_000),duration: CMTime(value: next-time,timescale: 1_000_000_000)))
                    time=next
                }
            }
        }
        parameters.append(contentsOf: lanes.map { $0.1 })
    }
    func reader(rangeDuration: Int64) throws -> (AVAssetReader, AVAssetReaderAudioMixOutput)? {
        guard hasAudio else { return nil }
        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: composition.tracks(withMediaType: .audio), audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
        output.audioMix = mix; output.audioTimePitchAlgorithm = .spectral; output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RenderError.decode("Cannot mix audio") }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(value: rangeDuration, timescale: 1_000_000_000))
        guard reader.startReading() else { throw RenderError.decode(reader.error.map { String(describing: $0 as NSError) } ?? "Audio reader failed") }
        return (reader, output)
    }
}
