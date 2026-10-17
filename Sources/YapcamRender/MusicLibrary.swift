import Foundation
import YapcamCore

/// Original scores and synthesis. No sampled music, system sounds or downloaded
/// assets. Generated WAVs are ordinary project media after import.
public enum MusicLibrary {
    public enum Category: String, CaseIterable, Sendable, Codable {
        case commercial, electronic, instrumental, loFi = "lo-fi"
        public var title: String {
            switch self { case .commercial: "Commercial"; case .electronic: "Electronic"
            case .instrumental: "Instrumental"; case .loFi: "Lo-fi" }
        }
    }
    public struct Track: Identifiable, Sendable, Equatable, Codable {
        public let id: String
        public let name: String
        public let category: Category
        public let beatsPerMinute: Int
        /// Eight bars of4/4. Loop boundaries are silent with bounded attack/release.
        public let durationNs: Int64
        fileprivate let root: Int
        fileprivate let pattern: Int
    }
    public static let tracks: [Track] = {
        let scores: [(String,String,Category,Int,Int)] = [
            ("open-road","Open Road",.commercial,112,48),("fresh-page","Fresh Page",.commercial,120,50),
            ("small-wins","Small Wins",.commercial,104,53),("daybreak","Daybreak",.commercial,116,55),
            ("forward","Forward",.commercial,124,57),
            ("pulse-grid","Pulse Grid",.electronic,120,45),("blue-circuit","Blue Circuit",.electronic,108,48),
            ("night-transit","Night Transit",.electronic,126,50),("slow-orbit","Slow Orbit",.electronic,96,43),
            ("signal-path","Signal Path",.electronic,114,52),
            ("felt-lines","Felt Lines",.instrumental,80,48),("paper-boats","Paper Boats",.instrumental,88,53),
            ("long-light","Long Light",.instrumental,72,55),("homeward","Homeward",.instrumental,92,50),
            ("window-seat","Window Seat",.loFi,76,45),("rain-check","Rain Check",.loFi,84,48),
            ("late-letter","Late Letter",.loFi,68,50),("warm-lamp","Warm Lamp",.loFi,80,53)
        ]
        return scores.enumerated().map { index,score in
            let (id,name,category,bpm,root)=score
            // Duration is quantized to the actual48k PCM frame count, so Core's
            // loop range and the generated WAV cannot disagree by a sample.
            let frames=Int((32*60/Double(bpm)*48_000).rounded())
            return Track(id: id,name: name,category: category,beatsPerMinute: bpm,
                durationNs: Int64((Double(frames)/48_000*1e9).rounded()),root: root,pattern: index)
        }
    }()
    public static func catalog(category: Category? = nil) -> [Track] {
        tracks.filter { category == nil || $0.category == category }
    }
    public static func track(id: String) -> Track? { tracks.first { $0.id == id } }

