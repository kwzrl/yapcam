import SwiftUI
import YapcamDesign

enum TimelineLane: String, CaseIterable { case typing, camera, cursor, highlight, text, caption, music }

extension TimelineLane {
    /// Quiet name in the track-name column.
    var title: String {
        switch self {
        case .typing: "Typing"
        case .camera: "Camera"
        case .cursor: "Cursor"
        case .highlight: "Regions"
        case .text: "Text"
        case .caption: "Captions"
        case .music: "Music"
        }
    }
}

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

/// Colours of the timeline. Chrome stays grey and white; colour only on content: clips yellow to amber, zooms violet,
/// camera green, regions pink. Selection is a white outline and a step of brightness, never a colour.
enum TimelineLook {
    static let clip = LinearGradient(colors: [Yap.clipTop, Yap.clipBottom], startPoint: .top, endPoint: .bottom)
    static let zoom = Yap.zoom
    /// Automatic zooms: the same violet, a little deeper, so manual ones stand out without a second hue.
    static let zoomAuto = Color(red: 0.45, green: 0.36, blue: 0.86)
    static let camera = Color(red: 0.36, green: 0.70, blue: 0.56)
    static let regions = Color(red: 0.96, green: 0.47, blue: 0.56)
    static let text = Color(red: 0.86, green: 0.55, blue: 0.82)
    static let caption = Color.white.opacity(0.16)
    static let music = Color(red: 0.95, green: 0.58, blue: 0.34)
    static let cursor = Color.white.opacity(0.22)
    /// Lane ground: a faint step of brightness, so empty time reads as track.
    static let laneGround = Color.white.opacity(0.04)
    static let radius: CGFloat = 6
    /// Track-name column left of the tracks (names never sit under items).
    static let namesWidth: CGFloat = 64
    static let namesColumn: CGFloat = namesWidth + 8
}

struct TimelineView: View {
    @ObservedObject var model: EditorModel
    @State private var viewportWidth: CGFloat = 800
    @State private var drag: DragKind?
    @State private var dragMoved = false
    @Environment(\.displayScale) private var displayScale
    private var layout: TimelineLayout { TimelineLayout(lanes: model.visibleLanes) }

    /// Width the track-name column takes from the panel.
    static let namesWidth = TimelineLook.namesColumn

    private enum DragKind {
        case scrub
        case inert
        case zoomCreate(startNs: Int64)
        case zoomMove(id: String, grabOffsetNs: Int64)
        case zoomStart(id: String)
        case zoomEnd(id: String)
        case rangeMove(key: String, grabOffsetNs: Int64)
        case rangeStart(key: String)
        case rangeEnd(key: String)
        case clipEdge(id: String, edge: ClipTrim.Edge)
        case laneCreate(lane: TimelineLane, startNs: Int64)
    }

