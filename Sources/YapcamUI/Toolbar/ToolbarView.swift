import AppKit
import SwiftUI

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

    var body: some View {
        HStack(spacing: 0) {
            Grabber(onClose: rec.phase == .idle ? { ToolbarPanelController.shared.hide() } : nil)
            Group {
                switch rec.phase {
                case .idle: idleControls
                case .countdown(let n): countdownControls(n)
                case .starting, .finishing: busyControls
                case .recording, .paused: recordingControls
                }
            }
            .padding(.trailing, 8)
        }
        .frame(height: rec.phase == .recording || rec.phase == .paused ? 48 : 62)
        .panelSurface(cornerRadius: 18)
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

    private var edge: Edge { layout.inLowerHalf ? .top : .bottom }

    // MARK: Idle: sources, devices, recents + gear

    private var idleControls: some View {
        HStack(spacing: 3) {
            ForEach(SourceMode.toolbarModes) { sourceButton($0) }

            Divider().frame(height: 34).padding(.horizontal, 3)

            deviceButton(symbol: camLabelOn ? "video.fill" : "video.slash", label: DeviceLabels.camera(name: cameraName), isOn: camOn, help: "Camera", menu: .camera)
                .popover(isPresented: binding(.camera), arrowEdge: edge) { CameraPopover().environmentObject(settings).environmentObject(perms) }
            deviceButton(symbol: micOn ? "mic.fill" : "mic.slash", label: DeviceLabels.microphone(name: microphoneName), isOn: micOn, help: "Microphone", menu: .microphone)
                .overlay(alignment: .top) { if micOn { LevelMeter(level: devices.level).frame(width: 34).padding(.top, 2).allowsHitTesting(false) } }
                .popover(isPresented: binding(.microphone), arrowEdge: edge) { MicrophonePopover().environmentObject(settings).environmentObject(perms) }
            deviceButton(symbol: settings.systemAudio ? "speaker.wave.2.fill" : "speaker.slash",
                         label: settings.systemAudioChoice.buttonLabel(appCount: settings.systemAudioApps.count), isOn: settings.systemAudio,
                         help: "System audio", menu: .audio)
                .popover(isPresented: binding(.audio), arrowEdge: edge) { SystemAudioPopover().environmentObject(settings) }

            Divider().frame(height: 34).padding(.horizontal, 3)

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
        ToolbarButton(symbol: symbol, label: label, help: help, active: isOn, width: 78) { toggle(menu) }
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
        HStack(spacing: 10) {
            Text("\(n)").font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                .frame(width: 44)
                .accessibilityLabel("Recording starts in \(n) seconds")
            ToolbarButton(symbol: "xmark", label: "Cancel", help: "Cancel countdown", active: false, action: rec.cancelCountdown)
        }
    }

    private var busyControls: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            if rec.workingLong { Text("Working…").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .frame(minWidth: 90, minHeight: 44)
        .accessibilityLabel(rec.phase == .finishing ? "Saving recording" : "Starting recording")
    }

    // MARK: Recording widget (48 pt tall)

    private var recordingControls: some View {
        let paused = rec.phase == .paused
        return HStack(spacing: 6) {
            Button(action: rec.toggleStartStop) {
                HStack(spacing: 7) {
                    Image(systemName: "stop.circle.fill").font(.system(size: 22)).foregroundStyle(.red)
                    Text(RecordingTimeFormat.string(rec.elapsed))
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(paused ? .secondary : .primary)
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
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help((rec.warnings + (rec.lowDisk ? ["Low disk space: recording may stop soon."] : [])).joined(separator: "\n"))
            }
            Divider().frame(height: 22)
            iconButton(paused ? "play.circle" : "pause.circle", label: paused ? "Resume" : "Pause",
                       help: "\(paused ? "Resume" : "Pause") (\(settings.pauseShortcut.display))", action: rec.togglePause)
            iconButton("arrow.counterclockwise", label: "Restart", help: "Discard this take and start over (asks first)", action: rec.confirmRestart)
            iconButton("flag", label: "Add marker", help: "Add a marker here (\(settings.combo(for: .marker)?.display ?? ""))", enabled: !paused, action: rec.addMarker)
            iconButton("trash", label: "Cancel recording", help: "Cancel and delete the recording (asks first)", action: rec.confirmCancel)
            if rec.workingLong { Text("Working…").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .padding(.leading, 4)
    }

    private func iconButton(_ symbol: String, label: String, help: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18)).frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
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

private struct Grabber: View {
    var onClose: (() -> Void)?
    var body: some View {
        VStack(spacing: 4) {
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Close (Esc)")
                .accessibilityLabel("Close toolbar")
            }
            HStack(spacing: 3) {
                ForEach(0..<2, id: \.self) { _ in
                    VStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 3, height: 3) } }
                }
            }
            .foregroundStyle(.tertiary)
            .help("Drag to move")
            .accessibilityHidden(true)      // VoiceOver users move the toolbar with the actions on the toolbar itself
        }
        .frame(width: 30).frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

struct ToolbarButton: View {
    let symbol: String
    let label: String
    var help: String = ""
    var active: Bool
    var enabled: Bool = true
    var width: CGFloat = 48
    let action: () -> Void
    @State private var hover = false
    @Environment(\.contrastOpacity) private var contrast

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 17, weight: .regular)).frame(height: 20)
                Text(label).font(.system(size: 9.5)).lineLimit(1).truncationMode(.tail)
            }
            .frame(width: width, height: 44)
            .foregroundStyle(active ? Color.accentColor : Color.primary)
            .opacity(enabled ? 1 : 0.35)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(active ? Color.accentColor.opacity(contrast.activeFill) : (hover ? Color.primary.opacity(contrast.hoverFill) : .clear)))
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
