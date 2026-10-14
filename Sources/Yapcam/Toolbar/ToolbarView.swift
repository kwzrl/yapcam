import SwiftUI

enum ToolbarPopover: Hashable { case source, audio, microphone, camera }

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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .padding(2)
        .fixedSize()
        .alert(item: $rec.alert) { a in Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK"))) }
    }

    private var edge: Edge { layout.onLeftHalf ? .trailing : .leading }

    // MARK: Idle

    private var idleControls: some View {
        VStack(spacing: 4) {
            ToolbarButton(symbol: settings.sourceMode.symbol, label: sourceLabel, help: "Source: \(sourceHelp)",
                          active: open == .source) { toggle(.source) }
                .popover(isPresented: binding(.source), arrowEdge: edge) { SourcePopover().environmentObject(settings) }
            ToolbarButton(symbol: settings.systemAudio ? "speaker.wave.2.fill" : "speaker.slash",
                          label: "System", help: settings.systemAudio ? "System audio on" : "System audio off",
                          active: settings.systemAudio) { toggle(.audio) }
                .popover(isPresented: binding(.audio), arrowEdge: edge) { SystemAudioPopover().environmentObject(settings) }
            Divider().padding(.vertical, 4)
            RecordButton(recording: false, action: rec.toggleStartStop)
                .help("Start recording (\(settings.startStopShortcut.display))")
            Divider().padding(.vertical, 4)
            ToolbarButton(symbol: "gearshape", label: "Settings", help: "Settings", active: false) {
                SettingsWindow.shared.show()
            }
        }
    }

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
            ToolbarButton(symbol: "xmark", label: "Cancel", help: "Cancel countdown", active: false, action: rec.cancelCountdown)
        }
    }

    private var busyControls: some View {
        ProgressView().controlSize(.small).frame(width: 44, height: 90)
    }

    // MARK: Recording

    private var recordingControls: some View {
        let paused = rec.phase == .paused
        return VStack(spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(paused ? Color.secondary : Color.red).frame(width: 7, height: 7)
                    .opacity(paused ? 1 : 0.9)
            }.padding(.top, 2)
            Text(timeString(rec.elapsed))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(paused ? .secondary : .primary)
                .frame(height: 18)
            if !rec.warnings.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help(rec.warnings.joined(separator: "\n"))
            }
            Divider().padding(.vertical, 2)
            ToolbarButton(symbol: paused ? "play.fill" : "pause.fill", label: paused ? "Resume" : "Pause",
                          help: "\(paused ? "Resume" : "Pause") (\(settings.pauseShortcut.display))", active: false, action: rec.togglePause)
            RecordButton(recording: true, action: rec.toggleStartStop)
                .help("Stop recording (\(settings.startStopShortcut.display))")
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

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 17, weight: .regular)).frame(height: 20)
                Text(label).font(.system(size: 9.5)).lineLimit(1)
            }
            .frame(width: 48, height: 46)
            .foregroundStyle(active ? Color.accentColor : Color.primary)
            .opacity(enabled ? 1 : 0.35)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(active ? Color.accentColor.opacity(0.14) : (hover ? Color.primary.opacity(0.08) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .onHover { hover = $0 }
        .help(help.isEmpty ? label : help)
        .accessibilityLabel(label)
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
                Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 2).frame(width: 40, height: 40)
                if recording {
                    RoundedRectangle(cornerRadius: 3).fill(Color.red).frame(width: 16, height: 16)
                } else {
                    Circle().fill(Color.red.opacity(hover ? 1 : 0.9)).frame(width: 28, height: 28)
                }
            }
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .accessibilityLabel(recording ? "Stop recording" : "Start recording")
    }
}
