import SwiftUI

enum TimelineLane: CaseIterable { case typing, camera, cursor, highlight, text, caption, music }

/// Vertical layout of the timeline. Only lanes that have content are present (no empty rows);
/// the clip and zoom tracks are always there.
struct TimelineLayout {
    static let rulerHeight: CGFloat = 24
    static let clipTrackHeight: CGFloat = 56
    static let zoomTrackHeight: CGFloat = 38
    static let laneHeight: CGFloat = 28
    static let gap: CGFloat = 6
    static let edgeHandle: CGFloat = 7
    var lanes: [TimelineLane]
    init(lanes: [TimelineLane]) { self.lanes = lanes }
    init(hasCamera: Bool) { self.init(lanes: hasCamera ? [.camera] : []) }
    var clipTop: CGFloat { Self.rulerHeight + Self.gap }
    var zoomTop: CGFloat { clipTop + Self.clipTrackHeight + Self.gap }
    /// First y below the zoom track: everything at or below is an overlay lane.
    var lanesTop: CGFloat { zoomTop + Self.zoomTrackHeight + Self.gap }
    func top(of lane: TimelineLane) -> CGFloat? {
        guard let i = lanes.firstIndex(of: lane) else { return nil }
        return lanesTop + CGFloat(i) * (Self.laneHeight + Self.gap)
    }
    var typingTop: CGFloat { top(of: .typing) ?? lanesTop }
    var cameraTop: CGFloat { top(of: .camera) ?? lanesTop }
    var cursorTop: CGFloat { top(of: .cursor) ?? lanesTop }
    var highlightTop: CGFloat { top(of: .highlight) ?? lanesTop }
    var textTop: CGFloat { top(of: .text) ?? lanesTop }
    var captionTop: CGFloat { top(of: .caption) ?? lanesTop }
    var musicTop: CGFloat { top(of: .music) ?? lanesTop }
    var totalHeight: CGFloat { lanes.isEmpty ? lanesTop + 4 : lanesTop + CGFloat(lanes.count) * (Self.laneHeight + Self.gap) + 2 }
}

extension EditorModel {
    /// Overlay lanes that currently have content.
    var visibleLanes: [TimelineLane] {
        var out: [TimelineLane] = []
        if !typingSuggestions.isEmpty { out.append(.typing) }
        if !layouts.isEmpty { out.append(.camera) }
        if !cursorHides.isEmpty { out.append(.cursor) }
        if !highlights.isEmpty { out.append(.highlight) }
        if !textItems(.annotation).isEmpty || !textItems(.reaction).isEmpty { out.append(.text) }
        if !textItems(.caption).isEmpty { out.append(.caption) }
        if !music.isEmpty { out.append(.music) }
        return out
    }
}

struct TimelineView: View {
    @ObservedObject var model: EditorModel
    @State private var viewportWidth: CGFloat = 800
    @State private var drag: DragKind?
    private var layout: TimelineLayout { TimelineLayout(lanes: model.visibleLanes) }

