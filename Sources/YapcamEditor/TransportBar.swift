import SwiftUI
import YapcamDesign

// The head row of the docked bottom panel: transport left (previous, play, next, time in yellow), the timeline tools,
// clip speed, volume and timeline zoom; the Timeline / Transcript switch right. Moved out of EditorChrome.swift.

/// Transport row. Standalone (`TransportBar(model:)`, the old place above the timeline) it shows transport and tools;
/// inside `BottomPanelView` it also gets the Timeline / Transcript switch and the transcript's "Cut" action.
struct TransportBar: View {
    @ObservedObject var model: EditorModel
    /// Words selected in the transcript panel; nil when the bar is not hosted by `BottomPanelView` (no switch then).
    var transcriptSelection: Binding<Set<String>>?
    static let height: CGFloat = 40

    init(model: EditorModel, transcriptSelection: Binding<Set<String>>? = nil) {
        self.model = model; self.transcriptSelection = transcriptSelection
    }

    private var hosted: Bool { transcriptSelection != nil }
    private var showsTimelineTools: Bool { !hosted || model.bottomPanel == .timeline }

    var body: some View {
        // Narrow panels drop the zoom slider for two buttons, then the tools' spacing; the transport never goes.
        ViewThatFits(in: .horizontal) {
            row(wideZoom: true)
            row(wideZoom: false)
        }
        .padding(.leading, 10).padding(.trailing, 8)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
    }

    private func row(wideZoom: Bool) -> some View {
        HStack(spacing: 10) {
            TransportControls(model: model, playhead: model.playhead)
            if showsTimelineTools { TimelineTools(model: model) }
            Spacer(minLength: 8)
            if showsTimelineTools {
                MediaSlots(model: model)
                LaneMenu(model: model)
                TimelineZoomControl(model: model, wide: wideZoom)
            }
            if let sel = transcriptSelection {
                if model.bottomPanel == .transcript && !sel.wrappedValue.isEmpty {
                    Button("Cut \(sel.wrappedValue.count) word\(sel.wrappedValue.count == 1 ? "" : "s")") {
                        model.deleteWords(ids: sel.wrappedValue); sel.wrappedValue = []
                    }
                    .buttonStyle(CapsuleButtonStyle(.secondary, height: 26))
                    .help("Cut the selected words out of the video (⌫)")
                }
                SegmentSwitch([(BottomPanel.timeline, "Timeline"), (.transcript, "Transcript")], selection: $model.bottomPanel)
                    .fixedSize()
            }
        }
    }
}

/// Previous edit point, play/pause, next edit point and the time. Only this observes the playhead, so playback
/// redraws the time and nothing else in the row.
private struct TransportControls: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var playhead: PlayheadState

    var body: some View {
        HStack(spacing: 4) {
            IconSlot("backward.end.fill", label: "Previous edit point", help: "Previous edit point (⌥←)") { model.jumpToEditPoint(forward: false) }
            Button { model.togglePlay() } label: { Image(systemName: playhead.isPlaying ? "pause.fill" : "play.fill") }
                .buttonStyle(CircleButtonStyle(size: 28))
                .help("Play / Pause (Space)").accessibilityLabel(playhead.isPlaying ? "Pause" : "Play")
            IconSlot("forward.end.fill", label: "Next edit point", help: "Next edit point (⌥→)") { model.jumpToEditPoint(forward: true) }
            HStack(spacing: 4) {
                Text(formatTimecode(playhead.ns)).technical()
                Text("/ " + formatTimecode(model.durationNs)).font(Yap.Font.technical).foregroundStyle(Yap.faint)
            }
            .lineLimit(1).fixedSize()
            .padding(.leading, 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Time")
            .accessibilityValue("\(formatTimecode(playhead.ns, showFraction: false)) of \(formatTimecode(model.durationNs, showFraction: false))")
        }
    }
}

/// Scissors, split, zoom, delete, snapping: icons on platters, the tools that stay on (scissors, magnet) brighter.
private struct TimelineTools: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 2) {
            IconSlot("scissors", label: "Cut tool", help: "Cut tool (hold ⌥): click a clip, zoom, layout or mask to split it there. C splits at the playhead",
                     active: model.cutToolActive) { model.cutToolActive.toggle() }
            IconSlot("rectangle.split.2x1", label: "Split at playhead", help: "Split at playhead (C)") { model.splitAtPlayhead() }
            IconSlot("plus.magnifyingglass", label: "Add zoom", help: "Add zoom at playhead (Z)") { model.addZoomAtPlayhead() }
            IconSlot("trash", label: "Delete selection", help: "Delete selection (⌫)") { model.deleteSelection() }
                .disabled(model.selection == .none)
            IconSlot("arrow.right.and.line.vertical.and.arrow.left", label: "Snapping", help: "Snapping", active: model.snappingEnabled) { model.snappingEnabled.toggle() }
        }
    }
}