    var body: some View {
        // Names stay put while the tracks scroll sideways; both scroll together vertically when lanes overflow.
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                TrackNames(layout: layout)
                ScrollView(.horizontal) { tracks }
                    .frame(height: layout.totalHeight)
                    .background(GeometryReader { p in Color.clear.onAppear { viewportChanged(p.size.width) }
                        .onChange(of: p.size.width) { _, w in viewportChanged(w) } })
            }
        }
        .scrollIndicators(.automatic)
        .task(id: model.revision) {
            try? await Task.sleep(for: .milliseconds(120))
            if !Task.isCancelled { await model.refreshWaveform() }
        }
    }

    private var tracks: some View {
        let g = model.geometry
        let contentW = max(g.contentWidth(durationNs: model.durationNs) + 40, viewportWidth)
        return ZStack(alignment: .topLeading) {
            Ruler(geometry: g, width: contentW)
                .frame(width: contentW, height: TimelineLayout.rulerHeight)
            markers(g)
            cutBubbles(g)
            outsideEnd(g, contentW: contentW)
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
                Rectangle().fill(Yap.technical).frame(width: PixelGrid.pixel(scale: displayScale), height: layout.totalHeight)
                    .offset(x: PixelGrid.lineEdge(g.x(forNs: snap) + g.scrollOffsetPx, scale: displayScale))
                    .allowsHitTesting(false)
            }
            PlayheadMarker(playhead: model.playhead, model: model, geometry: g, height: layout.totalHeight)
        }
        .frame(width: contentW, height: layout.totalHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(timelineDrag(g))
        .overlay(TimelineContextMenuHost { contextMenu(at: $0) })
        .background(TimelineScrollHost(model: model))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline")
    }

    /// Remembers the visible width; the first real width fits the whole project with a small margin.
    private func viewportChanged(_ w: CGFloat) {
        viewportWidth = w
        // Content is the fitted width plus 40 pt of scroll margin; fitting to (w − 16) makes it exactly the viewport (no scrollbar).
        model.timelineViewportWidth = Double(w) - 16
        if !model.timelineFitted, w > 100 { model.timelineFitted = true; model.fitTimeline(width: Double(w) - 16) }
    }

    /// Markers sit on the ruler, between the labels and the ticks.
    private func markers(_ g: TimelineGeometry) -> some View {
        ForEach(Array(model.project.markerTimesNs.enumerated()), id: \.offset) { _, ns in
            Image(systemName: "flag.fill").font(.system(size: 8)).foregroundStyle(Yap.label)
                .offset(x: g.x(forNs: ns) + 2, y: 13).allowsHitTesting(false)
                .help("Marker at \(formatTimecode(ns, showFraction: false))")
                .accessibilityLabel("Marker at \(formatTimecode(ns))")
        }
    }

    /// Scissors bubbles where material was trimmed or cut away; clicking one restores it (routed through `TimelineClick`).
    private func cutBubbles(_ g: TimelineGeometry) -> some View {
        ForEach(model.cutMarkers) { m in
            CutMarkerBubble(marker: m)
                .offset(x: g.x(forNs: m.atNs) - CutMarker.width(CutMarker.label(m.removedNs)) / 2, y: CutMarker.top)
                .allowsHitTesting(false)
        }
    }

    /// Time after the project end: lanes stop there, the ruler goes on, and this dimmed area says "outside".
    private func outsideEnd(_ g: TimelineGeometry, contentW: CGFloat) -> some View {
        let x = g.x(forNs: model.durationNs)
        return Rectangle().fill(Color.black.opacity(0.2))
            .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.14)).frame(width: PixelGrid.pixel(scale: displayScale)) }
            .frame(width: max(contentW - x, 0), height: max(layout.totalHeight - TimelineLayout.rulerHeight, 0))
            .offset(x: x, y: TimelineLayout.rulerHeight)
            .allowsHitTesting(false).accessibilityHidden(true)
    }

    // x positions use scrollOffsetPx = 0 inside the scroll view (scrolling is native).
    private func clipTrack(_ g: TimelineGeometry) -> some View {
        ForEach(Array(model.clipStarts().enumerated()), id: \.element.clip.id) { idx, entry in
            let x = g.x(forNs: entry.startNs)
            let w = max(g.contentWidth(durationNs: entry.clip.timelineDurationNs), 2)
            let selected = model.selection == .clip(entry.clip.id)
            RoundedRectangle(cornerRadius: TimelineLook.radius, style: .continuous)
                .fill(TimelineLook.clip)
                .overlay(alignment: .topLeading) {
                    if model.showWaveform && !model.waveform.isEmpty {
                        WaveformLayer(points: model.waveform, geometry: g, width: g.contentWidth(durationNs: model.durationNs) + 40, height: TimelineLayout.clipTrackHeight, smooth: model.smoothWaveform)
                            .offset(x: -x).frame(width: max(w - 1, 1), height: TimelineLayout.clipTrackHeight, alignment: .topLeading).clipped()
                    }
                }
                .overlay(alignment: .topLeading) { clipFace(entry.clip) }
                .modifier(ChipChrome(selected: selected, grips: true))
                .frame(width: max(w - 1, 1), height: TimelineLayout.clipTrackHeight)
                .offset(x: x, y: layout.clipTop)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(TimelineChipText.clipAccessibility(entry.clip, number: idx + 1, start: formatTimecode(entry.startNs), end: formatTimecode(entry.startNs + entry.clip.timelineDurationNs)))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction(named: "Select") { model.selection = .clip(entry.clip.id); model.seek(toNs: entry.startNs) }
                .accessibilityAction(named: "Delete") { model.selection = .clip(entry.clip.id); model.deleteSelection() }
        }
    }

    /// The length (and speed) on a small dark label, above the waveform; only where it fits whole.
    private func clipFace(_ c: TimelineClip) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                Text(clipLabel(c)).font(.system(size: 10, weight: .semibold)).lineLimit(1).fixedSize()
                if c.hideCursor { Image(systemName: "eye.slash").font(.system(size: 9, weight: .semibold)).help("Cursor hidden in this clip") }
                if c.disableSmoothing { Image(systemName: "cursorarrow.motionlines.click").font(.system(size: 9, weight: .semibold)).help("Smooth cursor movement is off in this clip") }
            }
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(4)
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private func clipLabel(_ c: TimelineClip) -> String {
        let secs = Double(c.timelineDurationNs) / 1e9
        let d = secs >= 1 ? String(format: "%.0fs", secs.rounded()) : String(format: "%.0f ms", secs * 1000)
        return "\(d) · " + (c.speed == 1 ? "1x" : String(format: "%.2gx", c.speed))
    }

    private func zoomTrack(_ g: TimelineGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: TimelineLook.radius, style: .continuous).fill(TimelineLook.laneGround)
                .overlay { if model.zooms.isEmpty && model.zoomCreatePreview == nil {
                    Text("Click or drag to add zoom on cursor").font(.system(size: 11)).foregroundStyle(Yap.faint).lineLimit(1)
                } }
                .frame(width: g.contentWidth(durationNs: model.durationNs), height: TimelineLayout.zoomTrackHeight)
            if let p = model.zoomCreatePreview {
                RoundedRectangle(cornerRadius: TimelineLook.radius, style: .continuous)
                    .fill(TimelineLook.zoom.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius: TimelineLook.radius, style: .continuous)
                        .strokeBorder(TimelineLook.zoom, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                    .frame(width: max(g.contentWidth(durationNs: p.end - p.start), 2), height: TimelineLayout.zoomTrackHeight - 4)
                    .offset(x: g.x(forNs: p.start), y: 2).allowsHitTesting(false)
            }
            ForEach(model.zooms) { z in
                let selected = model.selection == .zoom(z.id) || model.extraZoomSelection.contains(z.id)
                let r = model.displayedRange(of: z)
                let w = max(g.contentWidth(durationNs: r.end - r.start), 6)
                RoundedRectangle(cornerRadius: TimelineLook.radius, style: .continuous)
                    .fill(z.mode == .auto ? TimelineLook.zoomAuto : TimelineLook.zoom)
                    .overlay(alignment: .leading) {
                        ChipLabel(text: TimelineChipText.zoomTitle(z), symbol: "plus.magnifyingglass")
                    }
                    .modifier(ChipChrome(selected: selected))
                    .opacity(z.enabled ? 1 : 0.4)
                    .frame(width: w, height: TimelineLayout.zoomTrackHeight - 4)
                    .offset(x: g.x(forNs: r.start), y: 2)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(TimelineChipText.zoomAccessibility(z, start: formatTimecode(r.start), end: formatTimecode(r.end)))
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                    .modifier(ItemActions(model: model, selection: .zoom(z.id)))
            }
        }
        .offset(y: layout.zoomTop)
    }

    /// Hint on an empty creatable lane, and the dashed chip while dragging out a new item.
    @ViewBuilder private func laneHint(_ g: TimelineGeometry, top: CGFloat, lane: TimelineLane, empty: Bool, text: String) -> some View {
        if empty && model.laneCreatePreview == nil {
            Text(text).font(.system(size: 11)).foregroundStyle(Yap.faint).lineLimit(1).padding(.leading, 8)
                .frame(width: g.contentWidth(durationNs: model.durationNs), height: TimelineLayout.laneHeight, alignment: .leading)
                .offset(y: top).allowsHitTesting(false)
        }
        if let p = model.laneCreatePreview, p.lane == lane {
            RoundedRectangle(cornerRadius: TimelineLook.radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .frame(width: max(g.contentWidth(durationNs: p.end - p.start), 2), height: TimelineLayout.laneHeight - 4)
                .offset(x: g.x(forNs: p.start), y: top + 2).allowsHitTesting(false)
        }
    }

    private func laneBackground(_ g: TimelineGeometry, top: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: TimelineLook.radius, style: .continuous).fill(TimelineLook.laneGround)
            .frame(width: g.contentWidth(durationNs: model.durationNs), height: TimelineLayout.laneHeight)
            .offset(y: top)
    }

    private func rangeChip(_ g: TimelineGeometry, key: String, span: TimeSpan, top: CGFloat, fill: Color, title: String, sel: EditorSelection,
                           enabled: Bool = true, labelColor: Color = .white) -> some View {
        let selected = model.selection == sel
        let r = model.zoomPreview[key] ?? (span.startNs, span.endNs)
        return RoundedRectangle(cornerRadius: TimelineLook.radius, style: .continuous)
            .fill(fill)
            .overlay(alignment: .leading) { ChipLabel(text: title, color: labelColor) }
            .modifier(ChipChrome(selected: selected))
            .opacity(enabled ? 1 : 0.4)
            .frame(width: max(g.contentWidth(durationNs: r.1 - r.0), 6), height: TimelineLayout.laneHeight - 4)
            .offset(x: g.x(forNs: r.0), y: top + 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(formatTimecode(r.0)) to \(formatTimecode(r.1))")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .modifier(ItemActions(model: model, selection: sel))
    }

    /// Keystroke bursts that could be sped up: dashed while only suggested; click one for the suggestion popover.
    private func typingLane(_ g: TimelineGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            laneBackground(g, top: layout.typingTop)
            ForEach(model.typingSuggestions, id: \.startNs) { sp in
                RoundedRectangle(cornerRadius: TimelineLook.radius, style: .continuous).fill(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: TimelineLook.radius, style: .continuous)
                        .strokeBorder(Yap.caption, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .overlay(alignment: .leading) { ChipLabel(text: "Typing", symbol: "keyboard", color: Yap.label) }
                    .modifier(ChipChrome(selected: model.typingPopover == sp.startNs, grips: false))
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
            laneBackground(g, top: layout.cameraTop)
            laneHint(g, top: layout.cameraTop, lane: .camera, empty: model.layouts.isEmpty, text: "Click or drag to add a camera layout")
            ForEach(model.layouts) { l in
                rangeChip(g, key: l.id, span: TimeSpan(startNs: l.startNs, endNs: l.endNs), top: layout.cameraTop, fill: TimelineLook.camera,
                          title: (layoutModes.first { $0.value == l.mode }?.label ?? l.mode) + (l.enabled ? "" : " (off)"), sel: .layout(l.id), enabled: l.enabled)
            }
        }
    }

    private func highlightLane(_ g: TimelineGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            laneBackground(g, top: layout.highlightTop)
            laneHint(g, top: layout.highlightTop, lane: .highlight, empty: model.highlights.isEmpty, text: "Click or drag to add a mask")
            ForEach(model.highlights) { h in
                rangeChip(g, key: h.id, span: h.span, top: layout.highlightTop, fill: TimelineLook.regions,
                          title: TimelineChipText.maskTitle(h), sel: .highlight(h.id), enabled: h.enabled)
            }
        }
    }

    private func textLane(_ g: TimelineGeometry, top: CGFloat, kinds: [TextKind]) -> some View {
        ZStack(alignment: .topLeading) {
            laneBackground(g, top: top)
            ForEach(kinds.flatMap { model.textItems($0) }) { t in
                rangeChip(g, key: EditorModel.textKey(t), span: t.span, top: top, fill: t.kind == .caption ? TimelineLook.caption : TimelineLook.text,
                          title: t.text.replacingOccurrences(of: "\n", with: " "), sel: .text(t.kind, t.id),
                          labelColor: t.kind == .caption ? Yap.label : .white)
            }
        }
    }

    private func musicLane(_ g: TimelineGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            laneBackground(g, top: layout.musicTop)
            ForEach(model.music) { m in
                rangeChip(g, key: m.id, span: m.span, top: layout.musicTop, fill: TimelineLook.music, title: "♪ " + m.title, sel: .music(m.id))
            }
        }
    }

    private func cursorLane(_ g: TimelineGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            laneBackground(g, top: layout.cursorTop)
            ForEach(model.cursorHides, id: \.index) { h in
                rangeChip(g, key: EditorModel.cursorKey(h.index), span: h.span, top: layout.cursorTop, fill: TimelineLook.cursor,
                          title: "Cursor hidden", sel: .cursorHide(h.index), labelColor: Yap.label)
            }
        }
    }


    // MARK: gestures

    /// Scissors on a selected zoom, layout or highlight: split it at the click, unsnapped so it never lands on its own edge.
    private func cutSelected(at ns: Int64) {
        model.seek(toNs: ns, precise: true)
        model.splitContextAware()
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
                if drag == nil { drag = begin(at: v.startLocation, g); dragMoved = false }
                // A click is not a drag: nothing previews or snaps until the pointer actually moved.
                if !dragMoved { dragMoved = abs(v.translation.width) >= 3 || abs(v.translation.height) >= 3 }
                if !dragMoved, case .scrub = drag! {} else if !dragMoved { return }
                let ns = g.ns(forX: v.location.x)
                switch drag! {
                case .inert: break
                case .zoomCreate(let s): model.zoomCreatePreview = (min(s, ns), max(s, ns))
                case .scrub:
                    model.seek(toNs: model.snapped(ns, includePlayhead: false), precise: false)
                    model.scrubAudio(toNs: model.playheadNs, at: ProcessInfo.processInfo.systemUptime)
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
                case .laneCreate(let lane, let s):
                    model.laneCreatePreview = (lane, min(s, ns), max(s, ns))
                case .clipEdge(let id, let edge):
                    // The guide shows where the edge will land (clamped to the minimum length and the trimmed source).
                    model.snapGuideNs = model.trimPlan(clipID: id, edge: edge, targetNs: model.snapped(ns, includePlayhead: false))?.edgeNs
                }
            }
            .onEnded { v in
                switch drag {
                case .scrub: model.seek(toNs: model.playheadNs, precise: true); model.endAudioScrub()
                case .zoomMove(let id, _), .zoomStart(let id), .zoomEnd(let id): model.commitZoomPreview(id: id)
                case .rangeMove(let k, _), .rangeStart(let k), .rangeEnd(let k): model.commitRange(key: k)
                case .laneCreate(let lane, let s):
                    model.laneCreatePreview = nil
                    let end: Int64? = dragMoved ? model.snapped(g.ns(forX: v.location.x), includePlayhead: false) : nil
                    if lane == .camera { model.addLayout(fromNs: s, toNs: end) } else { model.addHighlight(fromNs: s, toNs: end) }
                case .clipEdge(let id, let edge):
                    if dragMoved { model.trimClipEdge(clipID: id, start: edge == .start, toNs: model.snapped(g.ns(forX: v.location.x), includePlayhead: false)) }
                    else { model.seek(toNs: model.snapped(g.ns(forX: v.location.x), includePlayhead: false), precise: true) }
                case .zoomCreate(let s):
                    model.zoomCreatePreview = nil
                    if dragMoved { model.addZoom(fromNs: s, toNs: model.snapped(g.ns(forX: v.location.x), includePlayhead: false)) } else { model.addZoom(fromNs: s) }
                case .inert, nil: break
                }
                drag = nil
                model.snapGuideNs = nil
            }
    }

    /// Snapshot of the timeline for one pointer position, shared by left-click routing and the context menu.
    private func clickInput(at p: CGPoint, _ g: TimelineGeometry, multiSelect: Bool) -> TimelineClick.Input {
        var items: [LaneHitTest.Item] = []
        func add(_ key: String, _ span: TimeSpan, _ top: CGFloat, _ sel: EditorSelection) { items.append(.init(key: key, span: span, top: top, tag: sel)) }
        if model.hasCamera { for l in model.layouts { add(l.id, TimeSpan(startNs: l.startNs, endNs: l.endNs), layout.cameraTop, .layout(l.id)) } }
        for t in model.allText { add(EditorModel.textKey(t), t.span, t.kind == .caption ? layout.captionTop : layout.textTop, .text(t.kind, t.id)) }
        for m in model.music { add(m.id, m.span, layout.musicTop, .music(m.id)) }
        for h in model.highlights { add(h.id, h.span, layout.highlightTop, .highlight(h.id)) }
        for h in model.cursorHides { add(EditorModel.cursorKey(h.index), h.span, layout.cursorTop, .cursorHide(h.index)) }
        return TimelineClick.Input(
            point: p, layout: layout, geometry: g, cutTool: model.cutToolActive, multiSelect: multiSelect, durationNs: model.durationNs,
            zooms: model.zooms.map { z in let r = model.displayedRange(of: z); return (z.id, r.start, r.end) },
            rangeItems: items, rangePreview: model.zoomPreview,
            typing: model.typingSuggestions.map { ($0.startNs, $0.endNs) },
            clips: model.clipStarts().map { ($0.clip.id, $0.startNs, $0.startNs + $0.clip.timelineDurationNs) },
            cutMarkers: model.cutMarkers.map { ($0.atNs, CutMarker.label($0.removedNs)) })
    }

    /// Secondary click: select what is under the pointer, then show its menu.
    private func contextMenu(at p: CGPoint) -> NSMenu? {
        let g = model.geometry
        guard let target = TimelineClick.menuTarget(clickInput(at: p, g, multiSelect: false)) else { return nil }
        switch target {
        case .clip(let id, _): model.selection = .clip(id)
        case .zoom(let id): if !model.extraZoomSelection.contains(id) { model.extraZoomSelection = [] }; model.selection = .zoom(id)
        case .layout(let id): model.selection = .layout(id)
        case .highlight(let id): model.selection = .highlight(id)
        case .text(let k, let id): model.selection = .text(k, id)
        case .music(let id): model.selection = .music(id)
        case .cursorHide(let i): model.selection = .cursorHide(i)
        case .empty: break
        }
        let entries = TimelineMenu.entries(for: target, in: model)
        return entries.isEmpty ? nil : TimelineMenu.nsMenu(entries) { [model] in model.apply($0) }
    }

    private func begin(at p: CGPoint, _ g: TimelineGeometry) -> DragKind {
        if !(p.y >= layout.zoomTop && p.y < layout.lanesTop) { model.extraZoomSelection = [] }
        let flags = NSEvent.modifierFlags
        let input = clickInput(at: p, g, multiSelect: flags.contains(.shift) || flags.contains(.command))
        switch TimelineClick.decide(input) {
        case .scrub(let clip):
            model.selection = clip.map { .clip($0) } ?? .none
            if p.y >= layout.clipTop { model.seek(toNs: model.snapped(g.ns(forX: p.x), includePlayhead: false), precise: false) }
            return .scrub
        case .typingPopover(let ns): model.typingPopover = ns; return .inert
        case .rangeDrag(let key, let part, let sel):
            model.selection = sel
            switch part {
            case .start: return .rangeStart(key: key)
            case .end: return .rangeEnd(key: key)
            case .body(let off): return .rangeMove(key: key, grabOffsetNs: off)
            }
        case .rangeSelectOnly(let sel): model.selection = sel; return .inert
        case .rangeCut(let sel, let ns): model.selection = sel; cutSelected(at: ns); return .inert
        case .zoomCreate(let ns):
            model.selection = .none
            return .zoomCreate(startNs: model.snapped(ns, includePlayhead: false))
        case .zoomCut(let id, let ns):
            // Scissors on a zoom: split that zoom at the click (C does the same at the playhead).
            model.extraZoomSelection = []; model.selection = .zoom(id); cutSelected(at: ns); return .inert
        case .zoomToggleSelect(let id):
            // Multi-select: toggle membership; no drag.
            if case .zoom(let primary) = model.selection {
                if id == primary { model.selection = model.extraZoomSelection.first.map { .zoom($0) } ?? .none
                                   if let n = model.extraZoomSelection.first { model.extraZoomSelection.remove(n) } }
                else if model.extraZoomSelection.contains(id) { model.extraZoomSelection.remove(id) }
                else { model.extraZoomSelection.insert(id) }
            } else { model.selection = .zoom(id) }
            return .inert
        case .zoomDrag(let id, let part):
            model.extraZoomSelection = []; model.selection = .zoom(id)
            switch part {
            case .start: return .zoomStart(id: id)
            case .end: return .zoomEnd(id: id)
            case .move(let off): return .zoomMove(id: id, grabOffsetNs: off)
            }
        case .clipCut(let ns):
            // Scissors: a click on a clip splits it there (snapped to edit points).
            model.seek(toNs: model.snapped(ns, includePlayhead: false), precise: true)
            model.splitAtPlayhead()
            return .inert
        case .laneCreate(let lane, let ns): model.selection = .none; return .laneCreate(lane: lane, startNs: model.snapped(ns, includePlayhead: false))
        case .restoreCut(let ns): model.restoreCut(atNs: ns); return .inert
        case .clipEdge(let id, let edge): model.selection = .clip(id); return .clipEdge(id: id, edge: edge)
        case .nothing: return .inert
        }
    }
}

