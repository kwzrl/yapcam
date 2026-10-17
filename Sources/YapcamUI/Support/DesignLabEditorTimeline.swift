import AppKit
import SwiftUI
import YapcamDesign

// The timeline on the window ground (no glass), after today's editor (TimelineView.swift, TimelineGeometry.swift):
// a fine ruler with major and minor ticks, a pixel-exact 1-px playhead with a small head in the ruler, the clip
// track with its waveform, the zoom track, then only the lanes that hold something, each with a quiet name.
// Colours stay ours: yellow for timecodes, content colours on the items, white for the playhead.

/// Docked at the bottom, from the left window edge to the inspector: a head row (transport left, over the track
/// names; the Timeline / Transcript switch right), then the ruler and the tracks, or the transcript.
struct TimelineArea: View {
    @Bindable var mock: EditorMock

    var body: some View {
        VStack(spacing: 0) {
            head
            Group {
                if mock.lower == .timeline { TimelineTracks(mock: mock) } else { TranscriptView(mock: mock) }
            }
            .frame(height: TimelineMetrics.tracksHeight(lanes: mock.lanes.count))
        }
        .background(Yap.dock)
    }

    private var head: some View {
        HStack(spacing: 10) {
            transport
            Spacer()
            if mock.lower == .transcript && !mock.selectedWords.isEmpty {
                Button("Cut \(mock.selectedWords.count) words") { mock.cutSelection() }
                    .buttonStyle(CapsuleButtonStyle(.secondary, height: 26))
            }
            SegmentSwitch([(EditorMock.Lower.timeline, "Timeline"), (.transcript, "Transcript")], selection: $mock.lower)
        }
        .padding(.leading, 10).padding(.trailing, 8)
        .frame(height: TimelineMetrics.headHeight)
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button { mock.playing.toggle() } label: { Image(systemName: mock.playing ? "pause.fill" : "play.fill") }
                .buttonStyle(CircleButtonStyle(size: 28))
                .accessibilityLabel(mock.playing ? "Pause" : "Play")
            HStack(spacing: 4) {
                Text(EditorMock.timecode(mock.time, fraction: true)).technical()
                Text("/ " + EditorMock.timecode(EditorMock.duration, fraction: true)).font(Yap.Font.technical).foregroundStyle(Yap.faint)
            }
        }
    }
}

/// Heights after TimelineLayout in today's editor.
enum TimelineMetrics {
    static let ruler: CGFloat = 24
    static let clip: CGFloat = 56
    static let zoom: CGFloat = 38
    static let lane: CGFloat = 28
    static let gap: CGFloat = 6
    static let names: CGFloat = 64
    static let headHeight: CGFloat = 40

    static func tracksHeight(lanes: Int) -> CGFloat {
        ruler + gap + clip + gap + zoom + gap + CGFloat(lanes) * (lane + gap) + 8
    }
}

enum MockLane: String { case camera = "Camera", graphics = "Graphics", captions = "Captions" }

private struct TimelineTracks: View {
    @Bindable var mock: EditorMock

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            names
            GeometryReader { geo in
                let px = geo.size.width / EditorMock.duration
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: TimelineMetrics.gap) {
                        RulerTrack(mock: mock, px: px)
                        ClipTrack(mock: mock, px: px)
                        ZoomTrack(mock: mock, px: px)
                        ForEach(mock.lanes, id: \.self) { lane in OverlayLane(mock: mock, lane: lane, px: px) }
                    }
                    Playhead(x: mock.time * px)
                }
            }
            .padding(.trailing, 12)
        }
    }

    /// Quiet track names in their own column, so items never cover them.
    private var names: some View {
        VStack(alignment: .trailing, spacing: TimelineMetrics.gap) {
            Color.clear.frame(height: TimelineMetrics.ruler)
            name("Video", TimelineMetrics.clip)
            name("Zoom", TimelineMetrics.zoom)
            ForEach(mock.lanes, id: \.self) { name($0.rawValue, TimelineMetrics.lane) }
        }
        .frame(width: TimelineMetrics.names)
        .padding(.trailing, 8)
    }

    private func name(_ text: String, _ height: CGFloat) -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(Yap.faint)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .trailing)
    }
}