/// Clip speed (value in yellow) and volume, each opening its small menu.
private struct MediaSlots: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 2) {
            ValueSlot(model.speedTargetClip.map { speedText($0.speed) } ?? "1x", label: "Clip speed", help: "Clip speed (S)") { model.speedMenuVisible = true }
                .popover(isPresented: $model.speedMenuVisible) { SpeedMenu(model: model) }
            IconSlot("speaker.wave.2", label: "Volume", help: "Volume (V; ⌃V for system audio)") {
                model.volumeMenuSystem = false; model.volumeMenuVisible = true
            }
            .popover(isPresented: $model.volumeMenuVisible) { VolumeMenu(model: model) }
        }
    }
}

/// Timeline zoom on a log scale: a thin slider between the two magnifiers, or just the two as buttons when narrow.
private struct TimelineZoomControl: View {
    @ObservedObject var model: EditorModel
    let wide: Bool

    private var zoom: Binding<Double> {
        Binding(get: { log2(model.geometry.pixelsPerSecond) },
                set: { model.geometry = TimelineGeometry(pixelsPerSecond: pow(2, $0)) })
    }
    private static let range = log2(TimelineGeometry.minPPS)...log2(TimelineGeometry.maxPPS)

    var body: some View {
        if wide {
            HStack(spacing: 6) {
                Image(systemName: "minus.magnifyingglass").font(.system(size: 11)).foregroundStyle(Yap.faint)
                HairSlider(value: zoom, in: Self.range, accessibilityStep: 0.5)
                    .frame(width: 90).accessibilityLabel("Timeline zoom")
                Image(systemName: "plus.magnifyingglass").font(.system(size: 11)).foregroundStyle(Yap.faint)
            }
        } else {
            HStack(spacing: 2) {
                IconSlot("minus.magnifyingglass", label: "Zoom timeline out") { step(-0.5) }
                IconSlot("plus.magnifyingglass", label: "Zoom timeline in") { step(0.5) }
            }
        }
    }

    private func step(_ d: Double) {
        zoom.wrappedValue = min(max(zoom.wrappedValue + d, Self.range.lowerBound), Self.range.upperBound)
    }
}

func speedText(_ v: Double) -> String { v == v.rounded() ? "\(Int(v))x" : String(format: "%gx", v) }

/// One choice in the small speed / volume menus: title, checkmark on the current one, platter on hover.
private struct MenuChoice: View {
    let title: String
    let checked: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(Yap.Font.body).foregroundStyle(hover || checked ? Yap.title : Yap.label)
                Spacer()
                if checked { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Yap.title) }
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(Platter(active: false, hover: hover, radius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

/// S: the reference's fixed speed list for the clip under the playhead (or the selected clip), plus "apply to all".
struct SpeedMenu: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let current = model.speedTargetClip?.speed
        VStack(alignment: .leading, spacing: 1) {
            Text("Clip speed").font(Yap.Font.caption).foregroundStyle(Yap.caption).padding(.horizontal, 8).padding(.bottom, 4)
            ForEach(clipSpeedOptions, id: \.self) { v in
                MenuChoice(title: speedText(v), checked: current == v) { model.setSpeedOfTarget(v); dismiss() }
            }
            Hairline(axis: .horizontal, opacity: 0.12).padding(.vertical, 4)
            MenuChoice(title: "Apply speed to all clips", checked: false) { if let c = current { model.applySpeedToAll(c) }; dismiss() }
                .disabled(current == nil).opacity(current == nil ? 0.4 : 1)
        }
        .padding(8).frame(width: 200)
    }
}

/// V / ⌃V: microphone or system-audio volume in 10 % steps (0 mutes).
struct VolumeMenu: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let system = model.volumeMenuSystem
        let current = model.volumePercent(system: system)
        VStack(alignment: .leading, spacing: 1) {
            SegmentSwitch([(false, "Microphone"), (true, "System audio")], selection: $model.volumeMenuSystem, height: 24)
                .frame(maxWidth: .infinity).padding(.bottom, 6)
            ForEach(Array(stride(from: 100, through: 0, by: -10)), id: \.self) { p in
                MenuChoice(title: p == 0 ? "Muted" : "\(p)%", checked: abs(current - p) < 5) { model.setVolume(percent: p, system: system); dismiss() }
            }
        }
        .padding(8).frame(width: 220)
    }
}
