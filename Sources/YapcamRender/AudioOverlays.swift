import Foundation

public struct AudioOverlay: Sendable, Equatable {
    public enum Click: Sendable { case soft, crisp }
    public enum Music: Sendable { case calm, bright }
    public enum Source: Sendable, Equatable { case media(relativePath: String), click(Click), music(Music) }
    public var source: Source
    public var startNs: Int64
    public var endNs: Int64
    public var sourceStartNs: Int64
    public var gain: Float
    public var loops: Bool
    public var fadeInNs: Int64
    public var fadeOutNs: Int64
    /// Optional evaluated dB-ramp endpoints; nil retains constant gain.
    public var gainStart: Float?
    public var gainEnd: Float?
    /// Original envelope bounds survive Core duck splits and export-range trimming.
    public var envelopeStartNs: Int64?
    public var envelopeEndNs: Int64?
    public var sourceDurationNs: Int64?
    /// Core fades multiply; existing custom-source overlays retain their minimum envelope.
    public var multiplyFades: Bool
    public init(source: Source, startNs: Int64, endNs: Int64, sourceStartNs: Int64 = 0, gain: Float = 1, loops: Bool = false, fadeInNs: Int64 = 0, fadeOutNs: Int64 = 0, gainStart: Float? = nil, gainEnd: Float? = nil, envelopeStartNs: Int64? = nil, envelopeEndNs: Int64? = nil, sourceDurationNs: Int64? = nil, multiplyFades: Bool = false) {
        self.source = source; self.startNs = startNs; self.endNs = endNs; self.sourceStartNs = sourceStartNs; self.gain = gain; self.loops = loops; self.fadeInNs = fadeInNs; self.fadeOutNs = fadeOutNs
        self.gainStart=gainStart; self.gainEnd=gainEnd; self.envelopeStartNs=envelopeStartNs
        self.envelopeEndNs=envelopeEndNs; self.sourceDurationNs=sourceDurationNs; self.multiplyFades=multiplyFades
    }
    var envelopeStart: Int64 { envelopeStartNs ?? startNs }
    var envelopeEnd: Int64 { envelopeEndNs ?? endNs }
    func validate() throws {
        guard startNs>=0,endNs>startNs,sourceStartNs>=0,fadeInNs>=0,fadeOutNs>=0,
              envelopeStart>=0,envelopeStart<=startNs,envelopeEnd>=endNs,
              [gain,gainStart ?? gain,gainEnd ?? gain].allSatisfy({ $0.isFinite && $0>=0 }),
              sourceDurationNs.map({ $0>0 && sourceStartNs<$0 }) ?? true else {
            throw RenderError.invalidSettings("Invalid evaluated audio overlay")
        }
    }
    func gain(atTimelineNs ns: Int64) -> Float {
        let a=gainStart ?? gain, b=gainEnd ?? gain
        let fraction=min(1,max(0,Double(ns-startNs)/Double(endNs-startNs)))
        let ramp=a>0 && b>0 ? exp(log(Double(a))+(log(Double(b))-log(Double(a)))*fraction) : Double(a)+(Double(b)-Double(a))*fraction
        let incoming=fadeInNs>0 ? min(1,max(0,Double(ns-envelopeStart)/Double(fadeInNs))) : 1
        let outgoing=fadeOutNs>0 ? min(1,max(0,Double(envelopeEnd-ns)/Double(fadeOutNs))) : 1
        return Float(ramp*(multiplyFades ? incoming*outgoing : min(incoming,outgoing)))
    }
}

/// Original procedural sounds, generated on demand. No third-party samples or recorded audio.
public enum ProceduralAudio {
    public static let sampleRate = 48_000
    public static func samples(for source: AudioOverlay.Source) throws -> [Int16] {
        switch source {
        case .media: throw RenderError.invalidSettings("Media audio must be read from the project")
        case .click(let variant): return clickSamples(variant)
        case .music(let style):
            let roots: [Double] = style == .calm ? [130.8128,174.6141,146.8324,195.9977] : [261.6256,329.6276,349.2282,391.9954]
            return (0..<(8*sampleRate)).map { i in
                let t=Double(i)/Double(sampleRate), section=min(3,Int(t/2)), local=t.truncatingRemainder(dividingBy: 2)
                let attack=min(1,local/0.15), release=min(1,(2-local)/0.3)
                let root=roots[section]
                let chord=(sin(2 * .pi * root*t)+sin(2 * .pi * root*1.25*t)+sin(2 * .pi * root*1.5*t))/3
                return Int16(chord*attack*release*0.3*32767)
            }
        }
    }
    /// The exact click used by preview and export, wrapped as mono 48 kHz PCM WAV.
    public static func clickSampleWAV(variant: AudioOverlay.Click) -> Data {
        wav(clickSamples(variant))
    }
    private static func clickSamples(_ variant: AudioOverlay.Click) -> [Int16] {
        let length = variant == .soft ? 0.08 : 0.05
        return (0..<Int(length*Double(sampleRate))).map { i in
            let t=Double(i)/Double(sampleRate)
            let f = variant == .soft ? 900.0 : 1800.0
            let signal = sin(2 * .pi * f * t) * exp(-t * 100) * 0.6 + sin(2 * .pi * f * 2.3 * t) * exp(-t * 180) * 0.15
            return Int16(max(-32767,min(32767,signal*32767)))
        }
    }
    public static func wav(_ samples: [Int16]) -> Data {
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func u32(_ value: UInt32) { var le=value.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var le=value.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        let bytes=UInt32(samples.count*2)
        ascii("RIFF"); u32(bytes+36); ascii("WAVEfmt "); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate*2)); u16(2); u16(16); ascii("data"); u32(bytes)
        for sample in samples { u16(UInt16(bitPattern: sample)) }
        return data
    }
}
