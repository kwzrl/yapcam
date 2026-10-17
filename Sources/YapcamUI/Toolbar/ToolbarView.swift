import AppKit
import SwiftUI
import YapcamDesign

enum ToolbarPopover: Hashable { case audio, microphone, camera, afterRecording, recents }

/// The recording picker: one horizontal bar (close, sources, devices, recents + gear) that turns into the
/// recording widget while a take runs. Starting happens on the source cards, not on the bar.
/// Look (lab variant B): rounded rectangle, concentric platters, plain hairlines between the groups, record
/// beside the bar on its own glass. Vertical, the bar is as narrow as the horizontal one is tall (icons only).
struct ToolbarView: View {
    @ObservedObject var layout: ToolbarLayoutModel
    @EnvironmentObject var rec: RecordingController
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var perms: PermissionsModel
    @ObservedObject private var picker = PickerState.shared
    @ObservedObject private var recovery = RecoveryModel.shared
    @ObservedObject private var devices = DeviceModel.shared
    @ObservedObject private var library = RecentProjectsWindow.shared.model
    @State private var open: ToolbarPopover?

    private var vertical: Bool { layout.vertical }
    /// Row for the horizontal bar, column for the vertical one.
    private func line<C: View>(_ spacing: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: spacing)) : AnyLayout(HStackLayout(spacing: spacing))
        return layout { content() }
    }
    static let radius: CGFloat = 16
    static let thickness: CGFloat = 54
    private var separator: some View {
        Hairline(axis: vertical ? .horizontal : .vertical)
            .frame(width: vertical ? 30 : nil, height: vertical ? nil : 30)
            .padding(vertical ? .vertical : .horizontal, 5)
    }

    var body: some View {
        let recording = rec.phase == .recording || rec.phase == .paused
        // The vertical widget needs room for the elapsed time across.
        let thickness: CGFloat = recording ? (vertical ? 64 : 44) : Self.thickness
        line(10) {
            bar(thickness: thickness)
            if rec.phase == .idle {
                RecordButton(help: "Start recording (\(settings.startStopShortcut.display))", action: rec.begin)
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 24)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Yapcam recording toolbar")
        .accessibilityAction(named: "Move toolbar left") { layout.move(-60, 0) }
        .accessibilityAction(named: "Move toolbar right") { layout.move(60, 0) }
        .accessibilityAction(named: "Move toolbar up") { layout.move(0, 60) }
        .accessibilityAction(named: "Move toolbar down") { layout.move(0, -60) }
        .fixedSize()
        .alert(item: $rec.alert) { a in
            if let p = a.permission {
                return Alert(title: Text(a.title), message: Text(a.message),
                             primaryButton: .default(Text("Open System Settings")) { perms.open(p) }, secondaryButton: .cancel(Text("Not Now")))
            }
            return Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
    }

    private func bar(thickness: CGFloat) -> some View {
        line(0) {
            Grabber(vertical: vertical, onClose: rec.phase == .idle ? { ToolbarPanelController.shared.hide() } : nil)
            Group {
                switch rec.phase {
                case .idle: idleControls
                case .countdown(let n): countdownControls(n)
                case .starting, .finishing: busyControls
                case .recording, .paused: recordingControls
                }
            }
            .padding(vertical ? .bottom : .trailing, 6)
        }
        .frame(width: vertical ? thickness : nil, height: vertical ? nil : thickness)
        .panelSurface(cornerRadius: Self.radius, sheen: true)
    }

    private var edge: Edge { vertical ? (layout.onLeftHalf ? .leading : .trailing) : (layout.inLowerHalf ? .top : .bottom) }

    // MARK: Idle: sources, devices, recents + gear

    private var idleControls: some View {
        line(2) {
            ForEach(SourceMode.toolbarModes) { sourceButton($0) }

            separator

            deviceButton(symbol: camLabelOn ? "video" : "video.slash", label: DeviceLabels.camera(name: cameraName), isOn: camOn, help: "Camera", menu: .camera)
                .popover(isPresented: binding(.camera), arrowEdge: edge) { CameraPopover().environmentObject(settings).environmentObject(perms) }
            deviceButton(symbol: micOn ? "mic" : "mic.slash", label: DeviceLabels.microphone(name: microphoneName), isOn: micOn, help: "Microphone", menu: .microphone)
                .overlay(alignment: .top) { if micOn { LevelMeter(level: devices.level).frame(width: 34).padding(.top, 2).allowsHitTesting(false) } }
                .popover(isPresented: binding(.microphone), arrowEdge: edge) { MicrophonePopover().environmentObject(settings).environmentObject(perms) }
            deviceButton(symbol: settings.systemAudio ? "speaker.wave.2" : "speaker.slash",
                         label: settings.systemAudioChoice.buttonLabel(appCount: settings.systemAudioApps.count), isOn: settings.systemAudio,
                         help: "System audio", menu: .audio)
                .popover(isPresented: binding(.audio), arrowEdge: edge) { SystemAudioPopover().environmentObject(settings) }

            separator

            if recovery.count > 0 {
                ToolbarButton(symbol: "exclamationmark.arrow.circlepath", label: "Recover", help: "Recover an unfinished recording", active: false, compact: vertical) {
                    RecoveryFlow.run(silentWhenNone: false); recovery.refresh()
                }
            }
            editButton
            ToolbarButton(symbol: "folder", label: "Library", help: "All recordings", active: open == .recents || settings.showRecentsWithPicker, compact: vertical) { toggle(.recents) }
                .popover(isPresented: binding(.recents), arrowEdge: edge) { RecentsPopover(dismiss: { open = nil }) }
            settingsMenu
        }
        .onChange(of: open) { _, new in if new == .recents { settings.showRecentsWithPicker = true } else if settings.showRecentsWithPicker, new == nil { settings.showRecentsWithPicker = false } }
        .onAppear { recovery.refresh(); library.reload(); startMeterIfNeeded(); if settings.showRecentsWithPicker { open = .recents } }
        .onDisappear { devices.stopMeter() }
        .onChange(of: settings.microphoneID) { _, _ in startMeterIfNeeded() }
        .onChange(of: perms.state(.microphone)) { _, _ in startMeterIfNeeded() }
    }

    /// Opens the latest recording in the editor; its first frame stands in for the icon.
    private var editButton: some View {
        let last = library.projects.first
        return ToolbarButton(symbol: "film", label: "Edit", help: last.map { "Open “\($0.name)” in the editor" } ?? "No recording to edit yet",
                             active: false, enabled: last != nil, compact: vertical, image: last.flatMap { library.thumbnails[$0.url] }) {
            guard let last else { return }
            open = nil
            rec.engine.openEditor(package: last.url)
        }
        .onAppear { if let last { library.loadThumbnail(last) } }
        .onChange(of: last?.url) { _, _ in if let first = library.projects.first { library.loadThumbnail(first) } }
    }

    /// Display / Window / Area: one click selects the mode and shows its overlay with **Start recording**.
    private func sourceButton(_ mode: SourceMode) -> some View {
        ToolbarButton(symbol: mode.symbol, label: mode.title, help: sourceHelp(mode), active: picker.openMode == mode, compact: vertical) {
            open = nil
            if picker.openMode == mode { SourcePicker.escape(); return }
            SourcePicker.open(mode)
        }
        .contextMenu { if mode == .display { displayMenu } }
        .accessibilityHint(mode == .display ? "Right-click lists the displays" : "")
    }

    /// Right-click on Display: pick one display directly.
    @ViewBuilder private var displayMenu: some View {
        ForEach(NSScreen.screens.compactMap { s in s.displayID.flatMap { id in Displays.info(for: id) } }, id: \.id) { d in
            Button("\(d.name) – \(d.detail)") { SourcePicker.open(.display, display: d.id) }
        }
    }

    private func sourceHelp(_ mode: SourceMode) -> String {
        switch mode {
        case .display: return "Record a display (1): shows the display with a Start recording button"
        case .window: return "Record one window (2): point at it, then Start recording"
        case .area: return settings.areaRect == nil ? "Record an area (3): drag a rectangle, then Start recording" : "Record an area (3): adjust the rectangle, then Start recording"
        case .device: return "Record an iPhone or iPad connected by USB"
        }
    }

    /// A device button: icon + state text; a click opens the device menu.
    private func deviceButton(symbol: String, label: String, isOn: Bool, help: String, menu: ToolbarPopover) -> some View {
        ToolbarButton(symbol: symbol, label: label, help: help, active: open == menu, dim: !isOn, compact: vertical) { toggle(menu) }
            .accessibilityLabel(help).accessibilityValue(label)
    }

    private var cameraName: String? { settings.cameraID.flatMap { id in camOn ? DeviceModel.shared.cameras.first { $0.id == id }?.name : nil } }
    private var microphoneName: String? { settings.microphoneID.flatMap { id in micOn ? DeviceModel.shared.microphones.first { $0.id == id }?.name : nil } }
    private var camLabelOn: Bool { camOn }

    /// A normal toolbar button that pops up the settings menu (an AppKit menu: it keeps the
    /// icon-over-label look that SwiftUI's `Menu` flattens into a row).
    private var settingsMenu: some View {
        ToolbarButton(symbol: "gearshape", label: "Settings", help: "Recording options and more", active: false, compact: vertical) {
            if let view = ToolbarPanelController.shared.panel.contentView, let event = NSApp.currentEvent {
                NSMenu.popUpContextMenu(GearMenu.build(settings: settings), with: event, for: view)
            }
        }
    }

    private var micOn: Bool { settings.microphoneID != nil && perms.state(.microphone) == .granted && DeviceModel.shared.isAvailable(microphone: settings.microphoneID) }
    private var camOn: Bool { settings.cameraID != nil && perms.state(.camera) == .granted && DeviceModel.shared.isAvailable(camera: settings.cameraID) }

    // MARK: Countdown / busy

    private func countdownControls(_ n: Int) -> some View {
        line(10) {
            Text("\(n)").font(.system(size: 26, weight: .bold).monospacedDigit()).foregroundStyle(Yap.title)
                .frame(width: 44)
                .accessibilityLabel("Recording starts in \(n) seconds")
            ToolbarButton(symbol: "xmark", label: "Cancel", help: "Cancel countdown", active: false, action: rec.cancelCountdown)
        }
    }

    private var busyControls: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            if rec.workingLong { Text("Working…").font(Yap.Font.caption).foregroundStyle(Yap.caption) }
        }
        .frame(minWidth: 90, minHeight: 44)
        .accessibilityLabel(rec.phase == .finishing ? "Saving recording" : "Starting recording")
    }

    // MARK: Recording widget (48 pt tall)

    private var recordingControls: some View {
        let paused = rec.phase == .paused
        return line(6) {
            Button(action: rec.toggleStartStop) {
                line(7) {
                    Image(systemName: "stop.circle.fill").font(.system(size: 22)).foregroundStyle(Yap.record)
                    Text(RecordingTimeFormat.string(rec.elapsed))
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(paused ? Yap.faint : Yap.technical)
                        .fixedSize()
                        .accessibilityLabel(paused ? "Recording paused" : "Recording time")
                        .accessibilityValue(Announcer.timeDescription(rec.elapsed))
                }
                .padding(.horizontal, 6).frame(height: 36).contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .help("Stop recording (\(settings.startStopShortcut.display))")
            .accessibilityLabel("Stop recording")
            .accessibilityHint("Stops and saves the recording")
            if !rec.warnings.isEmpty || rec.lowDisk {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Yap.technical)
                    .help((rec.warnings + (rec.lowDisk ? ["Low disk space: recording may stop soon."] : [])).joined(separator: "\n"))
            }
            Hairline(axis: vertical ? .horizontal : .vertical).frame(width: vertical ? 28 : nil, height: vertical ? nil : 28)
            iconButton(paused ? "play.circle" : "pause.circle", label: paused ? "Resume" : "Pause",
                       help: "\(paused ? "Resume" : "Pause") (\(settings.pauseShortcut.display))", action: rec.togglePause)
            iconButton("arrow.counterclockwise", label: "Restart", help: "Discard this take and start over (asks first)", action: rec.confirmRestart)
            iconButton("flag", label: "Add marker", help: "Add a marker here (\(settings.combo(for: .marker)?.display ?? ""))", enabled: !paused, action: rec.addMarker)
            iconButton("trash", label: "Cancel recording", help: "Cancel and delete the recording (asks first)", action: rec.confirmCancel)
            if rec.workingLong { Text("Working…").font(Yap.Font.caption).foregroundStyle(Yap.caption) }
        }
        .padding(vertical ? .top : .leading, 4)
    }

    private func iconButton(_ symbol: String, label: String, help: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(CircleButtonStyle(size: 32))
            .disabled(!enabled).opacity(enabled ? 1 : 0.35)
            .help(help).accessibilityLabel(label)
    }

    /// The live input level on the microphone button runs only while the idle bar is showing and a microphone is chosen.
    private func startMeterIfNeeded() { micOn ? devices.startMeter(deviceID: settings.microphoneID) : devices.stopMeter() }

    private func toggle(_ p: ToolbarPopover) { open = (open == p) ? nil : p }
    private func binding(_ p: ToolbarPopover) -> Binding<Bool> {
        Binding(get: { open == p }, set: { if !$0, open == p { open = nil } })
    }
}