    /// CPU generation runs outside the caller's actor. Does not overwrite an
    /// existing file. Preview and project import can use the same resulting WAV.
    public static func write(trackID: String,to url: URL) async throws {
        guard url.isFileURL,url.pathExtension.lowercased() == "wav",let track=track(id: trackID) else {
            throw RenderError.invalidSettings("Choose a library track and a local WAV destination")
        }
        try Task.checkCancellation()
        let worker=Task.detached(priority: .userInitiated) {
            let samples=try samples(track)
            try Task.checkCancellation()
            try ProceduralAudio.wav(samples).write(to: url,options: .withoutOverwriting)
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    /// Uses Core's existing atomic file import: one undo step; copied into the
    /// package, saved/reopened normally, available to both preview and export.
    @discardableResult public static func apply(trackID: String,to project: Project,startNs: Int64 = 0,
                                               endNs: Int64? = nil) async throws -> ChangeSet {
        guard track(id: trackID) != nil,startNs>=0,(endNs ?? project.durationNs)>startNs else {
            throw RenderError.invalidSettings("Invalid music selection or timeline range")
        }
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-music-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        defer { print("Cleanup render music import: \(directory.path)"); try? FileManager.default.removeItem(at: directory) }
        let url=directory.appendingPathComponent(trackID).appendingPathExtension("wav")
        try await write(trackID: trackID,to: url)
        try Task.checkCancellation()
        return try await project.importMusic(url,startNs: startNs,endNs: endNs,gainDb: -26.020599913279625,loop: true)
    }

    /// Internal PCM oracle used by contract and actual-file regressions.
    static func samples(_ track: Track) throws -> [Int16] {
        let rate=48_000.0,beat=60/Double(track.beatsPerMinute)
        let count=Int((32*beat*rate).rounded())
        var result=[Int16](repeating: 0,count: count)
        let progressions=[[0,5,9,7],[0,9,5,7],[0,7,5,9],[0,5,7,5]]
        let progression=progressions[track.pattern%progressions.count]
        let minor=track.category == .electronic || track.category == .loFi
        let third=minor ? 3 : 4
        let phrase=[[0,7,third,12,7,third,2,7],[12,7,third,0,2,7,third,7]][track.pattern%2]
        func hz(_ note: Int) -> Double { 440*pow(2,Double(note-69)/12) }
        let chordFrequencies=(0..<8).map { bar -> [Double] in
            let root=track.root+progression[(bar+track.pattern/4)%4]
            return [hz(root),hz(root+third),hz(root+7)]
        }
        let leadFrequencies=(0..<64).map { step in
            hz(track.root+12+progression[(step/8+track.pattern/4)%4]+phrase[(step+track.pattern)%8])
        }
        var noise: UInt32=UInt32(track.pattern+1)&*747_796_405
        for i in 0..<count {
            if i%4096 == 0 { try Task.checkCancellation() }
            let t=Double(i)/rate,b=t/beat,bar=min(7,Int(b/4))
            let local=t-Double(bar)*4*beat
            let chord=chordFrequencies[bar]
            let pad=(sin(2 * .pi * chord[0]*t)+sin(2 * .pi * chord[1]*t)+sin(2 * .pi * chord[2]*t))/3
            let padEnvelope=min(1,local/0.025)*min(1,(4*beat-local)/0.045)
            let step=min(63,Int(b*2)),noteTime=t-Double(step)*beat/2
            let note=sin(2 * .pi * leadFrequencies[step]*noteTime)*min(1,noteTime/0.006)*exp(-noteTime*(track.category == .instrumental ? 7 : 13))
            let kickTime=t-Double(Int(b))*beat
            let kick=sin(2 * .pi * (48*kickTime+3.5*(1-exp(-kickTime*30))))*exp(-kickTime*28)
            noise=noise&*1_664_525&+1_013_904_223
            let hiss=(Double(noise>>8)/Double(0xFF_FFFF)*2-1)
            let hatTime=t-Double(Int(b*2))*beat/2
            let hat=hiss*exp(-hatTime*180)*min(1,hatTime/0.001)
            let snareTime=t-Double(Int(b/2)*2+1)*beat
            let snare=snareTime>=0 ? hiss*exp(-snareTime*38) : 0
            let signal: Double
            switch track.category {
            case .commercial: signal=0.22*pad*padEnvelope+0.18*note+0.2*kick+0.035*hat+0.06*snare
            case .electronic:
                let bass=sin(2 * .pi * chord[0]/2*t)+0.25*sin(2 * .pi * chord[0]*t)
                signal=0.14*pad*padEnvelope+0.17*note+0.1*bass*(1-exp(-kickTime*12))+0.25*kick+0.045*hat+0.07*snare
            case .instrumental: signal=0.27*pad*padEnvelope+0.3*note+0.018*sin(2 * .pi * chord[0]*2*t)*padEnvelope
            case .loFi: signal=0.26*pad*padEnvelope+0.16*note+0.14*kick+0.02*hat+0.035*snare
            }
            let remaining=Double(count-1-i)/rate
            let edge=min(1,t/0.025)*min(1,remaining/0.045)
            result[i]=Int16((max(-0.95,min(0.95,signal*edge))*32767).rounded())
        }
        return result
    }
}
