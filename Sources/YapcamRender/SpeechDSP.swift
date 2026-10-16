import Foundation

public struct SpeechEnhancementSettings: Sendable, Codable, Equatable {
    public var highPassHz: Double
    public var noiseThresholdDB: Double
    public var noiseReductionDB: Double
    public var compressorThresholdDB: Double
    public var compressorRatio: Double
    public var targetLUFS: Double
    public var peakCeilingDBFS: Double
    public var normalizeLoudness: Bool
    public init(highPassHz: Double = 90,noiseThresholdDB: Double = -45,noiseReductionDB: Double = 30,compressorThresholdDB: Double = -24,compressorRatio: Double = 3,targetLUFS: Double = -16,peakCeilingDBFS: Double = -1,normalizeLoudness: Bool = true) {
        self.highPassHz=highPassHz; self.noiseThresholdDB=noiseThresholdDB; self.noiseReductionDB=noiseReductionDB
        self.compressorThresholdDB=compressorThresholdDB; self.compressorRatio=compressorRatio
        self.targetLUFS=targetLUFS; self.peakCeilingDBFS=peakCeilingDBFS; self.normalizeLoudness=normalizeLoudness
    }
    func validate() throws {
        guard highPassHz.isFinite,(20...300).contains(highPassHz),noiseThresholdDB.isFinite,(-70 ... -15).contains(noiseThresholdDB),noiseReductionDB.isFinite,(0...60).contains(noiseReductionDB),compressorThresholdDB.isFinite,(-60...0).contains(compressorThresholdDB),compressorRatio.isFinite,(1...10).contains(compressorRatio),targetLUFS.isFinite,(-36 ... -10).contains(targetLUFS),peakCeilingDBFS.isFinite,(-12...0).contains(peakCeilingDBFS) else { throw RenderError.invalidSettings("Invalid offline speech processing settings") }
    }
}

struct AudioBiquad {
    let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var z1=0.0, z2=0.0
    init(b0: Double,b1: Double,b2: Double,a1: Double,a2: Double) { self.b0=b0; self.b1=b1; self.b2=b2; self.a1=a1; self.a2=a2 }
    mutating func process(_ x: Double) -> Double {
        let y=b0*x+z1; z1=b1*x-a1*y+z2; z2=b2*x-a2*y; return y
    }
    static func highPass(hz: Double) -> Self {
        let w=2*Double.pi*hz/48_000, c=cos(w), alpha=sin(w)/(2*sqrt(0.5)), a0=1+alpha
        return Self(b0:(1+c)/2/a0,b1:-(1+c)/a0,b2:(1+c)/2/a0,a1:-2*c/a0,a2:(1-alpha)/a0)
    }
}

/// Mono/stereo ITU-R BS.1770 K-weighting and gated 400ms blocks, 75% overlap.
/// Coefficients/measurement definition: ITU-R BS.1770-5 Annex 1, Tables 1–2.
/// https://www.itu.int/rec/R-REC-BS.1770-5-202311-I/en
public struct LoudnessMeter48k {
    private let channels: Int
    private var shelf: [AudioBiquad]
    private var highPass: [AudioBiquad]
    private var window=[Double](repeating: 0,count: 19_200)
    private var position=0, frames: Int64=0
    private var sum=0.0
    private var blocks: [Double]=[]
    public init(channels: Int) throws {
        guard (1...2).contains(channels) else { throw RenderError.invalidSettings("Speech loudness supports mono/stereo PCM") }
        self.channels=channels
        shelf=Array(repeating: AudioBiquad(b0:1.53512485958697,b1:-2.69169618940638,b2:1.19839281085285,a1:-1.69065929318241,a2:0.73248077421585),count: channels)
        highPass=Array(repeating: AudioBiquad(b0:1,b1:-2,b2:1,a1:-1.99004745483398,a2:0.99007225036621),count: channels)
    }
    public mutating func process(interleaved samples: [Float]) throws {
        guard samples.count%channels==0 else { throw RenderError.invalidSettings("Incomplete PCM frame") }
        for offset in stride(from: 0,to: samples.count,by: channels) {
            var energy=0.0
            for channel in 0..<channels {
                let x=Double(samples[offset+channel])
                guard x.isFinite else { throw RenderError.decode("Nonfinite audio sample") }
                let y=highPass[channel].process(shelf[channel].process(x)); energy+=y*y
            }
            sum+=energy-window[position]; window[position]=energy; position=(position+1)%window.count; frames+=1
            if frames>=19_200 && (frames-19_200)%4_800==0 { blocks.append(max(0,sum)/19_200) }
        }
    }
    /// nil for silence/below-gate audio or fewer than 400ms; no short-clip LUFS estimate is invented.
    public var integratedLUFS: Double? {
        let absolute=pow(10,(-70+0.691)/10)
        let first=blocks.filter { $0>absolute }
        guard !first.isEmpty else { return nil }
        let mean=first.reduce(0,+)/Double(first.count), threshold=max(absolute,mean*0.1)
        let gated=first.filter { $0>threshold }
        guard !gated.isEmpty else { return nil }
        return -0.691+10*log10(gated.reduce(0,+)/Double(gated.count))
    }
}

