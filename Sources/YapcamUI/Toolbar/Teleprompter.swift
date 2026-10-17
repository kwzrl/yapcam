import AppKit
import SwiftUI

/// Floating, capture-excluded panel that shows the speaker notes large while recording,
/// optionally auto-scrolling at a chosen speed.
@MainActor final class TeleprompterController {
    static let shared = TeleprompterController()
    private var panel: NSPanel?
    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 520, height: 240),
                            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.level = .floating; p.isMovableByWindowBackground = true; p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.title = "Yapcam Teleprompter"
            p.contentView = NSHostingView(rootView: TeleprompterView(close: { [weak self] in self?.hide() })
                .environmentObject(RecordingController.shared))
            RecordingController.shared.engine.registerExcluded(p)
            if let s = NSScreen.main {
                p.setFrameOrigin(CGPoint(x: s.visibleFrame.midX - 260, y: s.visibleFrame.maxY - 260))
            }
            panel = p
        }
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

struct TeleprompterView: View {
    let close: () -> Void
    @EnvironmentObject var rec: RecordingController
    @AppStorage("teleprompterSize", store: AppDefaults.store) private var size = PrompterRanges.fontDefault
    @AppStorage("teleprompterSpeed", store: AppDefaults.store) private var speed = 0.0     // 0…25, 0 = manual (×4 = points per second)
    @AppStorage("teleprompterOpacity", store: AppDefaults.store) private var notepadOpacity = 1.0
    @State private var position = ScrollPosition()
    @State private var offset = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tickCount = 0
    private let tick = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "text.alignleft").foregroundStyle(.secondary)
                Text("Teleprompter").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                Slider(value: $size, in: PrompterRanges.font).frame(width: 90).accessibilityLabel("Text size")
                Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                Image(systemName: "tortoise").foregroundStyle(.secondary)
                Slider(value: $speed, in: PrompterRanges.speed).frame(width: 80).help(speed == 0 ? "Auto-scroll off" : "Auto-scroll speed")
                    .accessibilityLabel("Auto-scroll speed").accessibilityValue(speed == 0 ? "Off" : "speed \(Int(speed)) of 25")
                Image(systemName: "hare").foregroundStyle(.secondary)
                Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary).accessibilityHidden(true)
                Slider(value: $notepadOpacity, in: PrompterRanges.opacity).frame(width: 60).help("Notepad opacity").accessibilityLabel("Notepad opacity")
                Button { offset = 0; position.scrollTo(y: 0) } label: { Image(systemName: "arrow.up.to.line") }.help("Back to top").accessibilityLabel("Back to top")
                Button(action: close) { Image(systemName: "xmark") }.help("Close")
            }
            .buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollView {
                Text(rec.notes.isEmpty ? "No notes yet. Type them in the Notes popover on the toolbar." : rec.notes)
                    .font(.system(size: PrompterRanges.clampedFont(size)))
                    .foregroundStyle(rec.notes.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: Double.self, of: { $0.contentOffset.y }) { _, new in offset = new }
        }
        .panelSurface(cornerRadius: 14)
        .opacity(notepadOpacity)
        .onReceive(tick) { _ in
            guard speed > 0, rec.prompterPlaying, rec.phase == .recording else { return }
            offset += speed * 4 * 0.05
            // Reduce Motion: move in one step per second instead of continuously.
            tickCount += 1
            if !reduceMotion || tickCount % 20 == 0 { position.scrollTo(y: offset) }
        }
    }
}

/// Value ranges of the speaker-notes prompter (reference: speed 0–25, notepad opacity 0.4–1, font size 12–32).
enum PrompterRanges {
    static let speed: ClosedRange<Double> = 0...25
    static let opacity: ClosedRange<Double> = 0.4...1
    static let font: ClosedRange<Double> = 12...32
    static let fontDefault = 20.0
    static func clampedFont(_ v: Double) -> Double { min(max(v, font.lowerBound), font.upperBound) }
}
