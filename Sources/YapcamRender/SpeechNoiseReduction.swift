import Foundation

/// Fixed-size, real-input FFT implemented here. No model, plug-in, or audio-unit service.
private struct SpeechFFT {
    static let size = 2048
    let reverse: [Int]
    let cosine: [Double]
    let sine: [Double]
    init() {
        reverse = (0..<Self.size).map { i in
            var source = i, result = 0
            for _ in 0..<11 { result = (result << 1) | (source & 1); source >>= 1 }
            return result
        }
        cosine = (0..<Self.size/2).map { cos(2 * .pi * Double($0) / Double(Self.size)) }
        sine = (0..<Self.size/2).map { sin(2 * .pi * Double($0) / Double(Self.size)) }
    }
    func transform(_ real: inout [Double], _ imaginary: inout [Double], inverse: Bool = false) {
        let n = Self.size
        for i in 0..<n where reverse[i] > i { real.swapAt(i, reverse[i]); imaginary.swapAt(i, reverse[i]) }
        var width = 2
        while width <= n {
            let half = width/2, step = n/width
            for start in stride(from: 0, to: n, by: width) {
                for j in 0..<half {
                    let index = j*step, a = start+j, b = a+half
                    let wi = inverse ? sine[index] : -sine[index]
                    let r = cosine[index]*real[b] - wi*imaginary[b]
                    let i = cosine[index]*imaginary[b] + wi*real[b]
                    real[b] = real[a]-r; imaginary[b] = imaginary[a]-i
                    real[a] += r; imaginary[a] += i
                }
            }
            width *= 2
        }
        if inverse { for i in 0..<n { real[i] /= Double(n); imaginary[i] /= Double(n) } }
    }
}

/// Carries only a few windows regardless of recording length or decoder chunk boundaries.
private struct SpeechWindows {
    static let size = SpeechFFT.size, hop = 512
    let channels: Int
    private var samples: [Float]
    private var offset = 0
    init(channels: Int, centered: Bool = false) {
        self.channels = channels
        samples = Array(repeating: 0, count: centered ? Self.size/2*channels : 0)
    }
    mutating func append(_ input: [Float]) {
        if offset > 0 { samples.removeFirst(offset); offset = 0 }
        samples.append(contentsOf: input)
    }
    mutating func next() -> [Float]? {
        guard samples.count-offset >= Self.size*channels else { return nil }
        let frame = Array(samples[offset..<offset+Self.size*channels])
        offset += Self.hop*channels
        return frame
    }
}

struct SpeechNoiseProfile48k {
    let power: [Double]
    let containsSpeech: Bool
}

/// Offline first pass: retain at most 128 lowest-energy complete windows, about 1 MiB.
/// A flat broadband spectrum and sufficient observations are required. Tonal/no-pause
/// material uses the legacy high-pass/expander rather than treating a vowel as noise.
struct SpeechNoiseLearner48k {
    private let channels: Int
    private let fft = SpeechFFT()
    private let window = (0..<SpeechFFT.size).map { sin(.pi * (Double($0)+0.5) / Double(SpeechFFT.size)) }
    private var windows: SpeechWindows
    private var quiet: [(energy: Double, power: [Double])] = []
    private var histogram = Array(repeating: 0, count: 321)
    private var count = 0
    init(channels: Int) { self.channels = channels; windows = SpeechWindows(channels: channels) }
    mutating func process(_ samples: [Float]) {
        windows.append(samples)
        while let frame = windows.next() {
            var power = Array(repeating: 0.0, count: SpeechFFT.size/2+1)
            for channel in 0..<channels {
                var real = (0..<SpeechFFT.size).map { Double(frame[$0*channels+channel])*window[$0] }
                var imaginary = Array(repeating: 0.0, count: SpeechFFT.size)
                fft.transform(&real, &imaginary)
                for bin in power.indices { power[bin] += (real[bin]*real[bin]+imaginary[bin]*imaginary[bin])/Double(channels) }
            }
            let energy = power.reduce(0,+)
            // Capture gaps/digital silence are not observations of the room's
            // noise floor; otherwise a long gap would displace every noise window.
            guard energy > 1e-14 else { continue }
            let bucket = min(320, max(0, Int((10*log10(max(energy,1e-16))+160).rounded())))
            histogram[bucket] += 1; count += 1
            if quiet.count < 128 || energy < quiet.last!.energy {
                let index = quiet.firstIndex { $0.energy > energy } ?? quiet.endIndex
                quiet.insert((energy,power), at: index)
                if quiet.count > 128 { quiet.removeLast() }
            }
        }
    }
    var profile: SpeechNoiseProfile48k? {
        guard quiet.count >= 16 else { return nil }
        var power = Array(repeating: 0.0, count: SpeechFFT.size/2+1)
        for row in quiet { for i in power.indices { power[i] += row.power[i]/Double(quiet.count) } }
        let energy = power.reduce(0,+), mean = energy/Double(power.count)
        guard mean > 1e-14 else { return nil }
        let flatness = exp(power.reduce(0) { $0+log(max($1,1e-20)) }/Double(power.count))/mean
        guard flatness > 0.25 else { return nil }
        let floorDB = 10*log10(energy*2)
        let active = histogram.enumerated().reduce(0) { $0 + (Double($1.offset-160) > floorDB ? $1.element : 0) }
        return SpeechNoiseProfile48k(power: power, containsSpeech: active >= max(8,count/20))
    }
}