    private enum DragKind {
        case scrub
        case inert
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
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            ZStack(alignment: .topLeading) {
                Ruler(geometry: g, width: contentW)
                    .frame(width: contentW, height: TimelineLayout.rulerHeight)
                ForEach(Array(model.project.markerTimesNs.enumerated()), id: \.offset) { _, ns in
                    Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(.orange)
                        .offset(x: g.x(forNs: ns) - 2, y: 1).allowsHitTesting(false)
                        .accessibilityLabel("Marker at \(formatTimecode(ns))")
                }
                clipTrack(g)
                zoomTrack(g)
                if layout.lanes.contains(.typing) { typingLane(g) }
                if layout.lanes.contains(.camera) { cameraLane(g) }
                if layout.lanes.contains(.cursor) { cursorLane(g) }
                if layout.lanes.contains(.highlight) { highlightLane(g) }
                if layout.lanes.contains(.text) { textLane(g, top: layout.textTop, kinds: [.annotation, .reaction]) }
                if layout.lanes.contains(.caption) { textLane(g, top: layout.captionTop, kinds: [.caption]) }
                if layout.lanes.contains(.music) { musicLane(g) }
                if let snap = model.snapGuideNs {
                    Rectangle().fill(Color.yellow.opacity(0.9)).frame(width: 1, height: layout.totalHeight)
                        .offset(x: g.x(forNs: snap) + g.scrollOffsetPx)
                }
                PlayheadMarker(playhead: model.playhead, model: model, geometry: g, height: layout.totalHeight)
            }
            .frame(width: contentW, height: layout.totalHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(timelineDrag(g))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Timeline")
        }
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
                        Text(clipLabel(entry.clip)).font(.callout.weight(.medium))
                        if entry.clip.speed != 1 { Text(String(format: "%.2g×", entry.clip.speed)).font(.caption2).foregroundStyle(.secondary) }
                    }.padding(.leading, 8).lineLimit(1)
                }
                .frame(width: max(w - 1, 1), height: TimelineLayout.clipTrackHeight)
                .offset(x: x, y: layout.clipTop)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Clip \(idx + 1)\(entry.clip.speed == 1 ? "" : String(format: ", %.2g× speed", entry.clip.speed)), \(formatTimecode(entry.startNs)) to \(formatTimecode(entry.startNs + entry.clip.timelineDurationNs))")
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction(named: "Select") { model.selection = .clip(entry.clip.id); model.seek(toNs: entry.startNs) }
                .accessibilityAction(named: "Delete") { model.selection = .clip(entry.clip.id); model.deleteSelection() }
        }
    }

    private func clipLabel(_ c: TimelineClip) -> String {
        let secs = Double(c.timelineDurationNs) / 1e9
        let d = secs >= 1 ? String(format: "%.0fs", secs.rounded()) : String(format: "%.0f ms", secs * 1000)
        return "\(d) · " + (c.speed == 1 ? "1x" : String(format: "%.2gx", c.speed))
    }

    private func zoomTrack(_ g: TimelineGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04))
                .frame(width: g.contentWidth(durationNs: model.durationNs), height: TimelineLayout.zoomTrackHeight)
            ForEach(model.zooms) { z in
                let selected = model.selection == .zoom(z.id) || model.extraZoomSelection.contains(z.id)
                let tint: Color = z.mode == .auto ? .purple : .orange
                let r = model.displayedRange(of: z)
                let w = max(g.contentWidth(durationNs: r.end - r.start), 6)
                RoundedRectangle(cornerRadius: 5)
                    .fill(tint.opacity(selected ? 0.6 : 0.32))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(tint.opacity(selected ? 1 : 0.6), lineWidth: selected ? 2 : 1))
                    .overlay(alignment: .leading) {
                        Label(String(format: "%.1fx · ", z.scale).replacingOccurrences(of: ".0x", with: "x") + (z.mode == .auto ? "Auto" : "Manual"), systemImage: "plus.magnifyingglass")
                            .font(.caption2.weight(.medium)).labelStyle(.titleAndIcon).padding(.leading, 8).lineLimit(1)
                    }
                    .overlay(alignment: .leading) { Capsule().fill(tint).frame(width: 3, height: 16).padding(.leading, 2).opacity(selected ? 1 : 0) }
                    .overlay(alignment: .trailing) { Capsule().fill(tint).frame(width: 3, height: 16).padding(.trailing, 2).opacity(selected ? 1 : 0) }
                    .frame(width: w, height: TimelineLayout.zoomTrackHeight - 4)
                    .offset(x: g.x(forNs: r.start), y: 2)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(format: "Zoom %.1f×", z.scale) + (z.mode == .auto ? ", automatic" : "") + ", \(formatTimecode(r.start)) to \(formatTimecode(r.end))")
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                    .modifier(ItemActions(model: model, selection: .zoom(z.id)))
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

    private func rangeChip(_ g: TimelineGeometry, key: String, span: TimeSpan, top: CGFloat, tint: Color, title: String, sel: EditorSelection) -> some View {
        let selected = model.selection == sel
        let r = model.zoomPreview[key] ?? (span.startNs, span.endNs)
        return RoundedRectangle(cornerRadius: 5)
            .fill(tint.opacity(selected ? 0.6 : 0.32))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(tint.opacity(selected ? 1 : 0.6), lineWidth: selected ? 2 : 1))
            .overlay(alignment: .leading) { Text(title).font(.caption2.weight(.medium)).lineLimit(1).padding(.leading, 8) }
            .frame(width: max(g.contentWidth(durationNs: r.1 - r.0), 6), height: TimelineLayout.laneHeight - 4)
            .offset(x: g.x(forNs: r.0), y: top + 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(formatTimecode(r.0)) to \(formatTimecode(r.1))")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .modifier(ItemActions(model: model, selection: sel))
    }

    /// Keystroke bursts that could be sped up; click one for the suggestion popover.
    private func typingLane(_ g: TimelineGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            laneBackground(g, top: layout.typingTop, label: "")
            ForEach(model.typingSuggestions, id: \.startNs) { sp in
                RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.orange.opacity(0.7)))
                    .overlay(alignment: .leading) { Label("Typing", systemImage: "keyboard").font(.caption2.weight(.medium)).padding(.leading, 6).lineLimit(1) }
                    .frame(width: max(g.contentWidth(durationNs: sp.durationNs), 6), height: TimelineLayout.laneHeight - 4)
                    .offset(x: g.x(forNs: sp.startNs), y: layout.typingTop + 2)
                    .popover(isPresented: Binding(get: { model.typingPopover == sp.startNs }, set: { if !$0 { model.typingPopover = nil } }), arrowEdge: .top) {
                        TypingPopover(model: model, span: sp)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Typing suggestion, \(formatTimecode(sp.startNs)) to \(formatTimecode(sp.endNs))")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: "Open suggestion") { model.typingPopover = sp.startNs }
            }
        }
    }

    private func cameraLane(_ g: TimelineGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            laneBackground(g, top: layout.cameraTop, label: "")
            ForEach(model.layouts) { l in
                rangeChip(g, key: l.id, span: TimeSpan(startNs: l.startNs, endNs: l.endNs), top: layout.cameraTop, tint: .teal,
                          title: layoutModes.first { $0.value == l.mode }?.label ?? l.mode, sel: .layout(l.id))
            }
        }
    }

    private func highlightLane(_ g: TimelineGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            laneBackground(g, top: layout.highlightTop, label: "")
            ForEach(model.highlights) { h in
                rangeChip(g, key: h.id, span: h.span, top: layout.highlightTop, tint: .yellow,
                          title: h.kind.label, sel: .highlight(h.id))
            }
        }
    }

    private func textLane(_ g: TimelineGeometry, top: CGFloat, kinds: [TextKind]) -> some View {
        ZStack(alignment: .topLeading) {
            laneBackground(g, top: top, label: "")
            ForEach(kinds.flatMap { model.textItems($0) }) { t in
                rangeChip(g, key: EditorModel.textKey(t), span: t.span, top: top, tint: t.kind == .caption ? .indigo : t.kind == .reaction ? .pink : .mint,
                          title: t.text.replacingOccurrences(of: "\n", with: " "), sel: .text(t.kind, t.id))
            }
        }
    }

    private func musicLane(_ g: TimelineGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            laneBackground(g, top: layout.musicTop, label: "")
            ForEach(model.music) { m in
                rangeChip(g, key: m.id, span: m.span, top: layout.musicTop, tint: .green, title: "♪ " + m.title, sel: .music(m.id))
            }
        }
    }

    private func cursorLane(_ g: TimelineGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            laneBackground(g, top: layout.cursorTop, label: "")
            ForEach(model.cursorHides, id: \.index) { h in
                rangeChip(g, key: EditorModel.cursorKey(h.index), span: h.span, top: layout.cursorTop, tint: .gray,
                          title: "Cursor hidden", sel: .cursorHide(h.index))
            }
        }
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
        items += model.allText.map { ($0.kind == .caption ? EditorModel.textKey($0) : EditorModel.textKey($0), $0.span, $0.kind == .caption ? layout.captionTop : layout.textTop, .text($0.kind, $0.id)) }
        items += model.music.map { ($0.id, $0.span, layout.musicTop, .music($0.id)) }
        items += model.highlights.map { ($0.id, $0.span, layout.highlightTop, .highlight($0.id)) }
        items += model.cursorHides.map { (EditorModel.cursorKey($0.index), $0.span, layout.cursorTop, .cursorHide($0.index)) }
        guard let hit = LaneHitTest.topmost(x: p.x, y: p.y, items: items.map { LaneHitTest.Item(key: $0.key, span: $0.span, top: $0.top, tag: $0.sel) },
                                            preview: model.zoomPreview, geometry: g) else { return nil }
        model.selection = hit.tag
        switch hit.part {
        case .start: return .rangeStart(key: hit.key)
        case .end: return .rangeEnd(key: hit.key)
        case .body(let off): return .rangeMove(key: hit.key, grabOffsetNs: off)
        }
    }

    private func currentSpan(_ key: String) -> TimeSpan? {
        if let l = model.layouts.first(where: { $0.id == key }) { return TimeSpan(startNs: l.startNs, endNs: l.endNs) }
        if let h = model.highlights.first(where: { $0.id == key }) { return h.span }
        if let t = model.textItem(key: key) { return t.span }
        if let m = model.music.first(where: { $0.id == key }) { return m.span }
        if key.hasPrefix("cursor:"), let i = Int(key.dropFirst(7)) { return model.cursorHides.first { $0.index == i }?.span }
        return nil
    }

    private func timelineDrag(_ g: TimelineGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if drag == nil { drag = begin(at: v.startLocation, g) }
                let ns = g.ns(forX: v.location.x)
                switch drag! {
                case .inert: break
                case .scrub:
                    model.seek(toNs: model.snapped(ns, includePlayhead: false), precise: false)
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
                case .inert, nil: break
                }
                drag = nil
                model.snapGuideNs = nil
            }
    }

    private func begin(at p: CGPoint, _ g: TimelineGeometry) -> DragKind {
        if !(p.y >= layout.zoomTop && p.y < layout.lanesTop) { model.extraZoomSelection = [] }
        if p.y < layout.clipTop {
            model.selection = .none
            return .scrub
        }
        if layout.lanes.contains(.typing), p.y >= layout.typingTop, p.y < layout.typingTop + TimelineLayout.laneHeight,
           let sp = model.typingSuggestions.first(where: { p.x >= g.x(forNs: $0.startNs) - 2 && p.x <= g.x(forNs: $0.endNs) + 2 }) {
            model.typingPopover = sp.startNs; return .inert
        }
        if p.y >= layout.lanesTop, let kind = hitRange(at: p, g) { return kind }
        if p.y >= layout.zoomTop, p.y < layout.lanesTop, let (z, kind) = hitZoom(at: p.x, g) {
            if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) {
                // Multi-select: toggle membership; no drag.
                if case .zoom(let primary) = model.selection {
                    if z.id == primary { model.selection = model.extraZoomSelection.first.map { .zoom($0) } ?? .none
                                         if let n = model.extraZoomSelection.first { model.extraZoomSelection.remove(n) } }
                    else if model.extraZoomSelection.contains(z.id) { model.extraZoomSelection.remove(z.id) }
                    else { model.extraZoomSelection.insert(z.id) }
                } else { model.selection = .zoom(z.id) }
                return .inert
            }
            model.extraZoomSelection = []
            model.selection = .zoom(z.id)
            return kind
        }
        if p.y < layout.zoomTop - TimelineLayout.gap,
           let hit = model.clipStarts().first(where: { p.x >= g.x(forNs: $0.startNs) && p.x < g.x(forNs: $0.startNs + $0.clip.timelineDurationNs) }) {
            if model.cutToolActive {
                // Scissors: a click on a clip splits it there (snapped to edit points).
                model.seek(toNs: model.snapped(g.ns(forX: p.x), includePlayhead: false), precise: true)
                model.splitAtPlayhead()
                return .inert
            }
            model.selection = .clip(hit.clip.id)
        } else {
            model.selection = .none
        }
        model.seek(toNs: model.snapped(g.ns(forX: p.x), includePlayhead: false), precise: false)
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

