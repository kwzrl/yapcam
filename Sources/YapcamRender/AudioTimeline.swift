@preconcurrency import AVFoundation
import Foundation

final class AudioTimeline: @unchecked Sendable {
    let composition = AVMutableComposition()
    let mix = AVMutableAudioMix()
    private var generatedDirectory: URL?
    private var recordingAudioRequested = false
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
                    recordingAudioRequested = true
                    let fileStart = Double(sourceStart - trackStart) / 1e9 + Double(start - tlStart) / 1e9 * clip.speed
                    let sourceDuration = Double(end - start) / 1e9 * clip.speed
                    let requestedSource = CMTimeRange(start: CMTime(seconds: fileStart, preferredTimescale: 1_000_000_000), duration: CMTime(seconds: sourceDuration, preferredTimescale: 1_000_000_000))
                    let requestedTarget = CMTimeRange(start: CMTime(value: start-range.lowerBound, timescale: 1_000_000_000), duration: CMTime(value: end-start, timescale: 1_000_000_000))
                    guard let selection = try recordingSelection(source, requested: requestedSource, target: requestedTarget, unitRate: clip.speed == 1) else { continue }
                    if destination == nil { destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
                    guard let destination else { throw RenderError.write("Cannot create audio composition track") }
                    try insert(selection, of: source, into: destination, unitRate: clip.speed == 1)
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
        if hasAudio || recordingAudioRequested { try padMissingAudio(until: requested) }
    }

    // Keep physical source boundaries as rational media times. Rounding a 48kHz
    // EOF up to nanoseconds asks the decoder for samples that do not exist.
    private func recordingSelection(_ source: AVAssetTrack, requested: CMTimeRange, target: CMTimeRange, unitRate: Bool) throws -> CMTimeMapping? {
        let media = source.timeRange
        guard media.start.isNumeric, media.end.isNumeric, media.duration >= .zero, source.naturalTimeScale > 0 else { throw RenderError.decode("Audio media has invalid timing") }
        // Subtracting a ns trim from a sample-clock EOF can exceed CMTime's
        // timescale limit and round the resulting duration outward again. Snap
        // inward on the native sample clock before subtracting or retiming.
        let start = CMTimeConvertScale(max(requested.start, media.start), timescale: source.naturalTimeScale, method: .roundTowardPositiveInfinity)
        let end = CMTimeConvertScale(min(requested.end, media.end), timescale: source.naturalTimeScale, method: .roundTowardNegativeInfinity)
        guard end > start else { return nil }
        let selected = CMTimeRange(start: start, end: end)
        func outputTime(_ time: CMTime) -> CMTime {
            if time == requested.start { return target.start }
            if time == requested.end { return target.end }
            let offset = time-requested.start
            return target.start + (unitRate ? offset : CMTimeMultiplyByFloat64(offset, multiplier: target.duration.seconds/requested.duration.seconds))
        }
        return CMTimeMapping(source: selected, target: CMTimeRange(start: outputTime(start), end: outputTime(end)))
    }

    private func insert(_ selection: CMTimeMapping, of source: AVAssetTrack, into destination: AVMutableCompositionTrack, unitRate: Bool) throws {
        try destination.insertTimeRange(selection.source, of: source, at: selection.target.start)
        // Avoid manufacturing a rate change for ordinary playback. In particular,
        // a fractional-sample EOF must not be stretched to a rounded ns endpoint.
        if !unitRate {
            destination.scaleTimeRange(CMTimeRange(start: selection.target.start, duration: selection.source.duration), toDuration: selection.target.duration)
        }
    }

    private func padMissingAudio(until end: CMTime) throws {
        let coverage = composition.tracks(withMediaType: .audio).flatMap { $0.segments ?? [] }
            .filter { !$0.isEmpty }.map { $0.timeMapping.target }.sorted { $0.start < $1.start }
        var cursor = CMTime.zero
        var gaps: [CMTimeRange] = []
        for interval in coverage {
            let start = max(.zero, min(end, interval.start))
            if start > cursor { gaps.append(CMTimeRange(start: cursor, end: start)) }
            cursor = max(cursor, min(end, interval.end))
        }
        if cursor < end { gaps.append(CMTimeRange(start: cursor, end: end)) }
        guard !gaps.isEmpty else { return }
        // Real zero samples fill the entire uncovered interval, including exports
        // wholly after device EOF. Reuse a bounded 1-second file even for long gaps.
        let url = try temporaryDirectory().appendingPathComponent("silence.wav")
        try ProceduralAudio.wav([Int16](repeating: 0, count: 48_000)).write(to: url)
        let asset = AVURLAsset(url: url)
        guard let source = asset.tracks(withMediaType: .audio).first,
              let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw RenderError.write("Cannot pad the audio clock") }
        for gap in gaps {
            var position = gap.start
            while position < gap.end {
                try Task.checkCancellation()
                let length = min(source.timeRange.duration, gap.end-position)
                try track.insertTimeRange(CMTimeRange(start: source.timeRange.start, duration: length), of: source, at: position)
                position = position+length
            }
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
                recordingAudioRequested = true
                let requestedStart=row.fileNs(atTimelineNs: start), requestedEnd=row.fileNs(atTimelineNs: end)
                let unitRate = row.fileEndNs-row.fileStartNs == row.tlEndNs-row.tlStartNs
                let requestedSource = CMTimeRange(start: CMTime(value: requestedStart, timescale: 1_000_000_000), duration: CMTime(value: requestedEnd-requestedStart, timescale: 1_000_000_000))
                let requestedTarget = CMTimeRange(start: CMTime(value: start-range.lowerBound, timescale: 1_000_000_000), duration: CMTime(value: end-start, timescale: 1_000_000_000))
                guard let selection = try recordingSelection(source, requested: requestedSource, target: requestedTarget, unitRate: unitRate) else { continue }
                let outputStart = range.lowerBound+CMTimeConvertScale(selection.target.start, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
                let outputEnd = range.lowerBound+CMTimeConvertScale(selection.target.end, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
                if destination==nil {
                    destination=composition.addMutableTrack(withMediaType: .audio,preferredTrackID: kCMPersistentTrackID_Invalid)
                    guard let destination else { throw RenderError.write("Cannot create recording audio track") }
                    parameter=AVMutableAudioMixInputParameters(track: destination)
                }
                try insert(selection, of: source, into: destination!, unitRate: unitRate)
                // AVAudioMix stores every ramp; inserting tens of thousands of
                // identical 20ms ramps makes preparation superlinear. A constant
                // Core interval is represented exactly by one range, including mute.
                // Keep a separate call at every Core boundary for abrupt changes.
                if row.gainStart == row.gainEnd {
                    parameter!.setVolumeRamp(fromStartVolume: row.gainStart,toEndVolume: row.gainEnd,
                        timeRange: CMTimeRange(start: CMTime(value: outputStart-range.lowerBound,timescale: 1_000_000_000),
                                              duration: CMTime(value: outputEnd-outputStart,timescale: 1_000_000_000)))
                    continue
                }
                // Nonconstant dB curves retain the existing 20ms approximation.
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