/// Linked dynamics. Without a learned profile the legacy high-pass/expander is
/// retained; denoised material already has a phase-preserving spectral high-pass.
struct SpeechProcessor48k {
    let settings: SpeechEnhancementSettings
    let channels: Int
    private var filters: [AudioBiquad]
    private var working: [Double]
    private var envelope=0.0, gate=1.0, compressor=1.0
    private let denoised: Bool
    init(channels: Int,settings: SpeechEnhancementSettings,denoised: Bool = false) throws {
        try settings.validate(); guard (1...2).contains(channels) else { throw RenderError.invalidSettings("Speech processing supports mono/stereo") }
        self.channels=channels; self.settings=settings; self.denoised=denoised
        filters=Array(repeating: .highPass(hz: settings.highPassHz),count: channels); working=Array(repeating: 0,count: channels)
    }
    mutating func process(_ samples: [Float]) throws -> [Float] {
        guard samples.count%channels==0 else { throw RenderError.invalidSettings("Incomplete PCM frame") }
        var output=[Float](repeating: 0,count: samples.count)
        let attack=exp(-1/(0.008*48_000)), release=exp(-1/(0.12*48_000))
        // Slow RMS leveling avoids following individual speech cycles/phonemes,
        // which distorted the noisy speech even when normalization was disabled.
        let levelAttack=denoised ? exp(-1/(0.5*48_000)) : attack
        let levelRelease=denoised ? exp(-1/(2*48_000)) : release
        let compressionSmoothing=exp(-1/(0.1*48_000))
        for offset in stride(from: 0,to: samples.count,by: channels) {
            var power=0.0
            for channel in 0..<channels {
                let x=Double(samples[offset+channel]); guard x.isFinite else { throw RenderError.decode("Nonfinite speech sample") }
                working[channel]=denoised ? x : filters[channel].process(x); power=max(power,working[channel]*working[channel])
            }
            let coefficient=power>envelope ? levelAttack : levelRelease
            envelope=coefficient*envelope+(1-coefficient)*power
            let level=10*log10(max(envelope,1e-20))
            let reduction=max(-settings.noiseReductionDB,min(0,(level-settings.noiseThresholdDB)*2))
            let desiredGate=denoised ? 1 : pow(10,reduction/20), gateCoefficient=desiredGate>gate ? attack : release
            gate=gateCoefficient*gate+(1-gateCoefficient)*desiredGate
            let over=level-settings.compressorThresholdDB, knee=6.0
            let compressed: Double
            if over <= -knee/2 { compressed=0 }
            else if over >= knee/2 { compressed=over*(1-1/settings.compressorRatio) }
            else { compressed=pow(over+knee/2,2)/(2*knee)*(1-1/settings.compressorRatio) }
            let desiredCompressor=pow(10,-compressed/20), compCoefficient=denoised ? compressionSmoothing : (desiredCompressor<compressor ? attack : release)
            compressor=compCoefficient*compressor+(1-compCoefficient)*desiredCompressor
            for channel in 0..<channels { output[offset+channel]=Float(working[channel]*gate*compressor) }
        }
        return output
    }
}

