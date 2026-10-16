import AVFoundation

/// Plays a cue and reports when it has finished. Injected so timing is testable.
protocol CuePlayer: Sendable {
    /// Starts playback and returns when it has finished. Throws if it cannot start.
    func play(_ cue: Cue, gain: Float) async throws
}

enum Cue { case start, stop }

/// Begin-record sound plays quietly before capture starts; recording waits for it to finish
/// or for `limit`, whichever comes first. Never throws, never blocks longer than `limit`.
enum StartSoundGate {
    static let gain: Float = 0.33
    static let limit: Duration = .milliseconds(540)

    /// Returns when capture may start.
    static func run(player: CuePlayer, limit: Duration = limit, log: @escaping @Sendable (String) -> Void = { NSLog("[Yapcam] start sound: %@", $0) }) async {
        let outcome = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                do { try await player.play(.start, gain: gain); return true }
                catch { log("not played: \(error.localizedDescription)"); return true }
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !outcome { log("still playing after \(limit); starting capture anyway") }
    }
}

/// Our own chime, synthesized in code (no sampled or system audio): two short decaying sine tones.
enum ChimeSynth {
    static let sampleRate = 44_100.0

    /// Start: rising pair (E5 → A5). Stop: falling pair (A5 → E5 lower octave feel).
    static func tones(_ cue: Cue) -> [(freq: Double, length: Double)] {
        switch cue {
        case .start: return [(659.25, 0.14), (880.0, 0.20)]
        case .stop: return [(880.0, 0.12), (587.33, 0.20)]
        }
    }

    static func samples(_ cue: Cue) -> [Float] {
        var out: [Float] = []
        for (freq, length) in tones(cue) {
            let n = Int(length * sampleRate)
            for i in 0..<n {
                let t = Double(i) / sampleRate
                let attack = min(1, t / 0.005)
                let decay = exp(-t * 14)
                let release = min(1, Double(n - i) / (0.01 * sampleRate))
                out.append(Float(sin(2 * .pi * freq * t) * 0.8 * attack * decay * release))
            }
        }
        return out
    }

    static func duration(_ cue: Cue) -> Double { tones(cue).reduce(0) { $0 + $1.length } }

    /// 16-bit mono WAV bytes.
    static func wav(_ cue: Cue) -> Data {
        let pcm = samples(cue).map { Int16(max(-1, min(1, $0)) * 32_000) }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count * 2))
        d.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(pcm.count * 2))
        for s in pcm { u16(UInt16(bitPattern: s)) }
        return d
    }
}

/// Real output: AVAudioPlayer on the synthesized chime. Yapcam's own audio is excluded from
/// system-audio capture (`excludesCurrentProcessAudio`), so it cannot reach the recording.
final class ChimePlayer: CuePlayer, @unchecked Sendable {
    func play(_ cue: Cue, gain: Float) async throws {
        let player = try AVAudioPlayer(data: ChimeSynth.wav(cue))
        player.volume = gain
        guard player.prepareToPlay(), player.play() else { throw ChimeError.cannotStart }
        // Poll for completion; the caller's time limit bounds this.
        while player.isPlaying {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    enum ChimeError: LocalizedError {
        case cannotStart
        var errorDescription: String? { "the sound could not start (no output device?)" }
    }
}