/// Pure hit testing for the overlay lanes. Items are in drawing order, so later items are on top and win overlaps.
enum LaneHitTest {
    struct Item { var key: String; var span: TimeSpan; var top: CGFloat; var tag: EditorSelection }
    enum Part: Equatable { case start, end, body(grabOffsetNs: Int64) }
    struct Hit { var key: String; var tag: EditorSelection; var part: Part }

    static func topmost(x: Double, y: Double, items: [Item], preview: [String: (start: Int64, end: Int64)], geometry g: TimelineGeometry) -> Hit? {
        for it in items.reversed() where y >= it.top && y < it.top + TimelineLayout.laneHeight {
            let r = preview[it.key] ?? (it.span.startNs, it.span.endNs)
            let x0 = g.x(forNs: r.0), x1 = g.x(forNs: r.1)
            guard x >= x0 - 2 && x <= x1 + 2 else { continue }
            let h = min(TimelineLayout.edgeHandle, (x1 - x0) / 3)
            if x <= x0 + h { return Hit(key: it.key, tag: it.tag, part: .start) }
            if x >= x1 - h { return Hit(key: it.key, tag: it.tag, part: .end) }
            return Hit(key: it.key, tag: it.tag, part: .body(grabOffsetNs: g.ns(forX: x) - r.0))
        }
        return nil
    }
}

