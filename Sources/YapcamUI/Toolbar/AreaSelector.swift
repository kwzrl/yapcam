import AppKit
import SwiftUI

/// Full-screen overlay for choosing a capture rectangle on one display.
/// Result is display-local points with a top-left origin (SCStream `sourceRect` convention).
@MainActor final class AreaSelector {
    static let shared = AreaSelector()
    private var window: AreaOverlayWindow?
    private var done: ((CGRect?) -> Void)?

    var isActive: Bool { window != nil }
    func cancelForTesting() { end(nil) }
    var debugContentView: NSView? { window?.contentView }

    func begin(on screen: NSScreen, initial: CGRect?, completion: @escaping (CGRect?) -> Void) {
        end(nil)
        done = completion
        let w = AreaOverlayWindow(screen: screen)
        let view = AreaOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.rect = initial.map { $0.intersection(view.bounds) }.flatMap { $0.isEmpty ? nil : $0 }
        view.onFinish = { [weak self] r in self?.end(r) }
        w.contentView = view
        RecordingController.shared.engine.registerExcluded(w)
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(view)
    }

    private func end(_ rect: CGRect?) {
        guard let w = window else { return }
        RecordingController.shared.engine.unregisterExcluded(w)
        w.orderOut(nil)
        window = nil
        let cb = done; done = nil
        cb?(rect)
    }
}

private final class AreaOverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        setFrame(screen.frame, display: false)
    }
    override var canBecomeKey: Bool { true }
}

private struct AspectPreset: Equatable {
    let name: String
    let ratio: CGFloat?   // width / height; nil = free
    static let all: [AspectPreset] = [
        .init(name: "Free", ratio: nil), .init(name: "16:9", ratio: 16.0 / 9), .init(name: "4:3", ratio: 4.0 / 3),
        .init(name: "1:1", ratio: 1), .init(name: "9:16", ratio: 9.0 / 16),
    ]
}

private final class AreaOverlayView: NSView {
    var rect: CGRect? { didSet { needsDisplay = true; updateBar() } }
    var onFinish: ((CGRect?) -> Void)?
    private var preset = AspectPreset.all[0] { didSet { applyPreset(); updateBar() } }

