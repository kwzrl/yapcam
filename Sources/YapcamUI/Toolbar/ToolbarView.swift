import AppKit
import SwiftUI

enum ToolbarPopover: Hashable { case audio, microphone, camera, afterRecording }


struct ToolbarView: View {
    @ObservedObject var layout: ToolbarLayoutModel
    @EnvironmentObject var rec: RecordingController
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var perms: PermissionsModel
    @State private var open: ToolbarPopover?

    var body: some View {
        VStack(spacing: 0) {
            Grabber(onClose: rec.phase == .idle ? { ToolbarPanelController.shared.hide() } : nil)
            Group {
                switch rec.phase {
                case .idle: idleControls
                case .countdown(let n): countdownControls(n)
                case .starting, .finishing: busyControls
                case .recording, .paused: recordingControls
                }
            }
            .padding(.horizontal, 7)
            .padding(.bottom, 8)
        }
        .frame(width: 62)
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

    private var edge: Edge { layout.onLeftHalf ? .trailing : .leading }

    // MARK: Idle: source, devices, folder/settings, record

    private var idleControls: some View {
        VStack(spacing: 3) {
            ForEach(SourceMode.toolbarModes) { sourceButton($0) }

            Divider().padding(.vertical, 3)

            deviceToggle(symbolOn: "video.fill", symbolOff: "video.slash", label: "Camera", isOn: camOn, help: camOn ? "Camera on" : "Camera off",
                         toggle: toggleCamera, menu: .camera)
                .popover(isPresented: binding(.camera), arrowEdge: edge) { CameraPopover().environmentObject(settings).environmentObject(perms) }
            deviceToggle(symbolOn: "mic.fill", symbolOff: "mic.slash", label: "Mic", isOn: micOn, help: micOn ? "Microphone on" : "Microphone off",
                         toggle: toggleMicrophone, menu: .microphone)
                .popover(isPresented: binding(.microphone), arrowEdge: edge) { MicrophonePopover().environmentObject(settings).environmentObject(perms) }
            deviceToggle(symbolOn: "speaker.wave.2.fill", symbolOff: "speaker.slash", label: "System", isOn: settings.systemAudio,
                         help: settings.systemAudio ? "System audio on" : "System audio off",
                         toggle: { settings.systemAudio.toggle() }, menu: .audio)
                .popover(isPresented: binding(.audio), arrowEdge: edge) { SystemAudioPopover().environmentObject(settings) }

            Divider().padding(.vertical, 3)

            ToolbarButton(symbol: "folder", label: "Folder", help: "Show recordings in Finder", active: false) {
                try? FileManager.default.createDirectory(at: settings.storageDirectory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(settings.storageDirectory)
            }
            settingsMenu

            RecordButton(recording: false, large: true, action: rec.toggleStartStop)
                .help("\(settings.afterRecording.recordLabel) (\(settings.startStopShortcut.display))")
                .overlay(alignment: .topTrailing) {
                    Button { toggle(.afterRecording) } label: {
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).frame(width: 16, height: 16).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("After recording…").accessibilityLabel("After recording options")
                }
                .popover(isPresented: binding(.afterRecording), arrowEdge: edge) { AfterRecordingPopover().environmentObject(settings) }
                .padding(.top, 2)
        }
    }

    /// Display / Window / Area: one click picks the source and shows its overlay with **Start recording**.
    private func sourceButton(_ mode: SourceMode) -> some View {
        ToolbarButton(symbol: mode.symbol, label: mode.title, help: sourceHelp(mode), active: settings.sourceMode == mode) {
            open = nil
            settings.sourceMode = mode
            switch mode {
            case .display: SourceOverlay.shared.show(.display)
            case .window: SourceOverlay.shared.show(.window)
            case .area: AreaPicker.begin()
            case .device: break
            }
        }
    }

    private func sourceHelp(_ mode: SourceMode) -> String {
        switch mode {
        case .display: return "Record a display: shows the display with a Start recording button"
        case .window: return "Record one window: point at it, then Start recording"
        case .area: return settings.areaRect == nil ? "Record an area: drag a rectangle, then Start recording" : "Record an area (adjust the rectangle, then Start recording)"
        case .device: return "Record an iPhone or iPad connected by USB"
        }
    }

    /// A toggle with a small chevron that opens the device menu in a side popover.
    private func deviceToggle(symbolOn: String, symbolOff: String, label: String, isOn: Bool, help: String,
                              toggle: @escaping () -> Void, menu: ToolbarPopover) -> some View {
        ToolbarButton(symbol: isOn ? symbolOn : symbolOff, label: label, help: help, active: isOn, action: toggle)
            .overlay(alignment: .topTrailing) {
                Button { self.toggle(menu) } label: {
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                        .frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("\(label) options")
                .accessibilityLabel("\(label) options")
            }
    }

    private func toggleCamera() {
        DeviceModel.shared.reload()
        if perms.state(.camera) != .granted || DeviceModel.shared.cameras.isEmpty { toggle(.camera); return }
        if settings.cameraID != nil { settings.lastCameraID = settings.cameraID; settings.cameraID = nil }
        else {
            let remembered = DeviceModel.shared.isAvailable(camera: settings.lastCameraID) ? settings.lastCameraID : nil
            settings.cameraID = remembered ?? DeviceModel.shared.cameras.first?.id
        }
    }

    private func toggleMicrophone() {
        DeviceModel.shared.reload()
        if perms.state(.microphone) != .granted || DeviceModel.shared.microphones.isEmpty { toggle(.microphone); return }
        if settings.microphoneID != nil { settings.lastMicrophoneID = settings.microphoneID; settings.microphoneID = nil }
        else {
            let remembered = DeviceModel.shared.isAvailable(microphone: settings.lastMicrophoneID) ? settings.lastMicrophoneID : nil
            settings.microphoneID = remembered ?? DeviceModel.shared.microphones.first?.id
        }
    }

    /// A normal toolbar button that pops up the settings menu below it (an AppKit menu: it keeps the
    /// icon-over-label look that SwiftUI's `Menu` flattens into a row).
    private var settingsMenu: some View {
        ToolbarButton(symbol: "gearshape", label: "Settings", help: "Settings and more", active: false) {
            let menu = NSMenu()
            func add(_ title: String, _ action: @escaping () -> Void) {
                let item = ClosureMenuItem(title: title, handler: action); menu.addItem(item)
            }
            add("Settings…") { SettingsWindow.shared.show() }
            add("Recordings…") { RecentProjectsWindow.shared.show() }
            add("Speaker Notes…") { NotesWindow.shared.show() }
            add("Permissions…") { OnboardingWindow.shared.show(reason: nil) }
            menu.addItem(.separator())
            add("Hide Toolbar") { ToolbarPanelController.shared.hide() }
            add("Quit Yapcam") { NSApp.terminate(nil) }
            if let view = ToolbarPanelController.shared.panel.contentView, let event = NSApp.currentEvent {
                NSMenu.popUpContextMenu(menu, with: event, for: view)
            }
        }
    }

    private var micOn: Bool { settings.microphoneID != nil && perms.state(.microphone) == .granted && DeviceModel.shared.isAvailable(microphone: settings.microphoneID) }
    private var camOn: Bool { settings.cameraID != nil && perms.state(.camera) == .granted && DeviceModel.shared.isAvailable(camera: settings.cameraID) }

    // MARK: Countdown / busy

    private func countdownControls(_ n: Int) -> some View {
        VStack(spacing: 6) {
            Text("\(n)").font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                .frame(height: 40)
                .accessibilityLabel("Recording starts in \(n) seconds")
            ToolbarButton(symbol: "xmark", label: "Cancel", help: "Cancel countdown", active: false, action: rec.cancelCountdown)
        }
    }

    private var busyControls: some View {
        VStack(spacing: 6) {
            ProgressView().controlSize(.small)
            if rec.workingLong { Text("Working…").font(.system(size: 9.5)).foregroundStyle(.secondary) }
        }
        .frame(width: 48, height: 90)
        .accessibilityLabel(rec.phase == .finishing ? "Saving recording" : "Starting recording")
    }

    // MARK: Recording

    private var recordingControls: some View {
        let paused = rec.phase == .paused
        return VStack(spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(paused ? Color.secondary : Color.red).frame(width: 7, height: 7)
                    .opacity(paused ? 1 : 0.9).accessibilityHidden(true)
            }.padding(.top, 2)
            Text(timeString(rec.elapsed))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(paused ? .secondary : .primary)
                .frame(height: 18)
                .accessibilityLabel(paused ? "Recording paused" : "Recording time")
                .accessibilityValue(Announcer.timeDescription(rec.elapsed))
            if !rec.warnings.isEmpty || rec.lowDisk {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help((rec.warnings + (rec.lowDisk ? ["Low disk space: recording may stop soon."] : [])).joined(separator: "\n"))
            }
            Divider().padding(.vertical, 2)
            ToolbarButton(symbol: paused ? "play.fill" : "pause.fill", label: paused ? "Resume" : "Pause",
                          help: "\(paused ? "Resume" : "Pause") (\(settings.pauseShortcut.display))", active: false, action: rec.togglePause)
            RecordButton(recording: true, action: rec.toggleStartStop)
                .help("Stop recording (\(settings.startStopShortcut.display))")
            ToolbarButton(symbol: "flag", label: "Marker", help: "Add a marker here (\(settings.combo(for: .marker)?.display ?? ""))", active: false,
                          enabled: !paused, action: rec.addMarker)
            ToolbarButton(symbol: "arrow.counterclockwise", label: "Restart", help: "Discard this take and start over (asks first)", active: false, action: rec.confirmRestart)
            ToolbarButton(symbol: "trash", label: "Cancel", help: "Cancel and delete the recording (asks first)", active: false, action: rec.confirmCancel)
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func toggle(_ p: ToolbarPopover) { open = (open == p) ? nil : p }
    private func binding(_ p: ToolbarPopover) -> Binding<Bool> {
        Binding(get: { open == p }, set: { if !$0, open == p { open = nil } })
    }
}

// MARK: - Components

private struct Grabber: View {
    var onClose: (() -> Void)?
    var body: some View {
        ZStack {
            VStack(spacing: 3) {
                ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 3, height: 3) } }
                }
            }
            .foregroundStyle(.tertiary)
            .help("Drag to move")
            .accessibilityHidden(true)      // VoiceOver users move the toolbar with the actions on the toolbar itself
            HStack {
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Hide toolbar (bring it back from the menu bar item or the Dock)")
                    .accessibilityLabel("Close toolbar")
                }
                Spacer()
            }
            .padding(.leading, 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .contentShape(Rectangle())
    }
}

struct ToolbarButton: View {
    let symbol: String
    let label: String
    var help: String = ""
    var active: Bool
    var enabled: Bool = true
    let action: () -> Void
    @State private var hover = false
    @Environment(\.contrastOpacity) private var contrast

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 17, weight: .regular)).frame(height: 20)
                Text(label).font(.system(size: 9.5)).lineLimit(1)
            }
            .frame(width: 48, height: 44)
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

struct RecordButton: View {
    let recording: Bool
    var large = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let ring: CGFloat = large ? 48 : 40, dot: CGFloat = large ? 34 : 28, stop: CGFloat = large ? 20 : 16
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 2).frame(width: ring, height: ring).accessibilityHidden(true)
                if recording {
                    RoundedRectangle(cornerRadius: 3).fill(Color.red).frame(width: stop, height: stop)
                } else {
                    Circle().fill(Color.red.opacity(hover ? 1 : 0.9)).frame(width: dot, height: dot)
                }
            }
            .frame(width: 54, height: large ? 56 : 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .accessibilityLabel(recording ? "Stop recording" : "Start recording")
        .accessibilityHint(recording ? "Stops and saves the recording" : "Starts recording after the countdown")
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
