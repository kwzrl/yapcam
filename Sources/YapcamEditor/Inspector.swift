import SwiftUI
import UniformTypeIdentifiers
import YapcamCore
import YapcamDesign

// MARK: inspector

/// Output aspect ratios, as in the reference: Auto (recording plus padding), 16:9, 1:1, 4:3, 9:16, 3:4, 4:5.
public enum AspectPreset: String, CaseIterable {
    case auto = "source", wide = "16:9", square = "1:1", classic = "4:3", vertical = "9:16", tall = "3:4", portrait = "4:5"
    var label: String {
        switch self {
        case .auto: "Auto"; case .wide: "Wide 16:9"; case .square: "Square 1:1"; case .classic: "Classic 4:3"
        case .vertical: "Vertical 9:16"; case .tall: "Tall 3:4"; case .portrait: "Portrait 4:5"
        }
    }
    var hint: String {
        switch self {
        case .auto: "Fits the recording plus padding"; case .wide: "YouTube, presentations"; case .square: "Social posts"
        case .classic: "Older screens, slides"; case .vertical: "Stories, Reels, Shorts"; case .tall: "Tall feed posts"; case .portrait: "Instagram portrait"
        }
    }
    /// Output size to store with the aspect (height sets the export height); nil keeps the current size (Auto).
    var outputSize: [Double]? {
        switch self {
        case .auto: nil; case .wide: [1920, 1080]; case .square: [1080, 1080]; case .classic: [1440, 1080]
        case .vertical: [1080, 1920]; case .tall: [1080, 1440]; case .portrait: [1080, 1350]
        }
    }
}

public enum InspectorSection: String, CaseIterable, Identifiable {
    case background, cursor, cameraLayout, cameraStyle, captions, transcript, audio, keys, animations, extras
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .background: "Background"; case .cursor: "Cursor"; case .cameraLayout: "Camera layout"; case .cameraStyle: "Camera style"
        case .captions: "Captions"; case .transcript: "Edit by transcript"; case .audio: "Audio"; case .keys: "Keyboard shortcuts"
        case .animations: "Animations"; case .extras: "Text, regions & intro/outro"
        }
    }
    public var symbol: String {
        switch self {
        case .background: "photo.on.rectangle.angled"; case .cursor: "cursorarrow"; case .cameraLayout: "rectangle.inset.filled.and.person.filled"
        case .cameraStyle: "person.crop.rectangle"; case .captions: "captions.bubble"; case .transcript: "text.quote"
        case .audio: "speaker.wave.2"; case .keys: "command"; case .animations: "point.topleft.down.curvedto.point.bottomright.up"
        case .extras: "textformat"
        }
    }
    /// ⌘ digit that selects the section (1…9, then 0).
    public var shortcutDigit: Character { Self.digits[Self.allCases.firstIndex(of: self)!] }
    private static let digits: [Character] = Array("1234567890")
    /// One short line shown in the panel (and the rail tooltip) when the recording has no input for this section.
    public var unavailableReason: String {
        switch self {
        case .cursor: "This recording has no mouse data."
        case .cameraLayout, .cameraStyle: "This recording has no camera."
        case .captions, .transcript: "This recording has no microphone."
        case .keys: "No keystrokes were recorded. Turn on “Record keystrokes” before recording."
        default: ""
        }
    }
    @MainActor public func isAvailable(in m: EditorModel) -> Bool {
        switch self {
        case .background, .audio, .animations, .extras: true
        case .cursor: m.hasMouseData
        case .cameraLayout: m.hasCamera
        case .cameraStyle: m.hasCamera && m.bool("camera.visible", default: true)
        case .captions, .transcript: m.hasMic
        case .keys: m.hasKeystrokes
        }
    }
}

extension EditorModel {
    public var availableSections: [InspectorSection] { InspectorSection.allCases.filter { $0.isAvailable(in: self) } }
    /// ⌘ digit handler: selects the section bound to `digit` when it is available (and leaves any item inspector).
    @discardableResult public func selectInspector(digit: Character) -> Bool {
        guard let s = InspectorSection.allCases.first(where: { $0.shortcutDigit == digit }), s.isAvailable(in: self) else { return false }
        showSection(s); return true
    }
    public func showSection(_ s: InspectorSection) {
        if case .zoom = selection { selection = .none } else if case .clip = selection { selection = .none }
        inspectorSection = s
    }
    /// A selected zoom or clip replaces the section with that item's settings.
    var showsItemInspector: Bool {
        switch selection { case .zoom, .clip: true; default: false }
    }
}