/// Quiet track names in their own column, each centred on its track (same tops as `TimelineLayout`).
private struct TrackNames: View {
    let layout: TimelineLayout

    var body: some View {
        ZStack(alignment: .topTrailing) {
            name("Video", top: layout.clipTop, height: TimelineLayout.clipTrackHeight)
            name("Zoom", top: layout.zoomTop, height: TimelineLayout.zoomTrackHeight)
            ForEach(layout.lanes, id: \.self) { lane in
                name(lane.title, top: layout.top(of: lane) ?? layout.lanesTop, height: TimelineLayout.laneHeight)
            }
        }
        .frame(width: TimelineLook.namesWidth, height: layout.totalHeight, alignment: .topTrailing)
        .padding(.trailing, TimelineLook.namesColumn - TimelineLook.namesWidth)
        .accessibilityHidden(true)
    }

    private func name(_ text: String, top: CGFloat, height: CGFloat) -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(Yap.faint).lineLimit(1)
            .frame(width: TimelineLook.namesWidth, height: height, alignment: .trailing)
            .offset(y: top)
    }
}

/// Text on an item: white, 10 pt semibold, an optional symbol; shown only where it fits whole (a cut-off label is noise).
private struct ChipLabel: View {
    let text: String
    var symbol: String?
    var color = Color.white

