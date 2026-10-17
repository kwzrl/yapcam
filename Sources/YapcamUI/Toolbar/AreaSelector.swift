import AppKit
import SwiftUI

/// Full-screen overlay for choosing a capture rectangle on one display.
/// Result is display-local points with a top-left origin (SCStream `sourceRect` convention).
@MainActor final class AreaSelector {
    static let shared = AreaSelector()
    private var window: AreaOverlayWindow?
    private var done: ((CGRect?) -> Void)?
    private var keyMonitor: Any?
    private var screenObserver: Any?

    var isActive: Bool { window != nil }
    func cancelForTesting() { end(nil) }
    /// Start with the current rectangle (Return, or the Start/Stop shortcut while the overlay is up).
    func commit() { (window?.contentView as? AreaOverlayView)?.confirm() }
    /// Presses Start recording exactly as Return does (self-tests).
    func confirmForTesting() { (window?.contentView as? AreaOverlayView)?.confirm() }
    var debugContentView: NSView? { window?.contentView }

    func begin(on screen: NSScreen, initial: CGRect?, completion: @escaping (CGRect?) -> Void) {
        end(nil, restoreFocus: false)
        done = completion
        let w = AreaOverlayWindow(screen: screen)
        let view = AreaOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.rect = initial.map { $0.intersection(view.bounds) }.flatMap { $0.isEmpty ? nil : $0 }
        view.onFinish = { [weak self] r in self?.end(r) }
        w.contentView = view
        RecordingController.shared.engine.registerExcluded(w)
        window = w
        OverlayKeys.takeKeyboard(w)
        w.makeFirstResponder(view)
        // Return starts (unless a number field is being edited), Esc cancels: whatever has focus.
        keyMonitor = OverlayKeys.install(window: w, start: { [weak view] in view?.confirm() }, cancel: { [weak view] in view?.onFinish?(nil) },
                                         mode: { SourcePicker.open($0) })
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end(nil) }
        }
    }

    func end(_ rect: CGRect?, restoreFocus: Bool = true) {
        OverlayKeys.remove(keyMonitor); keyMonitor = nil
        if let o = screenObserver { NotificationCenter.default.removeObserver(o); screenObserver = nil }
        guard let w = window else { return }
        if restoreFocus { OverlayFocus.restore() }
        RecordingController.shared.engine.unregisterExcluded(w)
        w.orderOut(nil)
        window = nil
        let cb = done; done = nil
        if PickerState.shared.openMode == .area { PickerState.shared.openMode = nil }
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

/// Custom aspect ratio for the area (GAP-UI-6): W:H as typed, any positive pair up to 20:1.
enum AreaAspect {
    static let maxRatio: CGFloat = 20
    static let customName = "Custom"
    static func ratio(width: CGFloat, height: CGFloat) -> CGFloat? {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let r = width / height
        return r <= maxRatio && r >= 1 / maxRatio ? r : nil
    }
    /// The largest rect with `ratio` that fits `bounds`, centred on `rect` and kept inside `bounds`.
    static func fit(_ rect: CGRect, ratio: CGFloat, in bounds: CGSize) -> CGRect {
        var w = rect.width, h = w / ratio
        if h > bounds.height { h = bounds.height; w = h * ratio }
        if w > bounds.width { w = bounds.width; h = w / ratio }
        var n = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        n.origin.x = min(max(0, n.origin.x), bounds.width - w)
        n.origin.y = min(max(0, n.origin.y), bounds.height - h)
        return n
    }
}

private struct AspectPreset: Equatable {
    static func custom(_ w: CGFloat, _ h: CGFloat) -> AspectPreset { .init(name: AreaAspect.customName, ratio: AreaAspect.ratio(width: w, height: h)) }
    static let names = all.map(\.name) + [AreaAspect.customName]
    let name: String
    let ratio: CGFloat?   // width / height; nil = free
    static let all: [AspectPreset] = [
        .init(name: "Any", ratio: nil), .init(name: "16:9", ratio: 16.0 / 9), .init(name: "4:3", ratio: 4.0 / 3),
        .init(name: "1:1", ratio: 1), .init(name: "3:4", ratio: 3.0 / 4), .init(name: "9:16", ratio: 9.0 / 16),
    ]
}

private final class AreaOverlayView: NSView {
    var rect: CGRect? { didSet { needsDisplay = true; updateBar() } }
    var onFinish: ((CGRect?) -> Void)?
    private var preset = AspectPreset.all[0] { didSet { applyPreset(); updateBar() } }
    private var customW = AppSettings.shared.areaCustomRatioW
    private var customH = AppSettings.shared.areaCustomRatioH

    private enum Drag { case none, create(CGPoint), move(CGPoint, CGRect), resize(AreaHandle, CGRect) }
    private var drag = Drag.none
    private var bar: NSHostingView<AreaBar>?

    func confirm() { if let r = rect, AreaGeometry.canRecord(r) { onFinish?(r.integral) } }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()
        guard let r = rect else {
            drawHint("Drag area you want to record", at: CGPoint(x: bounds.midX, y: bounds.midY))
            return
        }
        NSGraphicsContext.current?.compositingOperation = .clear
        r.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5)); path.lineWidth = 1.5; path.stroke()
        for h in AreaHandle.allCases {
            let p = h.point(in: r)
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


    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch AreaMouseDown.decide(at: p, rect: rect) {
        case .resize(let h): if let r = rect { drag = .resize(h, r) }
        case .move: if let r = rect { drag = .move(p, r) }
        case .create: drag = .create(p); rect = nil
        }
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

    private func resized(_ r0: CGRect, handle h: AreaHandle, to raw: CGPoint) -> CGRect {
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
        rect = AreaAspect.fit(r, ratio: ratio, in: bounds.size)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onFinish?(nil)                                  // esc
        case 36, 76: confirm()                                    // return / enter
        case 123, 124, 125, 126: nudge(event)                    // arrows move, ⌘ resizes, ⇧ = 10
        default: super.keyDown(with: event)
        }
    }

    /// Keyboard control (reference): arrows move the area, ⌘+arrows resize it; ⇧ makes the step 10.
    private func nudge(_ event: NSEvent) {
        let arrow: AreaGeometry.Arrow = event.keyCode == 123 ? .left : event.keyCode == 124 ? .right : event.keyCode == 126 ? .up : .down
        let r = rect ?? CGRect(x: bounds.midX - 200, y: bounds.midY - 120, width: 400, height: 240)
        rect = AreaGeometry.nudged(r, arrow, shift: event.modifierFlags.contains(.shift), command: event.modifierFlags.contains(.command), in: bounds.size)
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
        "Arrow keys move the area, Command plus arrow resizes it, Shift makes the step ten points, Return confirms, Escape cancels."
    }

    // MARK: Bottom bar

    private func updateBar() {
        let view = AreaBar(
            preset: preset.name, rect: rect, bounds: bounds.size,
            setRect: { [weak self] r in self?.setNumeric(r) },
            choose: { [weak self] name in
                guard let self else { return }
                self.preset = name == AreaAspect.customName ? .custom(self.customW, self.customH) : (AspectPreset.all.first { $0.name == name } ?? AspectPreset.all[0])
            },
            customRatio: (customW, customH),
            setCustomRatio: { [weak self] w, h in
                guard let self else { return }
                self.customW = w; self.customH = h
                AppSettings.shared.areaCustomRatioW = w; AppSettings.shared.areaCustomRatioH = h
                if self.preset.name == AreaAspect.customName { self.preset = .custom(w, h) }
            },
            confirm: { [weak self] in if let r = self?.rect { self?.onFinish?(r.integral) } },
            cancel: { [weak self] in self?.onFinish?(nil) })
        if let bar { bar.rootView = view }
        else {
            let b = NSHostingView(rootView: view)
            addSubview(b); bar = b
        }
        guard let bar else { return }
        let size = bar.fittingSize
        bar.frame = AreaOverlayBarLayout.frame(size: size, selection: rect, in: bounds)
    }

    override func viewDidMoveToWindow() { updateBar() }

    /// Numeric entry: clamp into the display, keep at least the drag minimum.
    private func setNumeric(_ r: CGRect) {
        var n = r
        n.size.width = min(max(AreaGeometry.minSide, n.width), bounds.width)
        n.size.height = min(max(AreaGeometry.minSide, n.height), bounds.height)
        n.origin.x = min(max(0, n.origin.x), bounds.width - n.width)
        n.origin.y = min(max(0, n.origin.y), bounds.height - n.height)
        rect = n
    }

}

