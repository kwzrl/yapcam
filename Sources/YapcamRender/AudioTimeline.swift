@preconcurrency import AVFoundation
import Foundation

final class AudioTimeline: @unchecked Sendable {
    let composition = AVMutableComposition()
    let mix = AVMutableAudioMix()
    private var generatedDirectory: URL?
    deinit { if let generatedDirectory { try? FileManager.default.removeItem(at: generatedDirectory) } }
    var hasAudio: Bool { !composition.tracks(withMediaType: .audio).isEmpty }
    init(project: any RenderProjectSource, range: Range<Int64>) throws {
        let manifest = try RecordingManifest.load(package: project.packageURL)
        let clips = try project.renderClips()
        guard clips.allSatisfy({ $0.srcStartNs >= 0 && $0.srcEndNs > $0.srcStartNs && $0.speed.isFinite && $0.speed > 0 }) else { throw RenderError.invalidSettings("Invalid audio clip mapping") }
        var parameters: [AVAudioMixInputParameters] = []
        for kind in ["mic", "system_audio"] {
            var destination: AVMutableCompositionTrack?
            var timelineStart: Int64 = 0
            for clip in clips {
                let clipDuration = Int64((Double(clip.srcEndNs - clip.srcStartNs) / clip.speed).rounded())
                for segment in manifest.segments {
                    guard let relative = segment.files[kind] else { continue }
                    let trackStart = segment.srcStartNs + (segment.trackStartNs[kind] ?? 0)
                    let sourceStart = max(clip.srcStartNs, trackStart)
                    let sourceEnd = min(clip.srcEndNs, segment.srcStartNs + segment.durationNs)
                    guard sourceEnd > sourceStart else { continue }
                    let tlStart = timelineStart + Int64((Double(sourceStart - clip.srcStartNs) / clip.speed).rounded())
                    let tlEnd = timelineStart + Int64((Double(sourceEnd - clip.srcStartNs) / clip.speed).rounded())
                    let start = max(tlStart, range.lowerBound), end = min(tlEnd, range.upperBound)
                    guard end > start else { continue }
                    let asset = AVURLAsset(url: try mediaURL(relative, root: project.packageURL.appendingPathComponent("recording")))
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
                    let next = min(t + 20_000_000, range.upperBound)
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
            guard overlay.startNs >= 0, overlay.endNs > overlay.startNs, overlay.sourceStartNs >= 0, overlay.gain.isFinite, overlay.gain >= 0, overlay.fadeInNs >= 0, overlay.fadeOutNs >= 0 else { throw RenderError.invalidSettings("Invalid audio overlay") }
            let start=max(overlay.startNs,range.lowerBound), end=min(overlay.endNs,range.upperBound)
            guard end>start else { continue }
            let url: URL
            switch overlay.source {
            case .media(let relative): url=try mediaURL(relative,root: project.packageURL)
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
            let sourceDuration=source.timeRange.duration.seconds
            guard sourceDuration.isFinite, sourceDuration>0 else { throw RenderError.decode("Empty audio overlay") }
            let laneIndex: Int
            if let available=lanes.firstIndex(where: { $0.2<=start }) { laneIndex=available }
            else {
                guard let track=composition.addMutableTrack(withMediaType: .audio,preferredTrackID: kCMPersistentTrackID_Invalid) else { throw RenderError.write("Cannot add audio overlay track") }
                laneIndex=lanes.count; lanes.append((track,AVMutableAudioMixInputParameters(track: track),0))
            }
            let track=lanes[laneIndex].0, parameter=lanes[laneIndex].1
            var position=Double(start-range.lowerBound)/1e9
            let outputEnd=Double(end-range.lowerBound)/1e9
            var sourcePosition=Double(overlay.sourceStartNs+start-overlay.startNs)/1e9
            if overlay.loops { sourcePosition=sourcePosition.truncatingRemainder(dividingBy: sourceDuration) }
            while position<outputEnd-0.000_000_001 && sourcePosition<sourceDuration {
                let duration=min(sourceDuration-sourcePosition,outputEnd-position)
                try track.insertTimeRange(CMTimeRange(start: CMTime(seconds: sourcePosition,preferredTimescale: 1_000_000_000),duration: CMTime(seconds: duration,preferredTimescale: 1_000_000_000)),of: source,at: CMTime(seconds: position,preferredTimescale: 1_000_000_000))
                position+=duration
                if !overlay.loops { break }; sourcePosition=0
            }
            lanes[laneIndex].2=end
            let fadeInEnd=overlay.startNs+min(overlay.fadeInNs,overlay.endNs-overlay.startNs)
            let fadeOutStart=overlay.endNs-min(overlay.fadeOutNs,overlay.endNs-overlay.startNs)
            var boundaries=[start,end]
            if fadeInEnd>start && fadeInEnd<end { boundaries.append(fadeInEnd) }
            if fadeOutStart>start && fadeOutStart<end { boundaries.append(fadeOutStart) }
            boundaries=Array(Set(boundaries)).sorted()
            func gain(at t: Int64) -> Float {
                let incoming=overlay.fadeInNs>0 ? min(1,Double(t-overlay.startNs)/Double(overlay.fadeInNs)) : 1
                let outgoing=overlay.fadeOutNs>0 ? min(1,Double(overlay.endNs-t)/Double(overlay.fadeOutNs)) : 1
                return overlay.gain*Float(max(0,min(incoming,outgoing)))
            }
            for (a,b) in zip(boundaries,boundaries.dropFirst()) {
                parameter.setVolumeRamp(fromStartVolume: gain(at: a),toEndVolume: gain(at: b),timeRange: CMTimeRange(start: CMTime(value: a-range.lowerBound,timescale: 1_000_000_000),duration: CMTime(value: b-a,timescale: 1_000_000_000)))
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
