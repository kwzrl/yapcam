import AppKit
import SwiftUI
import YapcamDesign

/// A small floating "working…" card for steps with no progress to show (importing a video).
@MainActor final class BusyHUD {
    static let shared = BusyHUD()
    private var panel: NSPanel?
    private(set) var text: String?
    var isShowing: Bool { text != nil }

    static func importText(_ video: URL) -> String { "Importing “\(video.lastPathComponent)”…" }

    func show(_ message: String) {
        text = message
        let host = NSHostingView(rootView: HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(message).font(.system(size: 13)).foregroundStyle(Yap.title).lineLimit(1).truncationMode(.middle)
        }.padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: 360).panelSurface(cornerRadius: 12).padding(6))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let p = panel ?? NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.level = .floating
        p.isReleasedWhenClosed = false; p.hidesOnDeactivate = false
        p.contentView = host
        p.setContentSize(host.fittingSize)
        if let s = NSScreen.main { p.setFrameOrigin(CGPoint(x: s.visibleFrame.midX - p.frame.width / 2, y: s.visibleFrame.maxY - p.frame.height - 40)) }
        p.orderFrontRegardless()
        panel = p
    }

    func hide() { text = nil; panel?.orderOut(nil) }
}
