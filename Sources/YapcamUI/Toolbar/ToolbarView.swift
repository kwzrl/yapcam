import AppKit
import SwiftUI
import YapcamDesign

enum ToolbarPopover: Hashable { case audio, microphone, camera, afterRecording, recents }

/// The recording picker: one horizontal bar (close, sources, devices, recents + gear) that turns into the
/// recording widget while a take runs. Starting happens on the source cards, not on the bar.
struct ToolbarView: View {
    @ObservedObject var layout: ToolbarLayoutModel
    @EnvironmentObject var rec: RecordingController
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var perms: PermissionsModel
    @ObservedObject private var picker = PickerState.shared
    @ObservedObject private var recovery = RecoveryModel.shared
    @ObservedObject private var devices = DeviceModel.shared
    @State private var open: ToolbarPopover?

    private var vertical: Bool { layout.vertical }
    /// Row for the horizontal bar, column for the vertical one.
    private func line<C: View>(_ spacing: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: spacing)) : AnyLayout(HStackLayout(spacing: spacing))
        return layout { content() }
    }
    private var separator: some View {
        FadingHairline(axis: vertical ? .horizontal : .vertical)
            .frame(width: vertical ? 40 : 2, height: vertical ? 2 : 40)
            .padding(vertical ? .vertical : .horizontal, 3)
    }

    var body: some View {
        let recording = rec.phase == .recording || rec.phase == .paused
        // The vertical widget needs room for the elapsed time across.
        let thickness: CGFloat = recording ? (vertical ? 64 : 48) : 62
        line(0) {
            Grabber(vertical: vertical,
                    onClose: rec.phase == .idle ? { ToolbarPanelController.shared.hide() } : nil,
                    onRotate: { layout.vertical.toggle() })
            Group {
                switch rec.phase {
                case .idle: idleControls
                case .countdown(let n): countdownControls(n)
                case .starting, .finishing: busyControls
                case .recording, .paused: recordingControls
                }
            }
            .padding(vertical ? .bottom : .trailing, 8)
        }
        .frame(width: vertical ? max(thickness, 96) : nil, height: vertical ? nil : thickness)
        .panelSurface(cornerRadius: rec.phase == .recording || rec.phase == .paused ? 24 : 26)
        .padding(2)
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

    private var edge: Edge { vertical ? (layout.onLeftHalf ? .leading : .trailing) : (layout.inLowerHalf ? .top : .bottom) }

    // MARK: Idle: sources, devices, recents + gear

    private var idleControls: some View {
        line(3) {
            ForEach(SourceMode.toolbarModes) { sourceButton($0) }

            separator

            deviceButton(symbol: camLabelOn ? "video.fill" : "video.slash", label: DeviceLabels.camera(name: cameraName), isOn: camOn, help: "Camera", menu: .camera)
                .popover(isPresented: binding(.camera), arrowEdge: edge) { CameraPopover().environmentObject(settings).environmentObject(perms) }
            deviceButton(symbol: micOn ? "mic.fill" : "mic.slash", label: DeviceLabels.microphone(name: microphoneName), isOn: micOn, help: "Microphone", menu: .microphone)
                .overlay(alignment: .top) { if micOn { LevelMeter(level: devices.level).frame(width: 34).padding(.top, 2).allowsHitTesting(false) } }
                .popover(isPresented: binding(.microphone), arrowEdge: edge) { MicrophonePopover().environmentObject(settings).environmentObject(perms) }
            deviceButton(symbol: settings.systemAudio ? "speaker.wave.2.fill" : "speaker.slash",
                         label: settings.systemAudioChoice.buttonLabel(appCount: settings.systemAudioApps.count), isOn: settings.systemAudio,
                         help: "System audio", menu: .audio)
                .popover(isPresented: binding(.audio), arrowEdge: edge) { SystemAudioPopover().environmentObject(settings) }

            separator

            if recovery.count > 0 {
                ToolbarButton(symbol: "exclamationmark.arrow.circlepath", label: "Recover", help: "Recover an unfinished recording", active: false) {
                    RecoveryFlow.run(silentWhenNone: false); recovery.refresh()
                }
            }
            ToolbarButton(symbol: "folder", label: "Recent", help: "Recent projects", active: open == .recents || settings.showRecentsWithPicker) { toggle(.recents) }
                .popover(isPresented: binding(.recents), arrowEdge: edge) { RecentsPopover(dismiss: { open = nil }) }
            settingsMenu
        }
        .onChange(of: open) { _, new in if new == .recents { settings.showRecentsWithPicker = true } else if settings.showRecentsWithPicker, new == nil { settings.showRecentsWithPicker = false } }
        .onAppear { recovery.refresh(); startMeterIfNeeded(); if settings.showRecentsWithPicker { open = .recents } }
        .onDisappear { devices.stopMeter() }
        .onChange(of: settings.microphoneID) { _, _ in startMeterIfNeeded() }
        .onChange(of: perms.state(.microphone)) { _, _ in startMeterIfNeeded() }
    }

    /// Display / Window / Area: one click selects the mode and shows its overlay with **Start recording**.
    private func sourceButton(_ mode: SourceMode) -> some View {
        ToolbarButton(symbol: mode.symbol, label: mode.title, help: sourceHelp(mode), active: picker.openMode == mode) {
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
        ToolbarButton(symbol: symbol, label: label, help: help, active: open == menu, dim: !isOn, width: 88) { toggle(menu) }
            .accessibilityLabel(help).accessibilityValue(label)
    }

    private var cameraName: String? { settings.cameraID.flatMap { id in camOn ? DeviceModel.shared.cameras.first { $0.id == id }?.name : nil } }
    private var microphoneName: String? { settings.microphoneID.flatMap { id in micOn ? DeviceModel.shared.microphones.first { $0.id == id }?.name : nil } }
    private var camLabelOn: Bool { camOn }

    /// A normal toolbar button that pops up the settings menu (an AppKit menu: it keeps the
    /// icon-over-label look that SwiftUI's `Menu` flattens into a row).
    private var settingsMenu: some View {
        ToolbarButton(symbol: "gearshape", label: "Settings", help: "Recording options and more", active: false) {
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
            FadingHairline(axis: vertical ? .horizontal : .vertical).frame(width: vertical ? 28 : 2, height: vertical ? 2 : 28)
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

/// Bar handle: close (idle only), rotate between horizontal and vertical, and the drag grip.
/// Same icon size as the toolbar buttons, side by side in both orientations.
private struct Grabber: View {
    var vertical: Bool
    var onClose: (() -> Void)?
    var onRotate: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if let onClose {
                HandleButton(symbol: "xmark", help: "Close (Esc)", label: "Close toolbar", action: onClose)
            }
            HandleButton(symbol: vertical ? "rectangle.split.2x1" : "rectangle.split.1x2",
                         help: vertical ? "Make the toolbar horizontal" : "Make the toolbar vertical",
                         label: vertical ? "Make toolbar horizontal" : "Make toolbar vertical", action: onRotate)
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(0..<3, id: \.self) { _ in GridRow { ForEach(0..<2, id: \.self) { _ in Circle().frame(width: 3.5, height: 3.5) } } }
            }
                .foregroundStyle(Yap.caption)
                .frame(width: 30, height: 44)
                .contentShape(Rectangle())
                .help("Drag to move")
                .accessibilityHidden(true)      // VoiceOver users move the toolbar with the actions on the toolbar itself
        }
        .padding(vertical ? .top : .leading, 6)
    }
}

private struct HandleButton: View {
    let symbol: String, help: String, label: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                .foregroundStyle(hover ? Yap.title : Yap.caption)
                .frame(width: 30, height: 44)
                .background(RoundedRectangle(cornerRadius: Yap.concentric(26, inset: 9), style: .continuous)
                    .fill(Color.white.opacity(hover ? 0.05 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .help(help).accessibilityLabel(label)
    }
}

struct ToolbarButton: View {
    let symbol: String
    let label: String
    var help: String = ""
    /// Selected (open source, open menu): a brighter platter and full white. No colour.
    var active: Bool
    /// Off state of a device (no camera, mic muted): dimmed label, never a colour.
    var dim: Bool = false
    var enabled: Bool = true
    var width: CGFloat = 52
    let action: () -> Void
    @State private var hover = false
    @Environment(\.contrastOpacity) private var contrast

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium)).frame(height: 20)
                Text(label).font(.system(size: 10, weight: .medium)).lineLimit(1).truncationMode(.tail)
            }
            .frame(width: width, height: 44)
            .foregroundStyle(active ? Yap.title : (dim ? Yap.caption : Yap.label))
            .opacity(enabled ? 1 : 0.35)
            // Concentric with the bar: 26 pt corner, buttons inset 9 pt.
            .background(RoundedRectangle(cornerRadius: Yap.concentric(26, inset: 9), style: .continuous)
                .fill(Color.white.opacity(active ? (contrast.increased ? 0.22 : 0.10) : (hover ? (contrast.increased ? 0.14 : 0.05) : 0))))
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
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
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