// MARK: - Components

/// Start of the bar: the white close circle and a hairline (idle only). The bar itself is the drag
/// handle; horizontal/vertical lives in the gear menu.
private struct Grabber: View {
    var vertical: Bool
    var onClose: (() -> Void)?

    var body: some View {
        let stack = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        stack {
            if let onClose {
                CloseButton(action: onClose)
                Hairline(axis: vertical ? .horizontal : .vertical)
                    .frame(width: vertical ? 30 : nil, height: vertical ? nil : 30)
                    .padding(vertical ? .vertical : .horizontal, 5)
            } else {
                Color.clear.frame(width: vertical ? 1 : 6, height: vertical ? 6 : 1)
            }
        }
        .padding(vertical ? .top : .leading, 6)
    }
}

/// Icon over label on a platter concentric with the bar (bar radius 16, inset 6 → 10).
/// The white close circle, in a slot like every other button: hover shows the platter and lifts the circle.
private struct CloseButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.black)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white))
                .scaleEffect(hover ? 1.1 : 1)
                .animation(hover ? .snappy(duration: 0.14) : .smooth(duration: 0.3), value: hover)
                .frame(width: ToolbarButton.size, height: ToolbarButton.size)
                .background(Platter(active: false, hover: hover))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .help("Close (Esc)").accessibilityLabel("Close toolbar")
    }
}