/// 1 physical pixel, snapped to the pixel grid; the head sits in the ruler. White: red is for recording only.
private struct Playhead: View {
    let x: CGFloat
    @Environment(\.displayScale) private var scale

    var body: some View {
        let px = 1 / scale, snapped = (x * scale).rounded() / scale
        ZStack(alignment: .top) {
            Rectangle().fill(Color.white).frame(width: px)
            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 9)).foregroundStyle(Color.white).offset(y: -1)
        }
        .frame(width: 12, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .offset(x: snapped - 6)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Major ticks with timecodes (yellow) and four minor ticks between; markers on the ruler; click or drag to scrub.
private struct RulerTrack: View {
    @Bindable var mock: EditorMock
    let px: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in draw(ctx, size) }
            ForEach(EditorMock.markers, id: \.self) { m in
                Image(systemName: "flag.fill").font(.system(size: 8)).foregroundStyle(Yap.label)
                    .offset(x: m * px + 2, y: 13).help("Marker at \(EditorMock.timecode(m))")
            }
        }
        .frame(height: TimelineMetrics.ruler)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            mock.time = min(max(g.location.x / px, 0), EditorMock.duration)
        })
    }

    /// Smallest nice step whose labels stay at least 70 pt apart (TimelineGeometry.rulerStepSeconds).
    private var step: Double {
        [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300].first { $0 * px >= 70 } ?? 600
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let minor = step / 5
        let count = Int(EditorMock.duration / minor)
        for i in 0...count {
            let t = Double(i) * minor, x = (t * px).rounded()
            if i % 5 == 0 {
                ctx.fill(Path(CGRect(x: x, y: size.height - 8, width: 1, height: 8)), with: .color(.white.opacity(0.4)))
                let label = Text(EditorMock.timecode(t)).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(Yap.technical)
                ctx.draw(label, at: CGPoint(x: x + 4, y: 8), anchor: .leading)
            } else if minor * px >= 6 {
                ctx.fill(Path(CGRect(x: x, y: size.height - 4, width: 1, height: 4)), with: .color(.white.opacity(0.18)))
            }
        }
    }
}

/// Lane ground: a faint step of brightness, so empty time reads as track.
private struct LaneGround: View {
    let height: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.04)).frame(height: height)
    }
}

/// An item on a track: content colour, white outline when selected, dashed while only suggested.
private struct TrackItem<Label: View>: View {
    let start: Double
    let end: Double
    let px: CGFloat
    let height: CGFloat
    let fill: AnyShapeStyle
    var selected = false
    var dashed = false
    /// The microphone's waveform inside the item (clips).
    var waveform = false
    var labelAlignment = Alignment.leading
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        shape.fill(fill)
            .overlay { if dashed { shape.strokeBorder(Yap.zoom, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])) } }
            .overlay { if waveform { Waveform(offset: start * px).opacity(0.28) } }
            .overlay(alignment: labelAlignment) {
                // Only where it fits whole: a cut-off label reads as noise.
                ViewThatFits(in: .horizontal) { label.fixedSize(); Color.clear.frame(width: 0, height: 0) }
            }
            .overlay { if selected { shape.strokeBorder(Color.white, lineWidth: 2) } }
            .overlay(alignment: .leading) { if selected || hover { grips } }
            .brightness(hover ? 0.06 : 0)
            .frame(width: max((end - start) * px - 1, 4), height: height)
            .clipShape(shape)
            .offset(x: start * px)
            .onHover { hover = $0 }
            .onTapGesture(perform: action)
    }

    /// Trim grips at both ends, shown on hover and selection (as in today's editor).
    private var grips: some View {
        HStack {
            Capsule().fill(Color.white).frame(width: 3, height: 14)
            Spacer()
            Capsule().fill(Color.white).frame(width: 3, height: 14)
        }
        .padding(.horizontal, 3)
        .allowsHitTesting(false)
    }
}

