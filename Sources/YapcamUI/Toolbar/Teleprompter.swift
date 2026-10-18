import AppKit
import SwiftUI
import YapcamDesign

/// Value ranges of the speaker-notes prompter (reference: speed 1–25 default 8, notepad opacity 0.4–1, font size 12–32 default 20).
enum PrompterRanges {
    static let speed: ClosedRange<Double> = 1...25
    static let speedDefault = 8.0
    static let opacity: ClosedRange<Double> = 0.4...1
    static let font: ClosedRange<Double> = 12...32
    static let fontDefault = 20.0
    static func clampedFont(_ v: Double) -> Double { min(max(v, font.lowerBound), font.upperBound) }
    static func clampedSpeed(_ v: Double) -> Double { min(max(v, speed.lowerBound), speed.upperBound) }
    /// Points per second for a speed setting.
    static func pointsPerSecond(_ speed: Double) -> Double { clampedSpeed(speed) * 4 }
}

/// The prompter's state: independent of the recording phase (play scrolls whether or not a take is running).
extension PrompterModel {
    /// Tooltip for the play button, naming the real shortcut when one is set.
    static func playHelp(playing: Bool, shortcut: String?) -> String {
        let what = playing ? "Pause the prompter" : "Scroll the notes"
        return shortcut.map { "\(what) (\($0))" } ?? what
    }
}

@MainActor final class PrompterModel: ObservableObject {
    static let shared = PrompterModel()
    private let d = AppDefaults.store

    @Published var playing = false
    @Published var offset = 0.0
    @Published var speed: Double { didSet { d.set(speed, forKey: "teleprompterSpeed.v2") } }
    @Published var opacity: Double { didSet { d.set(opacity, forKey: "teleprompterOpacity") } }
    @Published var fontSize: Double { didSet { d.set(fontSize, forKey: "teleprompterSize") } }

    init() {
        let s = d.object(forKey: "teleprompterSpeed.v2") as? Double
        speed = s.map(PrompterRanges.clampedSpeed) ?? PrompterRanges.speedDefault
        opacity = min(max(d.object(forKey: "teleprompterOpacity") as? Double ?? 1, PrompterRanges.opacity.lowerBound), 1)
        fontSize = PrompterRanges.clampedFont(d.object(forKey: "teleprompterSize") as? Double ?? PrompterRanges.fontDefault)
    }

    var sizeIsDefault: Bool { fontSize == PrompterRanges.fontDefault }
    func resetSize() { fontSize = PrompterRanges.fontDefault }

    /// Advances the scroll while playing; stops at the end of the text so the button returns to "play".
    func tick(dt: Double, maxOffset: Double) {
        guard playing else { return }
        guard maxOffset > 0, offset < maxOffset else { playing = false; return }
        offset = min(offset + PrompterRanges.pointsPerSecond(speed) * dt, maxOffset)
        if offset >= maxOffset { playing = false }
    }

    func togglePlay(maxOffset: Double = .infinity) {
        if playing { playing = false; return }
        if offset >= maxOffset { offset = 0 }       // at the end: play starts again from the top
        playing = true
    }
}

/// Speaker notes and the prompter in one panel: editable when stopped, scrolling and read-only while playing.
struct SpeakerNotesView: View {
    @EnvironmentObject var rec: RecordingController
    @ObservedObject var prompter = PrompterModel.shared
    @State private var position = ScrollPosition()
    @State private var maxOffset = 0.0
    @State private var showSettings = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tickCount = 0
    private let tick = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { prompter.togglePlay(maxOffset: maxOffset) } label: { Image(systemName: prompter.playing ? "pause.fill" : "play.fill") }
                    .buttonStyle(CircleButtonStyle(active: prompter.playing, size: 28))
                    .help(PrompterModel.playHelp(playing: prompter.playing, shortcut: AppSettings.shared.combo(for: .prompterPlay)?.display)).accessibilityLabel(prompter.playing ? "Pause prompter" : "Play prompter")
                Text("Speaker notes").font(Yap.Font.body).foregroundStyle(Yap.label)
                Spacer()
                Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(CircleButtonStyle(size: 28)).help("Prompter settings").accessibilityLabel("Prompter settings")
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) { PrompterSettings(prompter: prompter) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Hairline()
            if prompter.playing {
                ScrollView {
                    Text(rec.notes.isEmpty ? "No notes yet." : rec.notes)
                        .font(.system(size: prompter.fontSize)).foregroundStyle(Yap.title)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
                .scrollPosition($position)
                .onScrollGeometryChange(for: Double.self, of: { max(0, $0.contentSize.height - $0.containerSize.height) }) { _, new in maxOffset = new }
                .onScrollGeometryChange(for: Double.self, of: { $0.contentOffset.y }) { _, new in prompter.offset = new }
            } else {
                TextEditor(text: $rec.notes)
                    .font(.system(size: prompter.fontSize)).scrollContentBackground(.hidden)
                    .padding(10)
                    .overlay(alignment: .topLeading) {
                        if rec.notes.isEmpty {
                            Text("Type what you want to say. Press play to scroll it.")
                                .font(.system(size: prompter.fontSize)).foregroundStyle(Yap.faint)
                                .padding(.horizontal, 15).padding(.top, 10).allowsHitTesting(false)
                        }
                    }
            }
        }
        .background(Yap.ground)
        .opacity(prompter.opacity)
        .onChange(of: prompter.playing) { _, playing in if playing { position.scrollTo(y: prompter.offset) } }
        .onReceive(tick) { _ in
            guard prompter.playing else { return }
            prompter.tick(dt: 0.05, maxOffset: maxOffset)
            // Reduce Motion: move in one step per second instead of continuously.
            tickCount += 1
            if !reduceMotion || tickCount % 20 == 0 { position.scrollTo(y: prompter.offset) }
        }
    }
}

private struct PrompterSettings: View {
    @ObservedObject var prompter: PrompterModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ValueSlider("Scroll speed", value: "\(Int(prompter.speed))", amount: norm($prompter.speed, PrompterRanges.speed))
            ValueSlider("Notepad opacity", value: String(format: "%.1f", prompter.opacity), amount: norm($prompter.opacity, PrompterRanges.opacity))
            ValueSlider("Text size", value: "\(Int(prompter.fontSize))", amount: norm($prompter.fontSize, PrompterRanges.font))
            Button("Reset text size") { prompter.resetSize() }.disabled(prompter.sizeIsDefault)
        }
        .padding(16).frame(width: 260)
    }
    private func norm(_ b: Binding<Double>, _ r: ClosedRange<Double>) -> Binding<Double> {
        Binding(get: { (b.wrappedValue - r.lowerBound) / (r.upperBound - r.lowerBound) },
                set: { b.wrappedValue = r.lowerBound + min(max($0, 0), 1) * (r.upperBound - r.lowerBound) })
    }
}
