import Foundation

/// Pure time↔pixel mapping for the timeline. `pixelsPerSecond` is the zoom level.
public struct TimelineGeometry: Equatable, Sendable {
    public var pixelsPerSecond: Double
    public var scrollOffsetPx: Double = 0
    public static let minPPS = 0.1
    public static let maxPPS = 2000.0

    public init(pixelsPerSecond: Double, scrollOffsetPx: Double = 0) {
        self.pixelsPerSecond = min(max(pixelsPerSecond, Self.minPPS), Self.maxPPS)
        self.scrollOffsetPx = scrollOffsetPx
    }

    public func x(forNs ns: Int64) -> Double { Double(ns) / 1e9 * pixelsPerSecond - scrollOffsetPx }
    public func ns(forX x: Double) -> Int64 {
        let v = ((x + scrollOffsetPx) / pixelsPerSecond) * 1e9
        guard v.isFinite else { return 0 }                                   // NaN/inf from a broken pointer event must not trap
        return Int64(min(max(v, -9e18), 9e18))
    }
    public func contentWidth(durationNs: Int64) -> Double { Double(durationNs) / 1e9 * pixelsPerSecond }

    /// Zoom around an anchor x (e.g. cursor or playhead) keeping the anchored time stationary.
    public func zoomed(by factor: Double, anchorX: Double) -> TimelineGeometry {
        let anchorNs = ns(forX: anchorX)
        var g = TimelineGeometry(pixelsPerSecond: pixelsPerSecond * factor)
        let target = Double(anchorNs) / 1e9 * g.pixelsPerSecond - anchorX
        g.scrollOffsetPx = max(0, target)
        return g
    }

    /// Fit the whole project into `width` px with a small margin.
    public static func fitting(durationNs: Int64, width: Double) -> TimelineGeometry {
        let secs = max(Double(durationNs) / 1e9, 0.1)
        return TimelineGeometry(pixelsPerSecond: max(width - 24, 40) / secs)
    }

    /// Ruler tick spacing: smallest "nice" interval whose labels are ≥ 70 px apart.
    public func rulerStepSeconds() -> Double {
        let nice: [Double] = [0.01, 0.02, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        return nice.first { $0 * pixelsPerSecond >= 70 } ?? 3600
    }
}

public func formatTimecode(_ ns: Int64, showFraction: Bool = true) -> String {
    let neg = ns < 0
    let total = abs(ns)
    let secs = Int(total / 1_000_000_000)
    let frac = Int((total % 1_000_000_000) / 10_000_000)   // centiseconds
    let h = secs / 3600, m = (secs % 3600) / 60, s = secs % 60
    var out = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    if showFraction { out += String(format: ".%02d", frac) }
    return neg ? "-" + out : out
}

/// The playhead is one physical pixel wide and sits exactly on the pixel grid, so it stays sharp at every zoom and
/// scale (a 1-pt line at a fractional x smears over two device pixels). Pure, for tests.
public enum PixelGrid {
    /// Width of one device pixel in points (0.5 on Retina). A missing or broken scale counts as 1.
    public static func pixel(scale: Double) -> Double { scale.isFinite && scale > 0 ? 1 / scale : 1 }
    /// Left edge (points) of the device pixel that contains `x`: the line covers [edge, edge + pixel).
    public static func lineEdge(_ x: Double, scale: Double) -> Double {
        let s = scale.isFinite && scale > 0 ? scale : 1
        guard x.isFinite else { return 0 }
        return (x * s + 1e-9).rounded(.down) / s
    }
}
