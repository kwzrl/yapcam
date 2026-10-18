import YapcamDesign
import SwiftUI

/// Scissors bubbles on the ruler (S-EDT-24): one per place where recorded material was trimmed or cut away, labelled with the
/// removed duration. Clicking one puts that material back (one undo step).
struct CutMarker: Equatable, Identifiable {
    var atNs: Int64                           // timeline boundary where the cut sits
    var removedNs: Int64                      // source time removed there
    var gaps: [(startNs: Int64, endNs: Int64, atNs: Int64)]
    var id: Int64 { atNs }
    static func == (a: CutMarker, b: CutMarker) -> Bool { a.atNs == b.atNs && a.removedNs == b.removedNs }

    /// Gaps that belong at the same boundary form one marker.
    static func markers(from gaps: [(startNs: Int64, endNs: Int64, atNs: Int64)]) -> [CutMarker] {
        var byBoundary: [Int64: [(startNs: Int64, endNs: Int64, atNs: Int64)]] = [:]
        for g in gaps where g.endNs > g.startNs { byBoundary[g.atNs, default: []].append(g) }
        return byBoundary.keys.sorted().map { at in
            let gs = byBoundary[at]!
            return CutMarker(atNs: at, removedNs: gs.reduce(0) { $0 + ($1.endNs - $1.startNs) }, gaps: gs)
        }
    }

    /// "450 ms", "2s", "1.5s", "1m 05s".
    static func label(_ ns: Int64) -> String {
        if ns < 1_000_000_000 { return "\(max(Int((Double(ns) / 1e6).rounded()), 1)) ms" }
        let s = Double(ns) / 1e9
        if s >= 60 { return "\(Int(s) / 60)m " + String(format: "%02ds", Int(s) % 60) }
        return s == s.rounded() ? "\(Int(s))s" : String(format: "%.1fs", s)
    }

    /// Bubble size in points: a scissors glyph plus the label (kept in one place so drawing and hit testing agree).
    static func width(_ label: String) -> CGFloat { 20 + CGFloat(label.count) * 5.2 }
    static let height: CGFloat = 12
    static let top: CGFloat = 11

    /// Whether the point (timeline content coordinates) is on the bubble of a marker drawn at `x` (centre).
    static func hits(_ p: CGPoint, bubbleCenterX x: Double, label: String) -> Bool {
        let w = width(label)
        return p.x >= x - w / 2 && p.x <= x + w / 2 && p.y >= top && p.y <= top + height
    }
}

struct CutMarkerBubble: View {
    let marker: CutMarker
    var body: some View {
        let label = CutMarker.label(marker.removedNs)
        HStack(spacing: 3) {
            Image(systemName: "scissors").font(.system(size: 7, weight: .semibold)).foregroundStyle(Color.white.opacity(0.8))
            Text(label).font(.system(size: 8, weight: .medium).monospacedDigit()).foregroundStyle(Yap.technical)
        }
        .frame(width: CutMarker.width(label), height: CutMarker.height)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cut, \(label) removed")
        .accessibilityHint("Click to restore")
    }
}

extension EditorModel {
    var cutMarkers: [CutMarker] { CutMarker.markers(from: trimGaps()) }
    /// Puts everything cut away at that boundary back, with the settings of the clip before it (else the one after), one undo step.
    func restoreCut(atNs: Int64) {
        guard let m = cutMarkers.first(where: { $0.atNs == atNs }) else { return }
        let starts = clipStarts()
        let template = starts.first { $0.startNs + $0.clip.timelineDurationNs == atNs }?.clip ?? starts.first { $0.startNs == atNs }?.clip
        perform(.batch(restoreCommands(m.gaps, like: template)))
    }
}
