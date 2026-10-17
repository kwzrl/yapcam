import AppKit
import SwiftUI

/// Pinch, ⌘-scroll and mouse-wheel navigation of the timeline (MKT-129 / MKT-201). The decisions are pure so they can be tested;
/// `TimelineScrollHost` only feeds events in and applies the answers.
enum TimelineNavigation {
    enum Intent: Equatable {
        case zoom(factor: Double)
        case scrollX(delta: Double)          // positive = content moves left (view shows later time)
        case passthrough                     // trackpad two-axis scrolling stays native
    }

    /// `precise` = trackpad / Magic Mouse (pixel deltas); a classic wheel reports line steps.
    static func intent(deltaX: Double, deltaY: Double, precise: Bool, command: Bool) -> Intent {
        guard deltaX.isFinite, deltaY.isFinite else { return .passthrough }
        if command {
            let d = abs(deltaY) >= abs(deltaX) ? deltaY : deltaX
            guard d != 0 else { return .passthrough }
            return .zoom(factor: exp(min(max(d, -60), 60) * (precise ? 0.01 : 0.06)))
        }
        // A classic wheel only has a vertical axis: map it to horizontal scrolling. A trackpad has both axes natively.
        if !precise, deltaX == 0, deltaY != 0 { return .scrollX(delta: -deltaY * 14) }
        return .passthrough
    }

    /// Pinch: `magnification` is the incremental change reported by AppKit (0.1 = 10 % larger).
    static func pinchFactor(magnification: Double) -> Double {
        guard magnification.isFinite else { return 1 }
        return min(max(1 + magnification, 0.5), 2)
    }

    /// Horizontal scroll offset after the scale changed by `ratio` that keeps the time under `anchorX` (content coordinates)
    /// at the same place in the viewport.
    static func anchoredOffset(scrollX: Double, anchorX: Double, ratio: Double, newContentWidth: Double, viewportWidth: Double) -> Double {
        guard scrollX.isFinite, anchorX.isFinite, ratio.isFinite, ratio > 0 else { return max(scrollX.isFinite ? scrollX : 0, 0) }
        let x = anchorX * (ratio - 1) + scrollX
        return min(max(x, 0), max(newContentWidth - viewportWidth, 0))
    }
}

/// What the model needs from the timeline's scroll view.
@MainActor protocol TimelineScroller: AnyObject {
    var offsetX: Double { get }
    var viewportWidth: Double { get }
    func scroll(toX x: Double)
}

extension EditorModel {
    /// Zooms around `anchorX` (timeline content coordinates; default: the playhead) and keeps that time where it was on screen.
    public func zoomTimeline(by factor: Double, anchorContentX: Double? = nil) {
        let old = geometry.pixelsPerSecond
        setTimelineScale(by: factor)
        let ratio = geometry.pixelsPerSecond / old
        guard let scroller = timelineScroller, ratio != 1 else { return }
        let anchor = anchorContentX ?? geometry.x(forNs: playheadNs) / ratio
        let x = TimelineNavigation.anchoredOffset(scrollX: scroller.offsetX, anchorX: anchor, ratio: ratio,
                                                  newContentWidth: geometry.contentWidth(durationNs: durationNs) + 40, viewportWidth: scroller.viewportWidth)
        // The content grows on the next layout pass; scroll once it has.
        DispatchQueue.main.async { DispatchQueue.main.async { [weak scroller] in scroller?.scroll(toX: x) } }
    }
}

struct TimelineScrollHost: NSViewRepresentable {
    let model: EditorModel
    func makeNSView(context: Context) -> HostView { let v = HostView(); v.model = model; return v }
    func updateNSView(_ v: HostView, context: Context) { v.model = model }

    @MainActor final class HostView: NSView, TimelineScroller {
        weak var model: EditorModel?
        private var monitor: Any?
        private weak var scrollView: NSScrollView?
        var offsetX: Double { Double(scrollView?.contentView.bounds.origin.x ?? 0) }
        var viewportWidth: Double { Double(scrollView?.contentView.bounds.width ?? 0) }
        func scroll(toX x: Double) {
            guard let sv = scrollView else { return }
            sv.contentView.scroll(to: NSPoint(x: x, y: sv.contentView.bounds.origin.y)); sv.reflectScrolledClipView(sv.contentView)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { if model?.timelineScroller === self { model?.timelineScroller = nil }; return }
            scrollView = enclosingScrollView
            model?.timelineScroller = self
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel]) { [weak self] e in
                guard let self else { return e }
                nonisolated(unsafe) let ev = e
                let used = MainActor.assumeIsolated { self.handle(ev) }
                return used ? nil : e
            }
        }

        private func handle(_ e: NSEvent) -> Bool {
            guard let sv = scrollView, let model, e.window === window, sv.window != nil else { return false }
            let p = sv.contentView.convert(e.locationInWindow, from: nil)
            guard sv.contentView.bounds.contains(p) else { return false }           // only over the timeline
            let anchor = Double(p.x)                                                // content x: the clip view's origin is the scroll offset
            if e.type == .magnify {
                model.zoomTimeline(by: TimelineNavigation.pinchFactor(magnification: Double(e.magnification)), anchorContentX: anchor); return true
            }
            switch TimelineNavigation.intent(deltaX: Double(e.scrollingDeltaX), deltaY: Double(e.scrollingDeltaY),
                                             precise: e.hasPreciseScrollingDeltas, command: e.modifierFlags.contains(.command)) {
            case .zoom(let f): model.zoomTimeline(by: f, anchorContentX: anchor); return true
            case .scrollX(let d):
                let maxX = max(model.geometry.contentWidth(durationNs: model.durationNs) + 40 - viewportWidth, 0)
                scroll(toX: min(max(offsetX + d, 0), maxX)); return true
            case .passthrough: return false
            }
        }
    }
}