    var body: some View {
        ViewThatFits(in: .horizontal) {
            full
            Color.clear.frame(width: 0, height: 0)
        }
        .allowsHitTesting(false)
    }

    private var full: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(.system(size: 10, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .fixedSize()
    }
}

/// Selection, hover and trim grips of a timeline item: a white outline when selected, a step of brightness on hover
/// (fast in, soft out), white grips at both ends on hover or selection (the edges are the trim hit areas).
struct ChipChrome: ViewModifier {
    let selected: Bool
    var grips = true
    @State private var hover = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: TimelineLook.radius, style: .continuous)
        content
            .brightness(hover ? 0.06 : 0)
            .overlay { if selected { shape.strokeBorder(Color.white, lineWidth: 2) } }
            .modifier(TrimHandles(visible: grips && (selected || hover)))
            .clipShape(shape)
            .onHover { on in withAnimation(Yap.Motion.hover(on)) { hover = on } }
    }
}

/// Grips at both ends of a chip (white, no tint), visible while the pointer is over it or it is selected.
struct TrimHandles: ViewModifier {
    let visible: Bool
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .leading) { grip.padding(.leading, 3) }
            .overlay(alignment: .trailing) { grip.padding(.trailing, 3) }
    }
    private var grip: some View {
        Capsule().fill(Color.white).frame(width: 3, height: 14).opacity(visible ? 1 : 0).allowsHitTesting(false)
    }
}