/// Centered 2048-sample sine-window STFT, 75% overlap. The same real gain is used
/// in both channels, preserving phase/stereo image. Normalized overlap-add and
/// explicit leading/trailing padding retain every original file-local sample.
struct SpeechNoiseReducer48k {
    private let channels: Int
    private let profile: SpeechNoiseProfile48k
    private let settings: SpeechEnhancementSettings
    private let fft = SpeechFFT()
    private let window = (0..<SpeechFFT.size).map { sin(.pi * (Double($0)+0.5) / Double(SpeechFFT.size)) }
    private var windows: SpeechWindows
    private var overlap: [Double]
    private var weight = Array(repeating: 0.0, count: SpeechFFT.size)
    private var emitted = -SpeechFFT.size/2
    private var inputFrames = 0
    private var finished = false
    init(channels: Int, profile: SpeechNoiseProfile48k, settings: SpeechEnhancementSettings) {
        self.channels = channels; self.profile = profile; self.settings = settings
        windows = SpeechWindows(channels: channels, centered: true)
        overlap = Array(repeating: 0, count: SpeechFFT.size*channels)
    }
    mutating func process(_ samples: [Float]) -> [Float] {
        precondition(!finished && samples.count%channels == 0)
        inputFrames += samples.count/channels
        windows.append(samples)
        return drain()
    }
    mutating func finish() -> [Float] {
        precondition(!finished); finished = true
        windows.append(Array(repeating: 0, count: SpeechFFT.size*channels))
        return drain()
    }
    private mutating func drain() -> [Float] {
        var output: [Float] = []
        let n = SpeechFFT.size, hop = SpeechWindows.hop
        while let frame = windows.next() {
            var real: [[Double]] = [], imaginary: [[Double]] = []
            var power = Array(repeating: 0.0, count: n/2+1)
            for channel in 0..<channels {
                var r = (0..<n).map { Double(frame[$0*channels+channel])*window[$0] }
                var i = Array(repeating: 0.0, count: n)
                fft.transform(&r, &i)
                for bin in power.indices { power[bin] += (r[bin]*r[bin]+i[bin]*i[bin])/Double(channels) }
                real.append(r); imaginary.append(i)
            }
            let quiet = power.reduce(0,+) < profile.power.reduce(0,+)*1.6
            let floor = pow(10,-settings.noiseReductionDB/20)
            let pauseGain = quiet ? pow(10,-max(18,settings.noiseReductionDB)/20) : 1
            let gain = power.indices.map { bin -> Double in
                let wiener = max(floor,1-1.1*profile.power[bin]/max(power[bin],1e-20))
                let hz = max(1e-6,Double(bin)*48_000/Double(n))
                // Butterworth magnitude only: avoid causal HP phase distortion of speech.
                let highPass = 1/sqrt(1+pow(settings.highPassHz/hz,4))
                return wiener*pauseGain*highPass
            }
            for channel in 0..<channels {
                for bin in 0..<n { let g = gain[min(bin,n-bin)]; real[channel][bin] *= g; imaginary[channel][bin] *= g }
                fft.transform(&real[channel], &imaginary[channel], inverse: true)
                for i in 0..<n { overlap[i*channels+channel] += real[channel][i]*window[i] }
            }
            for i in 0..<n { weight[i] += window[i]*window[i] }
            for i in 0..<hop where emitted+i >= 0 && emitted+i < inputFrames {
                for channel in 0..<channels { output.append(Float(overlap[i*channels+channel]/max(weight[i],1e-20))) }
            }
            emitted += hop
            overlap.removeFirst(hop*channels); overlap.append(contentsOf: repeatElement(0,count: hop*channels))
            weight.removeFirst(hop); weight.append(contentsOf: repeatElement(0,count: hop))
        }
        return output
    }
}