/// Record beside the bar on its own glass, as tall as the bar. Same as the start shortcut: records what an
/// open source overlay shows, otherwise the saved source.
private struct RecordButton: View {
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ToolbarView.radius, style: .continuous)
        Button(action: action) {
            Circle().fill(Yap.record).frame(width: 20, height: 20)
                .scaleEffect(hover ? 1.12 : 1)
                .animation(hover ? .snappy(duration: 0.14) : .smooth(duration: 0.3), value: hover)
                .frame(width: ToolbarView.thickness, height: ToolbarView.thickness)
                .background(Platter(active: false, hover: hover).padding(6))
                .panelSurface(cornerRadius: ToolbarView.radius, sheen: true)
                .contentShape(shape)
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .help(help).accessibilityLabel("Start recording")
    }
}

/// Hover/selection platter behind a slot: comes in fast and grows from 90 %, leaves softly.
private struct Platter: View {
    var active: Bool
    var hover: Bool
    @Environment(\.contrastOpacity) private var contrast

    var body: some View {
        let on = active || hover
        RoundedRectangle(cornerRadius: Yap.Radius.control, style: .continuous)
            .fill(Color.white.opacity(active ? (contrast.increased ? 0.36 : 0.24) : (contrast.increased ? 0.16 : 0.08)))
            .opacity(on ? 1 : 0)
            .scaleEffect(on ? 1 : 0.9)
            .animation(on ? .snappy(duration: 0.14) : .smooth(duration: 0.3), value: on)
            .animation(.snappy(duration: 0.18), value: active)
    }
}