/// Only this view observes the playhead, so scrubbing never re-evaluates the tracks.
struct PlayheadMarker: View {
    @ObservedObject var playhead: PlayheadState
    let model: EditorModel
    let geometry: TimelineGeometry
    let height: CGFloat
    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(Color.red).frame(width: 1.5, height: height)
            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 10)).foregroundStyle(.red).offset(y: -1)
        }
        .frame(width: 12, height: height, alignment: .top)
        .offset(x: geometry.x(forNs: playhead.ns) - 6)
        .allowsHitTesting(false)
        // VoiceOver: an adjustable "playhead" (up/down = ±1 s) with jump-to-edit-point actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playhead")
        .accessibilityValue("\(formatTimecode(playhead.ns)) of \(formatTimecode(model.durationNs))")
        .accessibilityAdjustableAction { dir in model.step(bySeconds: dir == .increment ? 1 : -1) }
        .accessibilityAction(named: "Previous edit point") { model.jumpToEditPoint(forward: false) }
        .accessibilityAction(named: "Next edit point") { model.jumpToEditPoint(forward: true) }
    }
}

/// VoiceOver actions shared by all timeline items.
struct ItemActions: ViewModifier {
    let model: EditorModel
    let selection: EditorSelection
    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: "Select") { model.selection = selection; if let i = model.selectableItems.first(where: { $0.selection == selection }) { model.seek(toNs: i.startNs) } }
            .accessibilityAction(named: "Delete") { model.selection = selection; model.deleteSelection() }
            .accessibilityAction(named: "Move earlier by 0.1 seconds") { model.selection = selection; model.nudgeSelection(byNs: -100_000_000) }
            .accessibilityAction(named: "Move later by 0.1 seconds") { model.selection = selection; model.nudgeSelection(byNs: 100_000_000) }
    }
}

