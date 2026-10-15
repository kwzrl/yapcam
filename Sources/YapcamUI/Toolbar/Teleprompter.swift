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
    @AppStorage("teleprompterSize") private var size = 28.0
    @AppStorage("teleprompterSpeed") private var speed = 0.0     // points per second, 0 = manual
    @State private var position = ScrollPosition()
    @State private var offset = 0.0
    private let tick = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "text.alignleft").foregroundStyle(.secondary)
                Text("Teleprompter").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                Slider(value: $size, in: 16...64).frame(width: 90)
                Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                Image(systemName: "tortoise").foregroundStyle(.secondary)
                Slider(value: $speed, in: 0...120).frame(width: 80).help(speed == 0 ? "Auto-scroll off" : "Auto-scroll speed")
                Image(systemName: "hare").foregroundStyle(.secondary)
                Button { offset = 0; position.scrollTo(y: 0) } label: { Image(systemName: "arrow.up.to.line") }.help("Back to top")
                Button(action: close) { Image(systemName: "xmark") }.help("Close")
            }
            .buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollView {
                Text(rec.notes.isEmpty ? "No notes yet. Type them in the Notes popover on the toolbar." : rec.notes)
                    .font(.system(size: size))
                    .foregroundStyle(rec.notes.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: Double.self, of: { $0.contentOffset.y }) { _, new in offset = new }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .onReceive(tick) { _ in
            guard speed > 0, rec.phase == .recording else { return }
            offset += speed * 0.05
            position.scrollTo(y: offset)
        }
    }
}