/// Major ticks with timecodes (yellow) and four minor ticks between, after the lab: major 8 px, minor 4 px, labels
/// at least 70 pt apart (`TimelineGeometry.rulerStepSeconds`).
struct Ruler: View {
    let geometry: TimelineGeometry
    let width: CGFloat
    @Environment(\.displayScale) private var displayScale

    /// Whole seconds ("0:01") unless the label spacing needs a fraction ("0:01.5", "0:01.25" for very fine steps).
    static func label(_ t: Double, step: Double) -> String {
        let ns = Int64((t * 1e9).rounded())
        if step >= 1 { return formatTimecode(ns, showFraction: false) }
        let base = formatTimecode(ns - ns % 1_000_000_000, showFraction: false)
        let frac = Double(ns % 1_000_000_000) / 1e9
        let digits = step >= 0.1 ? 1 : 2
        return base + String(format: "%.\(digits)f", frac).dropFirst(1)      // "0.5" → ".5"
    }

    var body: some View {
        Canvas { ctx, size in
            let step = geometry.rulerStepSeconds()
            let minor = step / 5
            let maxT = Double(width) / geometry.pixelsPerSecond
            for i in 0...((maxT / minor).isFinite ? Int(min(max(maxT / minor, 0), 100_000)) : 0) {
                let t = Double(i) * minor
                let x = PixelGrid.lineEdge(t * geometry.pixelsPerSecond, scale: displayScale)
                if i % 5 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: size.height - 8, width: 1, height: 8)), with: .color(.white.opacity(0.4)))
                    ctx.draw(Text(Self.label(t, step: step)).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(Yap.technical),
                             at: CGPoint(x: x + 4, y: 8), anchor: .leading)
                } else if minor * geometry.pixelsPerSecond >= 6 {
                    ctx.fill(Path(CGRect(x: x, y: size.height - 4, width: 1, height: 4)), with: .color(.white.opacity(0.18)))
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
/// One physical pixel of white, on the pixel grid, with a small head in the ruler. White: red is for recording only.
struct PlayheadMarker: View {
    @ObservedObject var playhead: PlayheadState
    let model: EditorModel
    let geometry: TimelineGeometry
    let height: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let px = PixelGrid.pixel(scale: displayScale)
        let edge = PixelGrid.lineEdge(geometry.x(forNs: playhead.ns), scale: displayScale)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.white).frame(width: px, height: height)
            PlayheadHead().fill(Color.white)
                .frame(width: PlayheadHead.width, height: PlayheadHead.height)
                .offset(x: px / 2 - PlayheadHead.width / 2)
        }
        .frame(width: px, height: height, alignment: .topLeading)
        .offset(x: edge)
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

