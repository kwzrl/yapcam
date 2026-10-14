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
    public init(source: Source, startNs: Int64, endNs: Int64, sourceStartNs: Int64 = 0, gain: Float = 1, loops: Bool = false, fadeInNs: Int64 = 0, fadeOutNs: Int64 = 0) {
        self.source = source; self.startNs = startNs; self.endNs = endNs; self.sourceStartNs = sourceStartNs; self.gain = gain; self.loops = loops; self.fadeInNs = fadeInNs; self.fadeOutNs = fadeOutNs
    }
}

/// Original procedural sounds, generated on demand. No third-party samples or recorded audio.
enum ProceduralAudio {
    static let sampleRate = 48_000
    static func samples(for source: AudioOverlay.Source) throws -> [Int16] {
        switch source {
        case .media: throw RenderError.invalidSettings("Media audio must be read from the project")
        case .click(let variant):
            let length = variant == .soft ? 0.08 : 0.05
            return (0..<Int(length*Double(sampleRate))).map { i in
                let t=Double(i)/Double(sampleRate)
                let f = variant == .soft ? 900.0 : 1800.0
                let signal = sin(2 * .pi * f * t) * exp(-t * 100) * 0.6 + sin(2 * .pi * f * 2.3 * t) * exp(-t * 180) * 0.15
                return Int16(max(-32767,min(32767,signal*32767)))
            }
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
    static func wav(_ samples: [Int16]) -> Data {
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