private struct AreaBar: View {
    let preset: String
    let rect: CGRect?
    let bounds: CGSize
    let setRect: (CGRect) -> Void
    let choose: (String) -> Void
    let customRatio: (CGFloat, CGFloat)
    let setCustomRatio: (CGFloat, CGFloat) -> Void
    let confirm: () -> Void
    let cancel: () -> Void

    private var valid: Bool { AreaGeometry.canRecord(rect) }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Picker("Aspect", selection: Binding(get: { preset }, set: choose)) {
                    ForEach(AspectPreset.names, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 360).accessibilityLabel("Aspect ratio")
                if preset == AreaAspect.customName {
                    NumberField(label: "Ratio", value: customRatio.0) { v in setCustomRatio(v, customRatio.1) }
                    Text(":").foregroundStyle(.secondary)
                    NumberField(label: "to", value: customRatio.1) { v in setCustomRatio(customRatio.0, v) }
                }
                Divider().frame(height: 18)
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(action: confirm) {
                    Text(AppSettings.shared.afterRecording.recordLabel).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(valid ? Color.red : Color.gray))
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction).disabled(!valid)
                .accessibilityLabel("Start recording")
            }
            HStack(spacing: 8) {
                NumberField(label: "X", value: rect?.minX) { v in update { $0.origin.x = v } }
                NumberField(label: "Y", value: rect?.minY) { v in update { $0.origin.y = v } }
                NumberField(label: "W", value: rect?.width) { v in update { $0.size.width = v } }
                NumberField(label: "H", value: rect?.height) { v in update { $0.size.height = v } }
                savedSizesMenu
                Spacer(minLength: 0)
                if rect != nil && !valid {
                    Label(AreaGeometry.minimalSizeMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .disabled(rect == nil)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .panelSurface(cornerRadius: 12)
        .padding(4)
    }

    /// "Save current dimensions" / saved sizes / "Delete saved dimensions" (the reference's area presets).
    private var savedSizesMenu: some View {
        let saved = AppSettings.shared.savedAreaSizes
        return Menu {
            Button("Save current dimensions") { if let r = rect { AppSettings.shared.savedAreaSizes = AreaGeometry.saving(r.size, into: saved) } }
                .disabled(rect == nil)
            Divider()
            if saved.isEmpty { Text("No saved dimensions") }
            ForEach(saved, id: \.self) { t in
                Button(t.replacingOccurrences(of: "x", with: " × ")) {
                    if let size = WindowAX.parseSize(t) ?? Self.parseSmall(t) { update { $0.size = size } }
                }
            }
            if !saved.isEmpty { Divider(); Button("Delete saved dimensions") { AppSettings.shared.savedAreaSizes = [] } }
        } label: { Label("Saved sizes", systemImage: "bookmark") }
        .menuStyle(.button).fixedSize().accessibilityLabel("Saved dimensions")
    }

    private static func parseSmall(_ t: String) -> CGSize? {
        let p = t.split(separator: "x").compactMap { Double($0) }
        return p.count == 2 ? CGSize(width: p[0], height: p[1]) : nil
    }

    private func update(_ change: (inout CGRect) -> Void) {
        guard var r = rect else { return }
        change(&r); setRect(r)
    }
}

private struct NumberField: View {
    let label: String
    let value: CGFloat?
    let commit: (CGFloat) -> Void
    @State private var text = ""
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField("", text: $text, onCommit: { if let v = Double(text) { commit(CGFloat(v)) } else { sync() } })
                .textFieldStyle(.roundedBorder).frame(width: 58).font(.system(size: 12).monospacedDigit())
                .accessibilityLabel(label == "W" ? "Width" : label == "H" ? "Height" : label == "X" ? "Left" : label == "Y" ? "Top" : label == "Ratio" ? "Ratio width" : "Ratio height")
        }
        .onAppear { sync() }
        .onChange(of: value) { _, _ in sync() }
    }
    private func sync() { text = value.map { String(Int($0.rounded())) } ?? "" }
}