/// Icon rail at the inspector's left edge: one slot per section, the open one brighter. Sections without input stay
/// reachable but dimmed (they explain why).
struct InspectorRail: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(spacing: 2) {
            ForEach(InspectorSection.allCases) { s in slot(s) }
            Spacer(minLength: 0)
        }
        .padding(Yap.Grid.inset)
        .frame(width: Yap.Inspector.rail)
    }

    private func slot(_ s: InspectorSection) -> some View {
        let available = s.isAvailable(in: model)
        let help = available ? "\(s.title) (⌘\(String(s.shortcutDigit)))" : "\(s.title): \(s.unavailableReason)"
        return SlotButton(symbol: s.symbol, label: s.title, help: help,
                          active: model.inspectorSection == s && !model.showsItemInspector, dim: !available, compact: true) {
            model.showSection(s)
        }
    }
}

/// The inspector inside the docked right column: rail, hairline, the section (or the selected zoom/clip). No card, no
/// background of its own; the column it sits in is `Yap.dock`.
struct InspectorView: View {
    @ObservedObject var model: EditorModel
    private let initialSection: InspectorSection?
    /// Width of the docked column: rail plus the 300-pt content column.
    static let width = Yap.Inspector.width
    init(model: EditorModel, initialSection: InspectorSection? = nil) { self.model = model; self.initialSection = initialSection }

    private var section: InspectorSection { model.inspectorSection }
    private var scrollID: String {
        switch model.selection { case .zoom: "zoom"; case .clip: "clip"; default: section.rawValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            InspectorRail(model: model)
            Hairline(axis: .vertical, opacity: Yap.dockHairline)
            ScrollView {
                content
                    .padding(.horizontal, Yap.Inspector.gutter).padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .id(scrollID)
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .tint(Yap.label)
        .onAppear { if let initialSection { model.inspectorSection = initialSection } }
        .onChange(of: model.selection) { _, s in follow(s) }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.showsItemInspector {
                ItemInspector(model: model)
            } else {
                InspectorHeader(title: section.title)
                SectionBody(model: model, section: section)
            }
        }
    }

    /// Selecting an item on the timeline opens the section that edits it.
    private func follow(_ s: EditorSelection) {
        switch s {
        case .layout: model.inspectorSection = .cameraLayout
        case .cursorHide: model.inspectorSection = .cursor
        case .highlight, .text(.annotation, _), .text(.reaction, _): model.inspectorSection = .extras
        case .text(.caption, _): model.inspectorSection = .captions
        case .music: model.inspectorSection = .audio
        case .zoom, .clip, .none: break
        }
    }
}

/// Title of the column: section name, or the selected item with its time in yellow and a Done slot.
struct InspectorHeader: View {
    let title: String
    var detail = ""
    var done: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Yap.title).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if !detail.isEmpty { Text(detail).technical().lineLimit(1).minimumScaleFactor(0.8) }
            Spacer(minLength: 0)
            if let done {
                SlotButton(symbol: "xmark", label: "Done", help: "Back to the section (Esc)", active: false, compact: true, action: done)
            }
        }
        .frame(height: Yap.Grid.cell + 4)
    }
}

/// The selected item of a section (layout, hidden cursor part, region, text, caption, music) on top of the section's
/// own settings: its name and time, a Done slot, then its controls.
struct SelectedItemGroup<Content: View>: View {
    @ObservedObject var model: EditorModel
    let title: String
    let span: TimeSpan
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title).font(Yap.Font.label).foregroundStyle(Yap.title).lineLimit(1)
                Text("\(formatTimecode(span.startNs)) – \(formatTimecode(span.endNs))").technical().lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                InspectorIconButton(symbol: "xmark", label: "Done") { model.selection = .none }
                    .help("Deselect (Esc)")
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) { Hairline(axis: .horizontal, opacity: Yap.dockHairline) }
        .padding(.bottom, 16)
    }
}

/// One section's settings, or why the recording has none.
private struct SectionBody: View {
    @ObservedObject var model: EditorModel
    let section: InspectorSection

