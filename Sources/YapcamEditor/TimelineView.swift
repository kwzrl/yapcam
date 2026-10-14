import SwiftUI

enum TimelineLayout {
    static let rulerHeight: CGFloat = 24
    static let clipTrackHeight: CGFloat = 52
    static let zoomTrackHeight: CGFloat = 36
    static let gap: CGFloat = 6
    static let edgeHandle: CGFloat = 7
    static var totalHeight: CGFloat { rulerHeight + gap + clipTrackHeight + gap + zoomTrackHeight + 8 }
    static var clipTop: CGFloat { rulerHeight + gap }
    static var zoomTop: CGFloat { clipTop + clipTrackHeight + gap }
}

struct TimelineView: View {
    @ObservedObject var model: EditorModel
    @State private var viewportWidth: CGFloat = 800
    @State private var drag: DragKind?

    private enum DragKind {
        case scrub
        case zoomMove(id: String, grabOffsetNs: Int64)
        case zoomStart(id: String)
        case zoomEnd(id: String)
    }

    var body: some View {
        let g = model.geometry
        let contentW = max(g.contentWidth(durationNs: model.durationNs) + 40, viewportWidth)
        ScrollView(.horizontal, showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                Ruler(geometry: g, width: contentW)
                    .frame(width: contentW, height: TimelineLayout.rulerHeight)
                clipTrack(g)
                zoomTrack(g)
                if let snap = model.snapGuideNs {
                    Rectangle().fill(Color.yellow.opacity(0.9)).frame(width: 1, height: TimelineLayout.totalHeight)
                        .offset(x: g.x(forNs: snap) + g.scrollOffsetPx)
                }
                playhead(g)
            }
            .frame(width: contentW, height: TimelineLayout.totalHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(timelineDrag(g))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Timeline")
        }
        .frame(height: TimelineLayout.totalHeight + 16)
        .background(GeometryReader { p in Color.clear.onAppear { viewportWidth = p.size.width }
            .onChange(of: p.size.width) { _, w in viewportWidth = w } })
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // x positions use scrollOffsetPx = 0 inside the scroll view (scrolling is native).
    private func clipTrack(_ g: TimelineGeometry) -> some View {
        ForEach(Array(model.clipStarts().enumerated()), id: \.element.clip.id) { idx, entry in
            let x = g.x(forNs: entry.startNs)
            let w = max(g.contentWidth(durationNs: entry.clip.timelineDurationNs), 2)
            let selected = model.selection == .clip(entry.clip.id)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(selected ? 0.55 : 0.28))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(selected ? 1 : 0.5), lineWidth: selected ? 2 : 1))
                .overlay(alignment: .leading) {
                    HStack(spacing: 4) {
                        Text("Clip \(idx + 1)").font(.caption.weight(.medium))
                        if entry.clip.speed != 1 { Text(String(format: "%.2g×", entry.clip.speed)).font(.caption2).foregroundStyle(.secondary) }
                    }.padding(.leading, 8).lineLimit(1)
                }
                .frame(width: max(w - 1, 1), height: TimelineLayout.clipTrackHeight)
                .offset(x: x, y: TimelineLayout.clipTop)
                .accessibilityLabel("Clip \(idx + 1)")
                .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    private func zoomTrack(_ g: TimelineGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04))
                .frame(width: g.contentWidth(durationNs: model.durationNs), height: TimelineLayout.zoomTrackHeight)
            ForEach(model.zooms) { z in
                let selected = model.selection == .zoom(z.id)
                let tint: Color = z.mode == .auto ? .purple : .orange
                let w = max(g.contentWidth(durationNs: z.endNs - z.startNs), 6)
                RoundedRectangle(cornerRadius: 5)
                    .fill(tint.opacity(selected ? 0.6 : 0.32))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(tint.opacity(selected ? 1 : 0.6), lineWidth: selected ? 2 : 1))
                    .overlay(alignment: .leading) {
                        Label(String(format: "%.1f×", z.scale), systemImage: "plus.magnifyingglass")
                            .font(.caption2.weight(.medium)).labelStyle(.titleAndIcon).padding(.leading, 8).lineLimit(1)
                    }
                    .overlay(alignment: .leading) { Capsule().fill(tint).frame(width: 3, height: 16).padding(.leading, 2).opacity(selected ? 1 : 0) }
                    .overlay(alignment: .trailing) { Capsule().fill(tint).frame(width: 3, height: 16).padding(.trailing, 2).opacity(selected ? 1 : 0) }
                    .frame(width: w, height: TimelineLayout.zoomTrackHeight - 4)
                    .offset(x: g.x(forNs: z.startNs), y: 2)
                    .accessibilityLabel("Zoom \(String(format: "%.1f", z.scale))×, \(formatTimecode(z.startNs)) to \(formatTimecode(z.endNs))")
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .offset(y: TimelineLayout.zoomTop)
    }

    private func playhead(_ g: TimelineGeometry) -> some View {
        let x = g.x(forNs: model.playheadNs)
        return ZStack(alignment: .top) {
            Rectangle().fill(Color.red).frame(width: 1.5, height: TimelineLayout.totalHeight)
            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 10)).foregroundStyle(.red).offset(y: -1)
        }
        .frame(width: 12, height: TimelineLayout.totalHeight, alignment: .top)
        .offset(x: x - 6)
        .allowsHitTesting(false)
    }

    // MARK: gestures

    private func hitZoom(at x: CGFloat, _ g: TimelineGeometry) -> (ZoomInfo, DragKind)? {
        for z in model.zooms.reversed() {
            let x0 = g.x(forNs: z.startNs), x1 = g.x(forNs: z.endNs)
            let h = min(TimelineLayout.edgeHandle, (x1 - x0) / 3)
            if x >= x0 - 2 && x <= x1 + 2 {
                if x <= x0 + h { return (z, .zoomStart(id: z.id)) }
                if x >= x1 - h { return (z, .zoomEnd(id: z.id)) }
                return (z, .zoomMove(id: z.id, grabOffsetNs: g.ns(forX: x) - z.startNs))
            }
        }
        return nil
    }

    private func timelineDrag(_ g: TimelineGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if drag == nil { drag = begin(at: v.startLocation, g) }
                let ns = g.ns(forX: v.location.x)
                switch drag! {
                case .scrub:
                    model.seek(toNs: model.snapped(ns), precise: false)
                case .zoomMove(let id, let off):
                    model.moveZoom(id: id, toStartNs: model.snapped(ns - off, excludingZoom: id))
                case .zoomStart(let id):
                    model.resizeZoom(id: id, startNs: model.snapped(ns, excludingZoom: id))
                case .zoomEnd(let id):
                    model.resizeZoom(id: id, endNs: model.snapped(ns, excludingZoom: id))
                }
            }
            .onEnded { v in
                if case .scrub = drag { model.seek(toNs: model.playheadNs, precise: true) }
                drag = nil
                model.snapGuideNs = nil
            }
    }

    private func begin(at p: CGPoint, _ g: TimelineGeometry) -> DragKind {
        if p.y < TimelineLayout.clipTop {
            model.selection = .none
            return .scrub
        }
        if p.y >= TimelineLayout.zoomTop, let (z, kind) = hitZoom(at: p.x, g) {
            model.selection = .zoom(z.id)
            return kind
        }
        if p.y < TimelineLayout.zoomTop - TimelineLayout.gap,
           let hit = model.clipStarts().first(where: { p.x >= g.x(forNs: $0.startNs) && p.x < g.x(forNs: $0.startNs + $0.clip.timelineDurationNs) }) {
            model.selection = .clip(hit.clip.id)
        } else {
            model.selection = .none
        }
        model.seek(toNs: model.snapped(g.ns(forX: p.x)), precise: false)
        return .scrub
    }
}

struct Ruler: View {
    let geometry: TimelineGeometry
    let width: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let step = geometry.rulerStepSeconds()
            let minor = step / 5
            let maxT = Double(width) / geometry.pixelsPerSecond
            for i in 0...Int(maxT / minor) {
                let t = Double(i) * minor
                let x = t * geometry.pixelsPerSecond
                let isMajor = i % 5 == 0
                if isMajor {
                    ctx.fill(Path(CGRect(x: x, y: size.height - 10, width: 1, height: 10)), with: .color(.secondary))
                    let label = formatTimecode(Int64((t * 1e9).rounded()), showFraction: step < 1)
                    ctx.draw(Text(label).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary),
                             at: CGPoint(x: x + 4, y: 8), anchor: .leading)
                } else if minor * geometry.pixelsPerSecond >= 6 {
                    ctx.fill(Path(CGRect(x: x, y: size.height - 5, width: 1, height: 5)), with: .color(.secondary.opacity(0.5)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