/// The playhead's head: a small downward triangle at the top of the ruler, its tip on the line.
struct PlayheadHead: Shape {
    static let width: CGFloat = 9, height: CGFloat = 6
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
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

    private var amount: Binding<Double> {
        let r = EditorModel.typingSpeedRange
        return Binding(get: { (speed - r.lowerBound) / (r.upperBound - r.lowerBound) },
                       set: { speed = ((r.lowerBound + $0 * (r.upperBound - r.lowerBound)) * 2).rounded() / 2 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard").foregroundStyle(Yap.caption)
                Text("Speed up typing").font(Yap.Font.label).foregroundStyle(Yap.title)
                Spacer()
                Text("\(formatTimecode(span.startNs, showFraction: false)) – \(formatTimecode(span.endNs, showFraction: false))").technical()
            }
            HStack(spacing: 8) {
                ValueSlider("Speed", value: String(format: "%.1fx", speed), amount: amount)
                    .accessibilityLabel("Typing speed").accessibilityValue(String(format: "%.1f times", speed))
                Button("Reset") { speed = EditorModel.defaultTypingSpeed }
                    .buttonStyle(.plain).font(Yap.Font.caption).foregroundStyle(Yap.caption)
                    .disabled(speed == EditorModel.defaultTypingSpeed).help("Back to \(String(format: "%.0fx", EditorModel.defaultTypingSpeed))")
            }
            HStack(spacing: 8) {
                Button("Apply") { model.typingSpeed = speed; model.applyTypingSuggestion(span) }.keyboardShortcut(.defaultAction)
                Button("Apply to all (\(model.typingSuggestions.count))") { model.typingSpeed = speed; model.applyAllTypingSuggestions() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .buttonStyle(CapsuleButtonStyle(.secondary, height: 28))
            HStack(spacing: 14) {
                Button("Remove suggestion") { model.dismissTypingSuggestion(span) }
                Button("Restore removed") { model.restoreTypingSuggestions() }
            }
            .buttonStyle(.plain).font(Yap.Font.caption).foregroundStyle(Yap.caption)
        }
        .padding(14).frame(width: 300)
        .onAppear { speed = model.typingSpeed }
    }
}
