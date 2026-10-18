import CoreGraphics
import Foundation

/// Aspect lock of the crop tool: "Any" or a fixed width/height ratio.
public enum CropAspectLock: String, CaseIterable, Identifiable, Sendable {
    case any, r16x9, r9x16, r1x1, r4x3, r3x4
    public var id: String { rawValue }
    public var label: String {
        switch self { case .any: "Any"; case .r16x9: "16:9"; case .r9x16: "9:16"; case .r1x1: "1:1"; case .r4x3: "4:3"; case .r3x4: "3:4" }
    }
    /// width / height, nil for Any.
    public var ratio: Double? {
        switch self { case .any: nil; case .r16x9: 16.0 / 9; case .r9x16: 9.0 / 16; case .r1x1: 1; case .r4x3: 4.0 / 3; case .r3x4: 3.0 / 4 }
    }
}

public enum CropHandle: CaseIterable, Sendable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, body }

/// The crop rectangle being edited, in source pixels. Staged locally by the crop tool and written once on Confirm.
/// Invariants: inside the frame, at least `minSide` on each side, whole pixels after `rounded()`.
public struct CropDraft: Equatable, Sendable {
    public static let minSide = 32.0
    public var frame: CGSize
    public var rect: CGRect
    public var lock: CropAspectLock = .any

    public init(frame: CGSize, rect: CGRect? = nil) {
        self.frame = CGSize(width: max(frame.width, 1), height: max(frame.height, 1))
        self.rect = rect ?? CGRect(origin: .zero, size: self.frame)
        self.rect = clamped(self.rect)
    }

    /// From `canvas.crop` ([x, y, w, h], normalized). Missing or invalid values give the whole frame.
    public init(frame: CGSize, stored: [Double]) {
        if stored.count == 4, stored[2] > 0, stored[3] > 0 {
            self.init(frame: frame, rect: CGRect(x: stored[0] * frame.width, y: stored[1] * frame.height,
                                                 width: stored[2] * frame.width, height: stored[3] * frame.height).rounded())
        } else { self.init(frame: frame) }
    }

    /// Normalized [x, y, w, h] for `canvas.crop`.
    public var stored: [Double] {
        [rect.minX / frame.width, rect.minY / frame.height, rect.width / frame.width, rect.height / frame.height]
    }
    /// Insets (left, top, right, bottom) as fractions of the frame, the unit `setCrop` takes.
    public var insets: (left: Double, top: Double, right: Double, bottom: Double) {
        (rect.minX / frame.width, rect.minY / frame.height, (frame.width - rect.maxX) / frame.width, (frame.height - rect.maxY) / frame.height)
    }
    public var isFullFrame: Bool { rect == CGRect(origin: .zero, size: frame) }

    private var minW: Double { min(frame.width, max(Self.minSide, lock.ratio.map { Self.minSide * $0 } ?? 0)) }
    private var minH: Double { min(frame.height, max(Self.minSide, lock.ratio.map { Self.minSide / $0 } ?? 0)) }

    private func clamped(_ r: CGRect) -> CGRect {
        let w = min(max(r.width, min(Self.minSide, frame.width)), frame.width)
        let h = min(max(r.height, min(Self.minSide, frame.height)), frame.height)
        return CGRect(x: min(max(r.minX, 0), frame.width - w), y: min(max(r.minY, 0), frame.height - h), width: w, height: h)
    }

    public func rounded() -> CropDraft {
        var d = self
        let x = rect.minX.rounded(), y = rect.minY.rounded()
        d.rect = d.clamped(CGRect(x: x, y: y, width: rect.maxX.rounded() - x, height: rect.maxY.rounded() - y))
        return d
    }

    // MARK: numeric fields