struct ToolbarButton: View {
    static let size: CGFloat = 42
    let symbol: String
    let label: String
    var help: String = ""
    /// Selected (open source, open menu): a brighter platter and full white. No colour.
    var active: Bool
    /// Off state of a device (no camera, mic muted): dimmed, never a colour.
    var dim: Bool = false
    var enabled: Bool = true
    /// Icon only (vertical bar); the label stays in the tooltip and for VoiceOver.
    var compact = false
    /// A picture in place of the symbol (the Edit button shows the latest recording).
    var image: NSImage?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            content
                .foregroundStyle(active || hover ? Yap.title : (dim ? Yap.caption : Yap.label))
                .opacity(enabled ? 1 : 0.35)
                .background(Platter(active: active, hover: hover && enabled))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .onHover { hover = $0 }
        .help(help.isEmpty ? label : help)
        .accessibilityLabel(label)
        .accessibilityHint(help == label ? "" : help)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    @ViewBuilder private var content: some View {
        if compact {
            glyph(17).frame(width: Self.size, height: Self.size)
        } else {
            VStack(spacing: 3) {
                glyph(16).frame(height: 19)
                Text(label).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8).truncationMode(.tail)
                    .frame(maxWidth: 104)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: Self.size, minHeight: Self.size, maxHeight: Self.size)
        }
    }

    @ViewBuilder private func glyph(_ size: CGFloat) -> some View {
        if let image {
            let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: 30, height: 19).clipShape(shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
        } else {
            Image(systemName: symbol).font(.system(size: size, weight: .regular))
        }
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// NSMenuItem that runs a closure (target/action without a separate controller).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}