    var body: some View {
        if !section.isAvailable(in: model) {
            InspectorNote(section.unavailableReason, symbol: "info.circle")
        } else {
            switch section {
            case .background: BackgroundPanel(model: model)
            case .cursor: CursorSection(model: model)
            case .cameraLayout: CameraLayoutSection(model: model)
            case .cameraStyle: CameraStylePanel(model: model)
            case .captions: CaptionSection(model: model)
            case .transcript: TranscriptSettingsSection(model: model)
            case .audio: AudioSection(model: model)
            case .keys: KeysSection(model: model)
            case .animations: AnimationsSection(model: model)
            case .extras: ExtrasSection(model: model)
            }
        }
    }
}

// MARK: selected zoom / clip

private struct ItemInspector: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        if let z = model.selectedZoom {
            ZoomInspector(model: model, zoom: z)
        } else if case .clip(let id) = model.selection, let c = model.clips.first(where: { $0.id == id }) {
            ClipInspector(model: model, clip: c)
        } else {
            InspectorHeader(title: "Nothing selected", done: { model.selection = .none })
        }
    }
}

struct ZoomInspector: View {
    @ObservedObject var model: EditorModel
    let zoom: TimelineZoom

    var body: some View {
        let z = zoom
        VStack(alignment: .leading, spacing: 0) {
            InspectorHeader(title: z.mode == .auto ? "Zoom (automatic)" : "Zoom",
                            detail: "\(formatTimecode(z.startNs)) – \(formatTimecode(z.endNs))", done: { model.selection = .none })
            InspectorGroup(first: true) { basics(z) }
            InspectorGroup { actions(z) }
        }
    }

    @ViewBuilder private func basics(_ z: TimelineZoom) -> some View {
        SwitchRow("Disable zoom", isOn: Binding(get: { !z.enabled }, set: { model.setZoomEnabled(id: z.id, !$0) }))
        if model.hasMouseData || z.mode == .auto {
            ChoiceRow("Type", selection: Binding(get: { z.mode }, set: { model.setZoomMode(id: z.id, $0) }),
                      options: [("Auto", TimelineZoom.Mode.auto), ("Manual", TimelineZoom.Mode.manual)])
            InspectorNote(z.mode == .auto ? "Follows your clicks and keeps the cursor in view." : "Pick the spot to zoom into.")
        }
        ChoiceRow("Style", selection: Binding(get: { z.lens != nil }, set: { model.setZoomLens(id: z.id, $0 ? ZoomLensParams() : nil) }),
                  options: [("Classic", false), ("Glass loupe", true)])
        if let l = z.lens { ZoomLensRows(model: model, zoomID: z.id, lens: l) }
        ZoomScaleRow(model: model, zoom: z)
        if z.mode == .manual && model.project is CoreEditingProject { ZoomTargetThumbnail(model: model, zoom: z) }
        InspectorInfo("Focus", String(format: "%.0f %%, %.0f %%", z.focusX * 100, z.focusY * 100))
        InspectorNote("Click in the preview or drag the dot above to set the focus point.")
        SwitchRow("Instant animation", isOn: Binding(get: { z.easeInNs == 0 && z.easeOutNs == 0 },
                                                      set: { model.setZoomEase(id: z.id, inNs: $0 ? 0 : 300_000_000, outNs: $0 ? 0 : 300_000_000) }))
    }

    @ViewBuilder private func actions(_ z: TimelineZoom) -> some View {
        InspectorAction("Use for new zooms") { model.useZoomForNewZooms(id: z.id) }
            .help("New zooms start with this level")
        InspectorAction("Apply this level to all other zooms") { model.applyZoomLevelToAll() }.disabled(model.zooms.count < 2)
        HStack(spacing: 6) {
            InspectorAction("Duplicate") { model.duplicateSelectedZoom() }
            InspectorAction("Delete zoom", symbol: "trash") { model.deleteSelection() }
        }
        InspectorNote("Keys: A auto · M manual · D disable · ⌘D duplicate · 1–9 level · 0 default · = / − step · ⌫ remove")
    }
}

struct ClipInspector: View {
    @ObservedObject var model: EditorModel
    let clip: TimelineClip

