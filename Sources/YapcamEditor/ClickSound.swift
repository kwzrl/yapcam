import AVFoundation
import SwiftUI
import YapcamCore
import YapcamDesign

/// Click sounds under Cursor (BS-10): None / Soft / Crisp, a 0–100 % volume that maps to `gain_db`, and a preview.
public enum ClickSoundSettings {
    public static let defaultPercent = 25.0
    /// Core accepts -48…12 dB; 0 % is the floor of that range (mute).
    public static let floorDb = -48.0

    public static func gainDb(percent: Double) -> Double {
        let p = min(max(percent, 0), 100) / 100
        return p <= 0 ? floorDb : max(floorDb, 20 * log10(p))
    }
    public static func percent(gainDb: Double) -> Double {
        gainDb <= floorDb ? 0 : min(100, max(0, pow(10, gainDb / 20) * 100))
    }

    /// The same two procedural clicks the renderer mixes into exports (see `ProceduralAudio` in YapcamRender), as mono
    /// 16-bit PCM at 48 kHz. Peak scales linearly with `percent / 100`.
    public static func previewSamples(variant: String, percent: Double) -> [Int16] {
        let rate = 48_000.0, soft = variant != "crisp"
        let f = soft ? 900.0 : 1800.0, length = soft ? 0.08 : 0.05
        let gain = min(max(percent, 0), 100) / 100
        return (0..<Int(length * rate)).map { i in
            let t = Double(i) / rate
            let s = sin(2 * .pi * f * t) * exp(-t * 100) * 0.6 + sin(2 * .pi * f * 2.3 * t) * exp(-t * 180) * 0.15
            return Int16(max(-32767, min(32767, s * gain * 32767)))
        }
    }

    static func wav(_ samples: [Int16]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + samples.count * 2)); d.append(contentsOf: "WAVEfmt ".utf8)
        u32(16); u16(1); u16(1); u32(48_000); u32(96_000); u16(2); u16(16)
        d.append(contentsOf: "data".utf8); u32(UInt32(samples.count * 2))
        for s in samples { u16(UInt16(bitPattern: s)) }
        return d
    }
}

extension EditorModel {
    /// "none" | "soft" | "crisp" from the stored settings.
    public var clickSoundChoice: String { bool("audio.click_sound.enabled") ? string("audio.click_sound.variant", default: "soft") : "none" }
    public var clickSoundPercent: Double { ClickSoundSettings.percent(gainDb: number("audio.click_sound.gain_db", default: ClickSoundSettings.gainDb(percent: ClickSoundSettings.defaultPercent))) }

    /// One undo step: choosing a variant turns the sounds on, "none" turns them off.
    public func setClickSound(_ choice: String) {
        if choice == "none" { set("audio.click_sound.enabled", bool: false); return }
        guard choice == "soft" || choice == "crisp" else { return }
        perform(.batch([.set(path: "audio.click_sound.enabled", value: .bool(true)), .set(path: "audio.click_sound.variant", value: .string(choice))]))
    }
    public func setClickSoundPercent(_ percent: Double) { set("audio.click_sound.gain_db", number: ClickSoundSettings.gainDb(percent: percent)) }
}

@MainActor private var clickPreviewPlayer: AVAudioPlayer?

struct ClickSoundGroup: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        InspectorGroup("Click sound") {
            let choice = model.clickSoundChoice
            SegmentSwitch([(id: "none", title: "None"), (id: "soft", title: "Soft"), (id: "crisp", title: "Crisp")],
                          selection: Binding(get: { choice }, set: { model.setClickSound($0) }), height: 26)
                .padding(.horizontal, -4)
                .accessibilityLabel("Click sound")
            if choice != "none" {
                CommitSlider(title: "Volume", range: 0...100, get: { model.clickSoundPercent }, commit: { model.setClickSoundPercent($0) },
                             text: { $0 < 0.5 ? "Muted" : "\(Int($0.rounded())) %" }, step: 1, defaultValue: ClickSoundSettings.defaultPercent)
                InspectorAction("Play click preview", symbol: "speaker.wave.2") { preview(choice) }
            }
            InspectorNote("Plays on every recorded click.")
        }
    }

    private func preview(_ variant: String) {
        let pcm = ClickSoundSettings.previewSamples(variant: variant, percent: max(model.clickSoundPercent, 1))
        clickPreviewPlayer = try? AVAudioPlayer(data: ClickSoundSettings.wav(pcm))
        clickPreviewPlayer?.volume = model.clickSoundPercent < 0.5 ? 0 : 1
        clickPreviewPlayer?.play()
    }
}