    private enum Drag { case none, create(CGPoint), move(CGPoint, CGRect), resize(Handle, CGRect) }
    private enum Handle: CaseIterable { case tl, t, tr, r, br, b, bl, l }
    private var drag = Drag.none
    private var bar: NSHostingView<AreaBar>?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()
        guard let r = rect else {
            drawHint("Drag to select the area to record", at: CGPoint(x: bounds.midX, y: bounds.midY))
            return
        }
        NSGraphicsContext.current?.compositingOperation = .clear
        r.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5)); path.lineWidth = 1.5; path.stroke()
        for h in Handle.allCases {
            let p = point(of: h, in: r)
            let hr = CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
            NSColor.white.setFill(); NSBezierPath(roundedRect: hr, xRadius: 2, yRadius: 2).fill()
            NSColor.black.withAlphaComponent(0.4).setStroke(); NSBezierPath(roundedRect: hr, xRadius: 2, yRadius: 2).stroke()
        }
        let label = "\(Int(r.width.rounded())) × \(Int(r.height.rounded()))"
        let y = r.minY > 34 ? r.minY - 28 : r.minY + 8
        drawHint(label, at: CGPoint(x: r.midX, y: y + 11))
    }

    private func drawHint(_ text: String, at c: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        let box = CGRect(x: c.x - size.width / 2 - 8, y: c.y - size.height / 2 - 3, width: size.width + 16, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        s.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 3))
    }

    private func point(of h: Handle, in r: CGRect) -> CGPoint {
        switch h {
        case .tl: CGPoint(x: r.minX, y: r.minY); case .t: CGPoint(x: r.midX, y: r.minY)
        case .tr: CGPoint(x: r.maxX, y: r.minY); case .r: CGPoint(x: r.maxX, y: r.midY)
        case .br: CGPoint(x: r.maxX, y: r.maxY); case .b: CGPoint(x: r.midX, y: r.maxY)
        case .bl: CGPoint(x: r.minX, y: r.maxY); case .l: CGPoint(x: r.minX, y: r.midY)
        }
    }

    private func hitHandle(_ p: CGPoint) -> Handle? {
        guard let r = rect else { return nil }
        return Handle.allCases.first { hypot(point(of: $0, in: r).x - p.x, point(of: $0, in: r).y - p.y) <= 9 }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let h = hitHandle(p), let r = rect { drag = .resize(h, r) }
        else if let r = rect, r.contains(p) { drag = .move(p, r) }
        else { drag = .create(p); rect = nil }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none: break
        case .create(let o): rect = constrained(from: o, to: p)
        case .move(let o, let r0):
            var r = r0.offsetBy(dx: p.x - o.x, dy: p.y - o.y)
            r.origin.x = min(max(0, r.origin.x), bounds.width - r.width)
            r.origin.y = min(max(0, r.origin.y), bounds.height - r.height)
            rect = r
        case .resize(let h, let r0): rect = resized(r0, handle: h, to: p)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let r = rect, r.width < 16 || r.height < 16 { rect = nil }
        drag = .none
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), bounds.width), y: min(max(0, p.y), bounds.height))
    }

    private func constrained(from o: CGPoint, to raw: CGPoint) -> CGRect {
        let p = clamp(raw)
        var w = p.x - o.x, h = p.y - o.y
        if let ratio = preset.ratio {
            let aw = abs(w), ah = abs(h)
            if aw / ratio > ah { h = (h < 0 ? -1 : 1) * aw / ratio } else { w = (w < 0 ? -1 : 1) * ah * ratio }
            // Keep inside the display.
            let maxW = w < 0 ? o.x : bounds.width - o.x, maxH = h < 0 ? o.y : bounds.height - o.y
            let k = min(1, maxW / max(abs(w), 1), maxH / max(abs(h), 1))
            w *= k; h *= k
        }
        return CGRect(x: min(o.x, o.x + w), y: min(o.y, o.y + h), width: abs(w), height: abs(h))
    }

    private func resized(_ r0: CGRect, handle h: Handle, to raw: CGPoint) -> CGRect {
        let p = clamp(raw)
        // Anchor = the opposite corner/edge; rebuild the rect from anchor and pointer.
        let anchor: CGPoint
        switch h {
        case .tl: anchor = CGPoint(x: r0.maxX, y: r0.maxY); case .tr: anchor = CGPoint(x: r0.minX, y: r0.maxY)
        case .br: anchor = CGPoint(x: r0.minX, y: r0.minY); case .bl: anchor = CGPoint(x: r0.maxX, y: r0.minY)
        case .t: anchor = CGPoint(x: r0.midX, y: r0.maxY); case .b: anchor = CGPoint(x: r0.midX, y: r0.minY)
        case .l: anchor = CGPoint(x: r0.maxX, y: r0.midY); case .r: anchor = CGPoint(x: r0.minX, y: r0.midY)
        }
        var r: CGRect
        switch h {
        case .t, .b: r = CGRect(x: r0.minX, y: min(anchor.y, p.y), width: r0.width, height: abs(p.y - anchor.y))
        case .l, .r: r = CGRect(x: min(anchor.x, p.x), y: r0.minY, width: abs(p.x - anchor.x), height: r0.height)
        default: r = CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y), width: abs(p.x - anchor.x), height: abs(p.y - anchor.y))
        }
        if let ratio = preset.ratio {
            switch h {
            case .t, .b:
                let w = r.height * ratio
                r = CGRect(x: r0.midX - w / 2, y: r.minY, width: w, height: r.height)
            case .l, .r:
                let hh = r.width / ratio
                r = CGRect(x: r.minX, y: r0.midY - hh / 2, width: r.width, height: hh)
            default:
                let aw = r.width, ah = r.height
                if aw / ratio > ah { r.size.height = aw / ratio } else { r.size.width = ah * ratio }
                if p.x < anchor.x { r.origin.x = anchor.x - r.width }
                if p.y < anchor.y { r.origin.y = anchor.y - r.height }
            }
            r = r.intersection(bounds)
        }
        return r
    }

    private func applyPreset() {
        guard let ratio = preset.ratio, let r = rect else { return }
        var w = r.width, h = w / ratio
        if h > bounds.height { h = bounds.height; w = h * ratio }
        if w > bounds.width { w = bounds.width; h = w / ratio }
        var n = CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
        n.origin.x = min(max(0, n.origin.x), bounds.width - w)
        n.origin.y = min(max(0, n.origin.y), bounds.height - h)
        rect = n
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onFinish?(nil)                                  // esc
        case 36, 76: if let r = rect { onFinish?(r.integral) }   // return / enter
        case 123, 124, 125, 126: nudge(event)                    // arrows: move; ⇧ resizes; ⌥ moves by 10
        default: super.keyDown(with: event)
        }
    }

    /// Keyboard control for people who can't drag: arrows move the area, ⇧+arrows resize it.
    private func nudge(_ event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.option) ? 10 : 1
        let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
        let dy: CGFloat = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
        var r = rect ?? CGRect(x: bounds.midX - 200, y: bounds.midY - 120, width: 400, height: 240)
        if event.modifierFlags.contains(.shift) { r.size.width += dx; r.size.height += dy }
        else { r.origin.x += dx; r.origin.y += dy }
        r.size.width = max(AreaGeometry.minSide, r.size.width); r.size.height = max(AreaGeometry.minSide, r.size.height)
        r.origin.x = min(max(0, r.origin.x), bounds.width - r.width)
        r.origin.y = min(max(0, r.origin.y), bounds.height - r.height)
        rect = r
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Recording area selector" }
    override func accessibilityChildren() -> [Any]? { bar.map { [$0] } }
    override func accessibilityValue() -> Any? {
        guard let r = rect else { return "No area selected. Press an arrow key to start one, or drag with the pointer." }
        return "\(Int(r.width)) by \(Int(r.height)) points at \(Int(r.minX)), \(Int(r.minY))"
    }
    override func accessibilityHelp() -> String? {
        "Arrow keys move the area, Shift plus arrow resizes it, Option moves by ten points, Return confirms, Escape cancels."
    }

    // MARK: Bottom bar

    private func updateBar() {
        let view = AreaBar(
            preset: preset.name, hasRect: rect != nil,
            choose: { [weak self] name in self?.preset = AspectPreset.all.first { $0.name == name } ?? AspectPreset.all[0] },
            confirm: { [weak self] in if let r = self?.rect { self?.onFinish?(r.integral) } },
            cancel: { [weak self] in self?.onFinish?(nil) })
        if let bar { bar.rootView = view }
        else {
            let b = NSHostingView(rootView: view)
            addSubview(b); bar = b
        }
        guard let bar else { return }
        let size = bar.fittingSize
        bar.frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 60, width: size.width, height: size.height)
    }

    override func viewDidMoveToWindow() { updateBar() }
}

private struct AreaBar: View {
    let preset: String
    let hasRect: Bool
    let choose: (String) -> Void
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker("Aspect", selection: Binding(get: { preset }, set: choose)) {
                ForEach(AspectPreset.all, id: \.name) { Text($0.name).tag($0.name) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 260).accessibilityLabel("Aspect ratio")
            Divider().frame(height: 18)
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            Button("Use Area", action: confirm).keyboardShortcut(.defaultAction).disabled(!hasRect)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .panelSurface(cornerRadius: 12)
        .padding(4)
    }
}