/// Where the Start-recording card goes relative to the selection (view coordinates, top-left origin).
enum AreaOverlayBarLayout {
    static func frame(size: CGSize, selection: CGRect?, in bounds: CGRect) -> CGRect {
        let gap: CGFloat = 14
        guard let r = selection else {
            return CGRect(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 60, width: size.width, height: size.height)
        }
        var y = r.maxY + gap                                      // larger y is lower on screen
        if y + size.height > bounds.maxY - 8 { y = r.minY - gap - size.height }
        if y < 8 { y = min(bounds.maxY - size.height - 8, r.maxY - size.height - gap) }   // no room either side: inside, at the bottom
        let x = min(max(8, r.midX - size.width / 2), bounds.maxX - size.width - 8)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

enum AreaHandle: CaseIterable {
    case tl, t, tr, r, br, b, bl, l
    func point(in r: CGRect) -> CGPoint {
        switch self {
        case .tl: CGPoint(x: r.minX, y: r.minY); case .t: CGPoint(x: r.midX, y: r.minY)
        case .tr: CGPoint(x: r.maxX, y: r.minY); case .r: CGPoint(x: r.maxX, y: r.midY)
        case .br: CGPoint(x: r.maxX, y: r.maxY); case .b: CGPoint(x: r.midX, y: r.maxY)
        case .bl: CGPoint(x: r.minX, y: r.maxY); case .l: CGPoint(x: r.minX, y: r.midY)
        }
    }
}

/// What a mouse-down in the area overlay starts: a handle hit wins over the body, the body moves, anywhere else draws a new area.
enum AreaMouseDown: Equatable {
    case resize(AreaHandle), move, create
    static let handleRadius: CGFloat = 9
    static func decide(at p: CGPoint, rect: CGRect?) -> AreaMouseDown {
        guard let r = rect else { return .create }
        if let h = AreaHandle.allCases.first(where: { hypot($0.point(in: r).x - p.x, $0.point(in: r).y - p.y) <= handleRadius }) { return .resize(h) }
        return r.contains(p) ? .move : .create
    }
}