private struct ItemLabel: View {
    let text: String
    var symbol: String?
    var color = Color.white
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(.system(size: 10, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
    }
}

private struct ClipTrack: View {
    @Bindable var mock: EditorMock
    let px: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(EditorMock.clips.enumerated()), id: \.offset) { i, c in
                TrackItem(start: c.start, end: c.end, px: px, height: TimelineMetrics.clip,
                          fill: AnyShapeStyle(LinearGradient(colors: [Yap.clipTop, Yap.clipBottom], startPoint: .top, endPoint: .bottom)),
                          selected: mock.selection == .clip(i), waveform: true, labelAlignment: .topLeading,
                          action: { mock.jump(to: c.start, select: .clip(i)) }) {
                    clipFace(c)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: TimelineMetrics.clip, maxHeight: TimelineMetrics.clip, alignment: .leading)
    }

    /// The length on a small dark label (today's clip track).
    private func clipFace(_ c: MockSpan) -> some View {
        Text(String(format: "%.0fs · 1×", c.end - c.start)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.black.opacity(0.42)))
            .padding(4)
    }
}

private struct Waveform: View {
    let offset: CGFloat
    var body: some View {
        Canvas { ctx, size in
            let first = Int(offset / 3)
            for i in 0..<max(Int(size.width / 3), 1) {
                let h = max(size.height * 0.7 * Self.level(Double(first + i)), 2)
                let r = CGRect(x: CGFloat(i) * 3, y: (size.height - h) / 2 + 6, width: 1.5, height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: 0.75), with: .color(.black))
            }
        }
        .allowsHitTesting(false)
    }

    private static func level(_ x: Double) -> CGFloat {
        let slow = sin(x * 0.37) * 0.6, swell = sin(x * 0.11 + 1) * 0.3, grain = sin(x * 1.7) * 0.1
        return CGFloat(abs(slow + swell + grain))
    }
}

private struct ZoomTrack: View {
    @Bindable var mock: EditorMock
    let px: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            LaneGround(height: TimelineMetrics.zoom)
            ForEach(Array(mock.zoomSpans.enumerated()), id: \.offset) { i, z in
                TrackItem(start: z.start, end: z.end, px: px, height: TimelineMetrics.zoom - 4, fill: AnyShapeStyle(Yap.zoom),
                          selected: mock.selection == .zoom(i), action: { mock.jump(to: z.start, select: .zoom(i)) }) {
                    ItemLabel(text: String(format: "%.1f×", z.scale), symbol: "plus.magnifyingglass")
                }
            }
            if mock.agentOn && mock.review == .pending { suggestion }
        }
        .frame(maxWidth: .infinity, minHeight: TimelineMetrics.zoom, maxHeight: TimelineMetrics.zoom, alignment: .leading)
    }

    /// The agent's suggestion lies dashed on the track until accepted; accept or reject right beside it.
    private var suggestion: some View {
        let s = EditorMock.suggestion
        return HStack(spacing: 4) {
            TrackItem(start: 0, end: s.end - s.start, px: px, height: TimelineMetrics.zoom - 4, fill: AnyShapeStyle(Yap.zoom.opacity(0.16)),
                      selected: mock.selection == .suggestion, dashed: true, action: { mock.jump(to: s.start, select: .suggestion) }) {
                ItemLabel(text: String(format: "%.1f×", s.scale), symbol: "plus.magnifyingglass", color: Yap.label)
            }
            mini("checkmark", "Accept suggestion") { mock.accept() }
            mini("xmark", "Reject suggestion") { mock.reject() }
        }
        .offset(x: s.start * px)
    }

    private func mini(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(CircleButtonStyle(size: 22))
            .help(label).accessibilityLabel(label)
    }
}

