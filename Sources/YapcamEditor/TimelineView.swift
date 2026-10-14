import SwiftUI

struct TimelineLayout {
    static let rulerHeight: CGFloat = 24
    static let clipTrackHeight: CGFloat = 52
    static let zoomTrackHeight: CGFloat = 36
    static let laneHeight: CGFloat = 28
    static let gap: CGFloat = 6
    static let edgeHandle: CGFloat = 7
    var hasCamera: Bool
    var clipTop: CGFloat { Self.rulerHeight + Self.gap }
    var zoomTop: CGFloat { clipTop + Self.clipTrackHeight + Self.gap }
    var cameraTop: CGFloat { zoomTop + Self.zoomTrackHeight + Self.gap }
    var cursorTop: CGFloat { hasCamera ? cameraTop + Self.laneHeight + Self.gap : cameraTop }
    var totalHeight: CGFloat { cursorTop + Self.laneHeight + 8 }
}

struct TimelineView: View {
    @ObservedObject var model: EditorModel
    @State private var viewportWidth: CGFloat = 800
    @State private var drag: DragKind?
    private var layout: TimelineLayout { TimelineLayout(hasCamera: model.hasCamera) }

    private enum DragKind {
        case scrub
        case zoomMove(id: String, grabOffsetNs: Int64)
        case zoomStart(id: String)
        case zoomEnd(id: String)
        case rangeMove(key: String, grabOffsetNs: Int64)
        case rangeStart(key: String)
        case rangeEnd(key: String)
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
                if model.hasCamera { cameraLane(g) }
                cursorLane(g)
                if let snap = model.snapGuideNs {
                    Rectangle().fill(Color.yellow.opacity(0.9)).frame(width: 1, height: layout.totalHeight)
                        .offset(x: g.x(forNs: snap) + g.scrollOffsetPx)
                }
                playhead(g)
            }
            .frame(width: contentW, height: layout.totalHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(timelineDrag(g))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Timeline")
        }
        .frame(height: layout.totalHeight + 16)
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
                .offset(x: x, y: layout.clipTop)
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
                let r = model.displayedRange(of: z)
                let w = max(g.contentWidth(durationNs: r.end - r.start), 6)
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
                    .offset(x: g.x(forNs: r.start), y: 2)
                    .accessibilityLabel("Zoom \(String(format: "%.1f", z.scale))×, \(formatTimecode(z.startNs)) to \(formatTimecode(z.endNs))")
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .offset(y: layout.zoomTop)
    }

    private func laneBackground(_ g: TimelineGeometry, top: CGFloat, label: String) -> some View {
        RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04))
            .overlay(alignment: .leading) { Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary).padding(.leading, 6) }
            .frame(width: g.contentWidth(durationNs: model.durationNs), height: TimelineLayout.laneHeight)
            .offset(y: top)
    }

    private func rangeChip(_ g: TimelineGeometry, key: String, span: TimeSpan, top: CGFloat, tint: Color, title: String, selected: Bool) -> some View {
        let r = model.zoomPreview[key] ?? (span.startNs, span.endNs)
        return RoundedRectangle(cornerRadius: 5)
            .fill(tint.opacity(selected ? 0.6 : 0.32))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(tint.opacity(selected ? 1 : 0.6), lineWidth: selected ? 2 : 1))
            .overlay(alignment: .leading) { Text(title).font(.caption2.weight(.medium)).lineLimit(1).padding(.leading, 8) }
            .frame(width: max(g.contentWidth(durationNs: r.1 - r.0), 6), height: TimelineLayout.laneHeight - 4)
            .offset(x: g.x(forNs: r.0), y: top + 2)
            .accessibilityLabel("\(title), \(formatTimecode(r.0)) to \(formatTimecode(r.1))")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func cameraLane(_ g: TimelineGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            laneBackground(g, top: layout.cameraTop, label: "")
            ForEach(model.layouts) { l in
                rangeChip(g, key: l.id, span: TimeSpan(startNs: l.startNs, endNs: l.endNs), top: layout.cameraTop, tint: .teal,
                          title: layoutModes.first { $0.value == l.mode }?.label ?? l.mode, selected: model.selection == .layout(l.id))
            }
        }
    }

    private func cursorLane(_ g: TimelineGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            laneBackground(g, top: layout.cursorTop, label: "")
            ForEach(model.cursorHides, id: \.index) { h in
                rangeChip(g, key: EditorModel.cursorKey(h.index), span: h.span, top: layout.cursorTop, tint: .gray,
                          title: "Cursor hidden", selected: model.selection == .cursorHide(h.index))
            }
        }
    }

    private func playhead(_ g: TimelineGeometry) -> some View {
        let x = g.x(forNs: model.playheadNs)
        return ZStack(alignment: .top) {
            Rectangle().fill(Color.red).frame(width: 1.5, height: layout.totalHeight)
            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 10)).foregroundStyle(.red).offset(y: -1)
        }
        .frame(width: 12, height: layout.totalHeight, alignment: .top)
        .offset(x: x - 6)
        .allowsHitTesting(false)
    }

    // MARK: gestures

    private func hitZoom(at x: CGFloat, _ g: TimelineGeometry) -> (TimelineZoom, DragKind)? {
        for z in model.zooms.reversed() {
            let r = model.displayedRange(of: z)
            let x0 = g.x(forNs: r.start), x1 = g.x(forNs: r.end)
            let h = min(TimelineLayout.edgeHandle, (x1 - x0) / 3)
            if x >= x0 - 2 && x <= x1 + 2 {
                if x <= x0 + h { return (z, .zoomStart(id: z.id)) }
                if x >= x1 - h { return (z, .zoomEnd(id: z.id)) }
                return (z, .zoomMove(id: z.id, grabOffsetNs: g.ns(forX: x) - z.startNs))
            }
        }
        return nil
    }

    private func hitRange(at p: CGPoint, _ g: TimelineGeometry) -> DragKind? {
        var items: [(key: String, span: TimeSpan, top: CGFloat, sel: EditorSelection)] = []
        if model.hasCamera { items += model.layouts.map { ($0.id, TimeSpan(startNs: $0.startNs, endNs: $0.endNs), layout.cameraTop, .layout($0.id)) } }
        items += model.cursorHides.map { (EditorModel.cursorKey($0.index), $0.span, layout.cursorTop, .cursorHide($0.index)) }
        for it in items where p.y >= it.top && p.y < it.top + TimelineLayout.laneHeight {
            let r = model.zoomPreview[it.key] ?? (it.span.startNs, it.span.endNs)
            let x0 = g.x(forNs: r.0), x1 = g.x(forNs: r.1)
            guard p.x >= x0 - 2 && p.x <= x1 + 2 else { continue }
            model.selection = it.sel
            let h = min(TimelineLayout.edgeHandle, (x1 - x0) / 3)
            if p.x <= x0 + h { return .rangeStart(key: it.key) }
            if p.x >= x1 - h { return .rangeEnd(key: it.key) }
            return .rangeMove(key: it.key, grabOffsetNs: g.ns(forX: p.x) - r.0)
        }
        return nil
    }

    private func currentSpan(_ key: String) -> TimeSpan? {
        if let l = model.layouts.first(where: { $0.id == key }) { return TimeSpan(startNs: l.startNs, endNs: l.endNs) }
        if key.hasPrefix("cursor:"), let i = Int(key.dropFirst(7)) { return model.cursorHides.first { $0.index == i }?.span }
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
                    model.previewZoom(id: id, moveToStartNs: model.snapped(ns - off, excludingZoom: id))
                case .zoomStart(let id):
                    model.previewZoom(id: id, startNs: model.snapped(ns, excludingZoom: id))
                case .zoomEnd(let id):
                    model.previewZoom(id: id, endNs: model.snapped(ns, excludingZoom: id))
                case .rangeMove(let key, let off):
                    if let c = currentSpan(key) { model.previewRange(key: key, current: c, moveToStartNs: model.snapped(ns - off)) }
                case .rangeStart(let key):
                    if let c = currentSpan(key) { model.previewRange(key: key, current: c, startNs: model.snapped(ns)) }
                case .rangeEnd(let key):
                    if let c = currentSpan(key) { model.previewRange(key: key, current: c, endNs: model.snapped(ns)) }
                }
            }
            .onEnded { v in
                switch drag {
                case .scrub: model.seek(toNs: model.playheadNs, precise: true)
                case .zoomMove(let id, _), .zoomStart(let id), .zoomEnd(let id): model.commitZoomPreview(id: id)
                case .rangeMove(let k, _), .rangeStart(let k), .rangeEnd(let k): model.commitRange(key: k)
                case nil: break
                }
                drag = nil
                model.snapGuideNs = nil
            }
    }

    private func begin(at p: CGPoint, _ g: TimelineGeometry) -> DragKind {
        if p.y < layout.clipTop {
            model.selection = .none
            return .scrub
        }
        if p.y >= layout.cameraTop, let kind = hitRange(at: p, g) { return kind }
        if p.y >= layout.zoomTop, p.y < layout.cameraTop, let (z, kind) = hitZoom(at: p.x, g) {
            model.selection = .zoom(z.id)
            return kind
        }
        if p.y < layout.zoomTop - TimelineLayout.gap,
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