    public mutating func setWidth(_ w: Double) {
        let w = min(max(w, minW), frame.width)
        var h = rect.height
        if let r = lock.ratio { h = min(w / r, frame.height) }
        resize(width: r(lockAdjusted: (w, h)).0, height: r(lockAdjusted: (w, h)).1)
    }
    public mutating func setHeight(_ h: Double) {
        let h = min(max(h, minH), frame.height)
        var w = rect.width
        if let r = lock.ratio { w = min(h * r, frame.width) }
        resize(width: r(lockAdjusted: (w, h)).0, height: r(lockAdjusted: (w, h)).1)
    }
    /// Keeps the ratio when both limits bind (a tall ratio on a short frame, etc.).
    private func r(lockAdjusted size: (Double, Double)) -> (Double, Double) {
        guard let ratio = lock.ratio else { return size }
        var (w, h) = size
        if w / h > ratio + 1e-9 { w = h * ratio } else if w / h < ratio - 1e-9 { h = w / ratio }
        return (w, h)
    }
    private mutating func resize(width: Double, height: Double) {
        rect = clamped(CGRect(x: rect.minX, y: rect.minY, width: width, height: height))
    }
    public mutating func setX(_ x: Double) { rect = clamped(CGRect(x: x, y: rect.minY, width: rect.width, height: rect.height)) }
    public mutating func setY(_ y: Double) { rect = clamped(CGRect(x: rect.minX, y: y, width: rect.width, height: rect.height)) }

    /// Picking a ratio shrinks the rectangle to that ratio around its centre.
    public mutating func setLock(_ l: CropAspectLock) {
        lock = l
        guard let ratio = l.ratio else { return }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var w = rect.width, h = rect.height
        if w / h > ratio { w = h * ratio } else { h = w / ratio }
        rect = clamped(CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h))
    }

    public mutating func reset() { rect = CGRect(origin: .zero, size: frame) }

    // MARK: dragging

    /// The rectangle after dragging `handle` by (dx, dy) source pixels from `start`. The aspect lock adjusts the opposite edge.
    public func dragged(_ handle: CropHandle, from start: CGRect, dx: Double, dy: Double) -> CGRect {
        let W = frame.width, H = frame.height
        if handle == .body {
            return CGRect(x: min(max(start.minX + dx, 0), W - start.width), y: min(max(start.minY + dy, 0), H - start.height),
                          width: start.width, height: start.height)
        }
        var l = start.minX, t = start.minY, r = start.maxX, b = start.maxY
        let movesLeft = [.topLeft, .left, .bottomLeft].contains(handle), movesRight = [.topRight, .right, .bottomRight].contains(handle)
        let movesTop = [.topLeft, .top, .topRight].contains(handle), movesBottom = [.bottomLeft, .bottom, .bottomRight].contains(handle)
        guard let ratio = lock.ratio else {
            let mw = min(Self.minSide, W), mh = min(Self.minSide, H)
            if movesLeft { l = min(max(l + dx, 0), r - mw) }
            if movesRight { r = max(min(r + dx, W), l + mw) }
            if movesTop { t = min(max(t + dy, 0), b - mh) }
            if movesBottom { b = max(min(b + dy, H), t + mh) }
            return CGRect(x: l, y: t, width: r - l, height: b - t)
        }
        // Locked: the dragged axis drives; the other follows. Corners anchor the opposite corner, edges grow around the centre.
        let horizontalDrives = movesLeft || movesRight
        var w = start.width + (movesRight ? dx : movesLeft ? -dx : 0)
        var h = start.height + (movesBottom ? dy : movesTop ? -dy : 0)
        if horizontalDrives && (movesTop || movesBottom) {          // corner: take the larger relative change
            let sw = abs(w / start.width - 1), sh = abs(h / start.height - 1)
            if sh > sw { w = h * ratio } else { h = w / ratio }
        } else if horizontalDrives { h = w / ratio } else { w = h * ratio }
        // Largest size that fits from the anchor.
        let anchorX = movesLeft ? start.maxX : movesRight ? start.minX : start.midX
        let anchorY = movesTop ? start.maxY : movesBottom ? start.minY : start.midY
        let availW = movesLeft ? anchorX : movesRight ? W - anchorX : 2 * min(anchorX, W - anchorX)
        let availH = movesTop ? anchorY : movesBottom ? H - anchorY : 2 * min(anchorY, H - anchorY)
        let fit = min(1, availW / max(w, 1e-9), availH / max(h, 1e-9))
        w *= fit; h *= fit
        if w < minW || h < minH { let up = max(minW / w, minH / h); w *= up; h *= up }
        let x = movesLeft ? anchorX - w : movesRight ? anchorX : anchorX - w / 2
        let y = movesTop ? anchorY - h : movesBottom ? anchorY : anchorY - h / 2
        return clamped(CGRect(x: x, y: y, width: w, height: h))
    }
}

extension CGRect {
    func rounded() -> CGRect {
        let x = minX.rounded(), y = minY.rounded()
        return CGRect(x: x, y: y, width: maxX.rounded() - x, height: maxY.rounded() - y)
    }
}
