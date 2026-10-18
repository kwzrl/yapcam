import Foundation

/// Text of timeline chips, separate from the views so it can be tested (BS-7, BS-8).
enum TimelineChipText {
    static func zoomTitle(_ z: TimelineZoom) -> String {
        String(format: "%.1fx · ", z.scale).replacingOccurrences(of: ".0x", with: "x") + (z.mode == .auto ? "Auto" : "Manual") + (z.enabled ? "" : " · Off")
    }
    static func zoomAccessibility(_ z: TimelineZoom, start: String, end: String) -> String {
        String(format: "Zoom %.1f×", z.scale) + (z.mode == .auto ? ", automatic" : "") + (z.enabled ? "" : ", disabled") + ", \(start) to \(end)"
    }
    static func clipAccessibility(_ c: TimelineClip, number: Int, start: String, end: String) -> String {
        "Clip \(number)" + (c.speed == 1 ? "" : String(format: ", %.2g× speed", c.speed))
            + (c.hideCursor ? ", cursor hidden" : "") + (c.disableSmoothing ? ", smooth cursor movement off" : "") + ", \(start) to \(end)"
    }
}