struct SpeechPeakLimiter {
    let ceiling: Double
    let channels: Int
    private var gain=1.0
    private(set) var limited=false
    private(set) var peak=0.0
    init(channels: Int,ceilingDBFS: Double) { self.channels=channels; ceiling=pow(10,ceilingDBFS/20) }
    mutating func process(_ samples: [Float],normalizationGain: Double) -> [Float] {
        var output=[Float](repeating: 0,count: samples.count)
        let release=exp(-1/(0.06*48_000))
        for offset in stride(from: 0,to: samples.count,by: channels) {
            var inputPeak=0.0
            for channel in 0..<channels { inputPeak=max(inputPeak,abs(Double(samples[offset+channel])*normalizationGain)) }
            let desired=min(1,ceiling/max(inputPeak,1e-20))
            if desired<gain { gain=desired; limited=true } else { gain=release*gain+(1-release)*desired }
            for channel in 0..<channels {
                let value=Double(samples[offset+channel])*normalizationGain*gain
                output[offset+channel]=Float(value); peak=max(peak,abs(value))
            }
        }
        return output
    }
}

public struct SpeechEnhancementReport: Sendable {
    public let frames: Int64
    public let channels: Int
    public let sampleRate: Double = 48_000
    public let targetLUFS: Double
    public let processedLUFS: Double?
    public let outputLUFS: Double?
    public let normalizationGainDB: Double
    public let samplePeakDBFS: Double?
    public let peakLimited: Bool
    public var reachedTarget: Bool { outputLUFS.map { abs($0-targetLUFS)<0.2 } ?? false }
}

public enum SpeechEnhancer {
    /// Convenience for short interleaved 48kHz test/preview buffers; processFile streams recordings.
    public static func process(interleaved samples: [Float],channels: Int,settings: SpeechEnhancementSettings = .init()) throws -> (samples: [Float],report: SpeechEnhancementReport) {
        try settings.validate()
        guard (1...2).contains(channels),samples.count%channels==0 else { throw RenderError.invalidSettings("Incomplete mono/stereo PCM") }
        guard samples.allSatisfy(\.isFinite) else { throw RenderError.decode("Nonfinite speech sample") }
        var learner=SpeechNoiseLearner48k(channels: channels)
        if settings.noiseReductionDB>0 {
            for start in stride(from: 0,to: samples.count,by: 4096*channels) {
                learner.process(Array(samples[start..<min(samples.count,start+4096*channels)]))
            }
        }
        let profile=settings.noiseReductionDB>0 ? learner.profile : nil
        var processor=try SpeechProcessor48k(channels: channels,settings: settings,denoised: profile != nil)
        var processed: [Float]=[]
        if let profile {
            var reducer=SpeechNoiseReducer48k(channels: channels,profile: profile,settings: settings)
            for start in stride(from: 0,to: samples.count,by: 4096*channels) {
                processed.append(contentsOf: try processor.process(reducer.process(Array(samples[start..<min(samples.count,start+4096*channels)]))))
            }
            processed.append(contentsOf: try processor.process(reducer.finish()))
        } else { processed=try processor.process(samples) }
        var meter=try LoudnessMeter48k(channels: channels); try meter.process(interleaved: processed)
        let before=meter.integratedLUFS
        let normalize=settings.normalizeLoudness && (profile?.containsSpeech ?? true)
        var gainDB=normalize ? before.map { min(60,settings.targetLUFS-$0) } ?? 0 : 0
        var output=processed, final: Double?, limiter=SpeechPeakLimiter(channels: channels,ceilingDBFS: settings.peakCeilingDBFS)
        for attempt in 0..<4 {
            limiter=SpeechPeakLimiter(channels: channels,ceilingDBFS: settings.peakCeilingDBFS)
            output=limiter.process(processed,normalizationGain: pow(10,gainDB/20))
            var result=try LoudnessMeter48k(channels: channels); try result.process(interleaved: output); final=result.integratedLUFS
            guard attempt<3,normalize,let final,abs(final-settings.targetLUFS)>=0.2,gainDB<60 else { break }
            gainDB=min(60,gainDB+settings.targetLUFS-final)
        }
        return (output,SpeechEnhancementReport(frames: Int64(samples.count/channels),channels: channels,targetLUFS: settings.targetLUFS,processedLUFS: before,outputLUFS: final,normalizationGainDB: gainDB,samplePeakDBFS: limiter.peak>0 ? 20*log10(limiter.peak) : nil,peakLimited: limiter.limited))
    }
}