/// Popover on a typing burst: speed 1.5–8x (remembered), apply, apply to all, remove the suggestion.
struct TypingPopover: View {
    @ObservedObject var model: EditorModel
    let span: TimeSpan
    @State private var speed = 3.0
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Speed up typing", systemImage: "keyboard").font(.headline)
            Text("\(formatTimecode(span.startNs)) – \(formatTimecode(span.endNs))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack {
                Slider(value: $speed, in: EditorModel.typingSpeedRange, step: 0.5) { e in if !e { model.typingSpeed = speed } }
                    .accessibilityLabel("Typing speed").accessibilityValue(String(format: "%.1f times", speed))
                Text(String(format: "%.1fx", speed)).monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            HStack {
                Button("Apply") { model.typingSpeed = speed; model.applyTypingSuggestion(span) }.keyboardShortcut(.defaultAction)
                Button("Apply to all (\(model.typingSuggestions.count))") { model.typingSpeed = speed; model.applyAllTypingSuggestions() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
            HStack {
                Button("Remove suggestion", role: .destructive) { model.dismissTypingSuggestion(span) }
                Button("Restore removed") { model.restoreTypingSuggestions() }
            }.buttonStyle(.borderless)
        }
        .padding(14).frame(width: 290)
        .onAppear { speed = model.typingSpeed }
    }
}