private struct OverlayLane: View {
    @Bindable var mock: EditorMock
    let lane: MockLane
    let px: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            LaneGround(height: TimelineMetrics.lane)
            switch lane {
            case .camera: camera
            case .graphics: graphics
            case .captions: captions
            }
        }
        .frame(maxWidth: .infinity, minHeight: TimelineMetrics.lane, maxHeight: TimelineMetrics.lane, alignment: .leading)
    }

    private var camera: some View {
        ForEach(Array(EditorMock.layouts.enumerated()), id: \.offset) { i, l in
            TrackItem(start: l.start, end: l.end, px: px, height: TimelineMetrics.lane - 4, fill: AnyShapeStyle(MockLook.camera),
                      selected: mock.selection == .layout(i), action: { mock.jump(to: l.start, select: .layout(i)) }) {
                ItemLabel(text: l.title)
            }
        }
    }

    private var graphics: some View {
        ForEach(mock.blocks) { b in
            TrackItem(start: b.start, end: b.end, px: px, height: TimelineMetrics.lane - 4, fill: AnyShapeStyle(MockLook.graphics),
                      selected: mock.selection == .block(b.id), action: { mock.jump(to: b.start, select: .block(b.id)) }) {
                ItemLabel(text: b.kind.label)
            }
        }
    }

    private var captions: some View {
        ForEach(Array(EditorMock.captions.enumerated()), id: \.offset) { _, c in
            TrackItem(start: c.start, end: c.end, px: px, height: TimelineMetrics.lane - 4, fill: AnyShapeStyle(Color.white.opacity(0.16)),
                      action: { mock.jump(to: c.start); mock.show(.captions) }) { EmptyView() }
        }
    }
}

// MARK: - Transcript

/// The second view of the timeline: select words and press Delete to cut; filler words are dotted.
private struct TranscriptView: View {
    @Bindable var mock: EditorMock
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(EditorMock.paragraphs, id: \.time) { p in paragraph(p.time, p.words) }
            }
            .padding(.leading, TimelineMetrics.names - 28).padding(.trailing, 16).padding(.vertical, 12)
        }
        .scrollIndicators(.never)
        .focusable().focusEffectDisabled().focused($focused)
        .onDeleteCommand { mock.cutSelection() }
        .onAppear { focused = true }
    }

    private func paragraph(_ t: Double, _ words: [MockWord]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button { mock.jump(to: t) } label: { Text(EditorMock.timecode(t)).technical() }
                .buttonStyle(.plain).frame(width: 36, alignment: .leading)
            FlowLayout {
                ForEach(words) { w in WordChip(mock: mock, word: w) }
            }
        }
    }
}

private struct WordChip: View {
    @Bindable var mock: EditorMock
    let word: MockWord
    @State private var hover = false

    var body: some View {
        let selected = mock.selectedWords.contains(word.id), cut = mock.cutWords.contains(word.id)
        Text(word.text)
            .font(.system(size: 14))
            .foregroundStyle(cut ? Yap.faint : (word.filler ? Yap.caption : Yap.label))
            .strikethrough(cut, color: Yap.faint)
            .underline(word.filler && !cut, pattern: .dot, color: Yap.caption)
            .padding(.horizontal, 2).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.24 : (hover ? 0.08 : 0))))
            .onHover { hover = $0 }
            .onTapGesture { mock.tapWord(word.id, extend: NSEvent.modifierFlags.contains(.shift)) }
            .help(word.filler ? "Filler word" : "")
    }
}

/// Lays words out in lines like text.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 0
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? 600, subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews)
        for (v, p) in zip(subviews, rows.points) {
            v.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += line + lineSpacing; line = 0 }
            points.append(CGPoint(x: x, y: y))
            x += s.width + spacing; widest = max(widest, x); line = max(line, s.height)
        }
        return (points, widest, y + line)
    }
}
