import SwiftUI
import YapcamDesign

enum ToolbarPopover: Hashable { case source, audio, microphone, camera, notes }


struct ToolbarView: View {
    @ObservedObject var layout: ToolbarLayoutModel
    @EnvironmentObject var rec: RecordingController
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var perms: PermissionsModel
    @State private var open: ToolbarPopover?

    var body: some View {
        VStack(spacing: 0) {
            Grabber()
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

    // MARK: Idle

    private var idleControls: some View {
        VStack(spacing: 4) {
            ToolbarButton(symbol: settings.sourceMode.symbol, label: sourceLabel, help: "Source: \(sourceHelp)",
                          active: open == .source) { toggle(.source) }
                .popover(isPresented: binding(.source), arrowEdge: edge) { SourcePopover(dismiss: { open = nil }).environmentObject(settings) }
            ToolbarButton(symbol: settings.systemAudio ? "speaker.wave.2.fill" : "speaker.slash",
                          label: "System", help: settings.systemAudio ? "System audio on" : "System audio off",
                          active: settings.systemAudio) { toggle(.audio) }
                .popover(isPresented: binding(.audio), arrowEdge: edge) { SystemAudioPopover().environmentObject(settings) }
            ToolbarButton(symbol: micOn ? "mic.fill" : "mic.slash", label: "Mic", help: micOn ? "Microphone on" : "Microphone off",
                          active: micOn) { toggle(.microphone) }
                .popover(isPresented: binding(.microphone), arrowEdge: edge) {
                    MicrophonePopover().environmentObject(settings).environmentObject(perms)
                }
            ToolbarButton(symbol: camOn ? "video.fill" : "video.slash", label: "Camera", help: camOn ? "Camera on" : "Camera off",
                          active: camOn) { toggle(.camera) }
                .popover(isPresented: binding(.camera), arrowEdge: edge) {
                    CameraPopover().environmentObject(settings).environmentObject(perms)
                }
            notesButton
            Divider().padding(.vertical, 4)
            RecordButton(recording: false, action: rec.toggleStartStop)
                .help("Start recording (\(settings.startStopShortcut.display))")
            Divider().padding(.vertical, 4)
            ToolbarButton(symbol: "gearshape", label: "Settings", help: "Settings", active: false) {
                SettingsWindow.shared.show()
            }
        }
    }

    private var notesButton: some View {
        ToolbarButton(symbol: "note.text", label: "Notes", help: "Speaker notes", active: !rec.notes.isEmpty) { toggle(.notes) }
            .popover(isPresented: binding(.notes), arrowEdge: edge) { NotesPopover().environmentObject(rec) }
    }

    private var micOn: Bool { settings.microphoneID != nil && perms.state(.microphone) == .granted && DeviceModel.shared.isAvailable(microphone: settings.microphoneID) }
    private var camOn: Bool { settings.cameraID != nil && perms.state(.camera) == .granted && DeviceModel.shared.isAvailable(camera: settings.cameraID) }

    private var sourceLabel: String { settings.sourceMode.title }
    private var sourceHelp: String {
        switch settings.sourceMode {
        case .display: return Displays.resolve(settings.displayID)?.name ?? "Display"
        case .window: return "Window"
        case .area: return "Area"
        }
    }

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
        ProgressView().controlSize(.small).frame(width: 44, height: 90)
            .accessibilityLabel(rec.phase == .finishing ? "Saving recording" : "Starting recording")
    }

    // MARK: Recording

    private var recordingControls: some View {
        let paused = rec.phase == .paused
        return VStack(spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(paused ? Color.secondary : Yap.record).frame(width: 7, height: 7)
                    .opacity(paused ? 1 : 0.9).accessibilityHidden(true)
            }.padding(.top, 2)
            Text(timeString(rec.elapsed))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(paused ? .secondary : .primary)
                .frame(height: 18)
                .accessibilityLabel(paused ? "Recording paused" : "Recording time")
                .accessibilityValue(Announcer.timeDescription(rec.elapsed))
            if !rec.warnings.isEmpty || rec.lowDisk {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Yap.warning)
                    .help((rec.warnings + (rec.lowDisk ? ["Low disk space: recording may stop soon."] : [])).joined(separator: "\n"))
            }
            Divider().padding(.vertical, 2)
            ToolbarButton(symbol: paused ? "play.fill" : "pause.fill", label: paused ? "Resume" : "Pause",
                          help: "\(paused ? "Resume" : "Pause") (\(settings.pauseShortcut.display))", active: false, action: rec.togglePause)
            RecordButton(recording: true, action: rec.toggleStartStop)
                .help("Stop recording (\(settings.startStopShortcut.display))")
            notesButton
            ToolbarButton(symbol: "arrow.counterclockwise", label: "Restart", help: "Discard this take and start over", active: false, action: rec.restart)
            ToolbarButton(symbol: "trash", label: "Cancel", help: "Discard recording", active: false, action: rec.cancel)
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
    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 3, height: 3) } }
            }
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .frame(height: 22)
        .contentShape(Rectangle())
        .help("Drag to move")
        .accessibilityHidden(true)      // VoiceOver users move the toolbar with the actions on the toolbar itself
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
            .frame(width: 48, height: 46)
            .foregroundStyle(active ? Yap.accent : Color.primary)
            .opacity(enabled ? 1 : 0.35)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(active ? Yap.accent.opacity(contrast.activeFill) : (hover ? Color.primary.opacity(contrast.hoverFill) : .clear)))
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
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 2).frame(width: 40, height: 40).accessibilityHidden(true)
                if recording {
                    RoundedRectangle(cornerRadius: 3).fill(Yap.record).frame(width: 16, height: 16)
                } else {
                    Circle().fill(Yap.record.opacity(hover ? 1 : 0.9)).frame(width: 28, height: 28)
                }
            }
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .accessibilityLabel(recording ? "Stop recording" : "Start recording")
        .accessibilityHint(recording ? "Stops and saves the recording" : "Starts recording after the countdown")
    }
}
