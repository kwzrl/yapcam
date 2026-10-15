import CoreGraphics

/// A display as the geometry code sees it: AppKit global coordinates (bottom-left origin).
struct ScreenInfo: Equatable {
    var id: UInt32
    var frame: CGRect
    var visibleFrame: CGRect
    var scale: CGFloat = 1
}

/// Pure placement rules for the floating toolbar, so multi-display behavior is testable
/// without real displays.
enum ToolbarGeometry {
    static let edgeInset: CGFloat = 4
    static let defaultInset: CGFloat = 24

    /// Position as fractions of the display frame for the toolbar's top-left corner.
    struct Fraction: Equatable { var x: Double; var y: Double }

    static func fraction(frame: CGRect, on screen: ScreenInfo) -> Fraction {
        Fraction(x: (frame.minX - screen.frame.minX) / screen.frame.width,
                 y: (frame.maxY - screen.frame.minY) / screen.frame.height)
    }

    /// Screen holding the center of `frame`; nil when it is on no display.
    static func screen(containing frame: CGRect, in screens: [ScreenInfo]) -> ScreenInfo? {
        let c = CGPoint(x: frame.midX, y: frame.midY)
        return screens.first { $0.frame.contains(c) }
    }

    /// Display to use when the toolbar has no valid current one: last used display if still
    /// connected, otherwise the main display, otherwise the first.
    static func fallbackScreen(lastID: UInt32?, mainID: UInt32?, in screens: [ScreenInfo]) -> ScreenInfo? {
        if let lastID, let s = screens.first(where: { $0.id == lastID }) { return s }
        if let mainID, let s = screens.first(where: { $0.id == mainID }) { return s }
        return screens.first
    }

    /// Where a toolbar of `size` goes on `screen`: the saved spot, else right edge, vertically centered.
    static func origin(size: CGSize, on screen: ScreenInfo, saved: Fraction?) -> CGPoint {
        let raw: CGPoint
        if let saved {
            raw = CGPoint(x: screen.frame.minX + saved.x * screen.frame.width,
                          y: screen.frame.minY + saved.y * screen.frame.height - size.height)
        } else {
            raw = CGPoint(x: screen.visibleFrame.maxX - size.width - defaultInset, y: screen.visibleFrame.midY - size.height / 2)
        }
        return clamp(CGRect(origin: raw, size: size), to: screen.visibleFrame).origin
    }

    /// Keeps the whole toolbar inside the visible area (menu bar and Dock excluded).
    static func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
        var f = frame
        f.origin.x = max(visible.minX + edgeInset, min(f.origin.x, visible.maxX - f.width - edgeInset))
        f.origin.y = max(visible.minY + edgeInset, min(f.origin.y, visible.maxY - f.height - edgeInset))
        // A display smaller than the toolbar: pin to the top-left rather than straddle.
        if visible.width < f.width + 2 * edgeInset { f.origin.x = visible.minX }
        if visible.height < f.height + 2 * edgeInset { f.origin.y = visible.maxY - f.height }
        return f
    }

    /// Display configuration changed: stay put if still on a display (just clamp), else move to the fallback.
    static func relocate(frame: CGRect, screens: [ScreenInfo], lastID: UInt32?, mainID: UInt32?,
                         saved: (UInt32) -> Fraction?) -> CGRect? {
        if let s = screen(containing: frame, in: screens) { return clamp(frame, to: s.visibleFrame) }
        guard let fb = fallbackScreen(lastID: lastID, mainID: mainID, in: screens) else { return nil }
        return CGRect(origin: origin(size: frame.size, on: fb, saved: saved(fb.id)), size: frame.size)
    }

    /// Popovers open toward the display's center: right of the toolbar when it sits on the left half.
    static func onLeftHalf(frame: CGRect, of screen: ScreenInfo) -> Bool { frame.midX < screen.frame.midX }
}

/// Coordinate rules for the area overlay. Saved areas are display-local points with a top-left
/// origin (SCStream `sourceRect` convention); AppKit windows use global bottom-left coordinates.
enum AreaGeometry {
    static let minSide: CGFloat = 16

    /// Saved area → AppKit global rect on the display with frame `screenFrame`.
    static func globalRect(fromLocal r: CGRect, screenFrame f: CGRect) -> CGRect {
        CGRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// Inverse of `globalRect`.
    static func localRect(fromGlobal r: CGRect, screenFrame f: CGRect) -> CGRect {
        CGRect(x: r.minX - f.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// Output pixel size of an area on a display with `scale` (1× or 2×).
    static func pixelSize(of r: CGRect, scale: CGFloat) -> CGSize {
        CGSize(width: (r.width * scale).rounded(), height: (r.height * scale).rounded())
    }

    /// A saved area made valid for a display of `size` points (resolution or display changed):
    /// clipped to the display, nil when too little is left to record.
    static func fit(_ r: CGRect, in size: CGSize) -> CGRect? {
        let clipped = r.intersection(CGRect(origin: .zero, size: size))
        guard !clipped.isNull, clipped.width >= minSide, clipped.height >= minSide else { return nil }
        return clipped
    }
}