    var body: some View {
        let c = clip
        VStack(alignment: .leading, spacing: 0) {
            InspectorHeader(title: "Clip", done: { model.selection = .none })
            InspectorGroup(first: true) { basics(c) }
            InspectorGroup { actions(c) }
        }
    }

    @ViewBuilder private func basics(_ c: TimelineClip) -> some View {
        ChoiceRow("Speed", selection: Binding(get: { c.speed }, set: { model.setSpeed(clipID: c.id, $0) }), options: speedOptions(c), forceMenu: true)
        InspectorAction("Apply this speed to all clips") { model.applySpeedToAll(c.speed) }.disabled(model.clips.count < 2)
        if model.hasMic { ClipVolumeRow(model: model, title: "Microphone volume", system: false, clip: c) }
        ClipVolumeRow(model: model, title: "System audio volume", system: true, clip: c)
        if model.hasMouseData {            // nothing to hide or smooth without mouse data
            SwitchRow("Hide the cursor in this part", isOn: Binding(get: { c.hideCursor }, set: { model.setClipCursor(hide: $0) }))
            SwitchRow("Smooth cursor movement off", isOn: Binding(get: { c.disableSmoothing }, set: { model.setClipCursor(smoothingOff: $0) }))
        }
        InspectorInfo("Length", formatTimecode(c.timelineDurationNs))
    }

    @ViewBuilder private func actions(_ c: TimelineClip) -> some View {
        InspectorAction("Reset trim") { model.resetTrim(clipID: c.id) }.disabled(!model.hasTrimsOrCuts)
            .help("Bring back the parts of the recording that were cut away next to this clip")
        InspectorAction("Reset all trims and cuts") { model.resetAllTrimsAndCuts() }.disabled(!model.hasTrimsOrCuts)
        InspectorAction("Delete clip", symbol: "trash") { model.deleteSelection() }
    }

    private func speedOptions(_ c: TimelineClip) -> [(String, Double)] {
        var o = clipSpeedOptions.map { ($0 == 1 ? "1× (normal)" : clipSpeedLabel($0), $0) }
        if !clipSpeedOptions.contains(c.speed) { o.append((clipSpeedLabel(c.speed), c.speed)) }
        return o
    }
}

func clipSpeedLabel(_ v: Double) -> String { v == v.rounded() ? "\(Int(v))×" : String(format: "%g×", v) }

struct ZoomScaleRow: View {
    @ObservedObject var model: EditorModel
    let zoom: TimelineZoom
    var body: some View {
        CommitSlider(title: "Level", range: zoomLevelRange, get: { zoom.scale }, commit: { model.setZoomScale(id: zoom.id, $0) },
                     text: { String(format: "%.1f×", $0) }, defaultValue: model.defaultZoomScale)
            .id(zoom.id)
        InspectorNote("How close the zoom gets.")
    }
}

/// Glass loupe parameters: size of the lens, edge bevel and color fringing.
struct ZoomLensRows: View {
    @ObservedObject var model: EditorModel
    let zoomID: String
    let lens: ZoomLensParams
    private func row(_ title: String, _ range: ClosedRange<Double>, _ get: @escaping (ZoomLensParams) -> Double,
                     _ set: @escaping (inout ZoomLensParams, Double) -> Void) -> some View {
        CommitSlider(title: title, range: range, get: { get(lens) },
                     commit: { v in var l = lens; set(&l, v); model.setZoomLens(id: zoomID, l) }, text: { String(format: "%.2f", $0) })
    }
    var body: some View {
        row("Lens size", ZoomLensParams.radiusRange, { $0.radius }) { $0.radius = $1 }
        row("Bevel", 0...1, { $0.bevel }) { $0.bevel = $1 }
        row("Color fringing", 0...1, { $0.chromaticAberration }) { $0.chromaticAberration = $1 }
    }
}

struct ClipVolumeRow: View {
    @ObservedObject var model: EditorModel
    let title: String
    let system: Bool
    let clip: TimelineClip
    var body: some View {
        CommitSlider(title: title, range: 0...100, get: { (system ? clip.systemGain : clip.micGain) * 100 },
                     commit: { model.setVolume(percent: Int($0), system: system) },
                     text: { $0 == 0 ? "Muted" : "\(Int($0)) %" }, step: 5)
            .id(clip.id)
    }
}
