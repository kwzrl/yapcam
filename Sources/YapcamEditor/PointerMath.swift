import CoreGraphics

/// Pure point → value mappings of the preview and inspector pads. They never produce NaN/inf (zero-size views, non-finite
/// pointer events) and clamp drags that leave the view, so the model never receives an out-of-range or invalid value.
enum PointerMath {
    /// 0…1 inside `size`; nil when the view has no area yet. A drag past the edge clamps to it.
    static func unit(_ p: CGPoint, in size: CGSize) -> CGPoint? {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite, p.x.isFinite, p.y.isFinite else { return nil }
        return CGPoint(x: min(max(p.x / size.width, 0), 1), y: min(max(p.y / size.height, 0), 1))
    }
    /// −1…1 (the inset-origin pad).
    static func pad(_ p: CGPoint, in size: CGSize) -> CGPoint? {
        unit(p, in: size).map { CGPoint(x: $0.x * 2 - 1, y: $0.y * 2 - 1) }
    }
    /// Pointer movement as a fraction of the view; zero for a zero-size view or non-finite input.
    static func delta(from a: CGPoint, to b: CGPoint, in size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else { return .zero }
        return CGSize(width: (b.x - a.x) / size.width, height: (b.y - a.y) / size.height)
    }
    /// Which part of a box a pointer-down grabs: a corner within `radius` (0 TL, 1 TR, 2 BL, 3 BR, nearest first), the body, or nothing.
    static func rectHit(at p: CGPoint, frame f: CGRect, radius: CGFloat = 14) -> RectEditOverlay.Mode? {
        guard p.x.isFinite, p.y.isFinite, f.width.isFinite, f.height.isFinite else { return nil }
        let corners = [CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.minY), CGPoint(x: f.minX, y: f.maxY), CGPoint(x: f.maxX, y: f.maxY)]
        let near = corners.enumerated().map { ($0.offset, hypot($0.element.x - p.x, $0.element.y - p.y)) }.filter { $0.1 <= radius }.min { $0.1 < $1.1 }
        if let near { return .corner(near.0) }
        return f.contains(p) ? .move : nil
    }
}
