import AVFoundation
import SwiftUI

struct PopoverHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .textCase(.uppercase).padding(.bottom, 2)
    }
}

private struct SelectableRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hover = false
    @Environment(\.contrastOpacity) private var contrast
    var body: some View {
        Button(action: action) {
            HStack { content; Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) } }
                .padding(.vertical, 5).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(contrast.hoverFill) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Source

struct SourcePopover: View {
    let dismiss: () -> Void
    @EnvironmentObject var settings: AppSettings
    @State private var displays = Displays.all()
    @StateObject private var windows = WindowList()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Source", selection: $settings.sourceMode) {
                ForEach(SourceMode.allCases) { m in Label(m.title, systemImage: m.symbol).tag(m) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityLabel("Recording source")

            switch settings.sourceMode {
            case .display: displayList
            case .window: windowGrid
            case .area: areaPane
            }
        }
        .padding(14)
        .frame(width: settings.sourceMode == .window ? 400 : 280)
        .onAppear { displays = Displays.all() }
        .task(id: settings.sourceMode) { if settings.sourceMode == .window { await windows.reload() } }
    }

    // Display

    private var displayList: some View {
        VStack(alignment: .leading, spacing: 2) {
            PopoverHeader(title: "Display")
            ForEach(displays) { d in
                SelectableRow(selected: Displays.resolve(settings.displayID)?.id == d.id) {
                    settings.displayID = d.id
                } content: {
                    Image(systemName: "display").frame(width: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(d.name)
                        Text("\(Int(d.pixelSize.width)) × \(Int(d.pixelSize.height))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // Window

    private var windowGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                PopoverHeader(title: "Window")
                Spacer()
                Button { Task { await windows.reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh window list")
            }
            if let e = windows.error, windows.windows.isEmpty {
                Text(e).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(windows.windows) { w in
                            WindowCell(info: w, selected: settings.windowID == w.id, thumbnail: windows.thumbnails[w.id]) {
                                settings.windowID = w.id; dismiss()
                            }
                            .onAppear { windows.loadThumbnail(for: w.id) }
                        }
                    }.padding(.vertical, 2)
                }
                .frame(height: 340)
            }
        }
    }

    // Area

    private var areaPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            PopoverHeader(title: "Area")
            if let r = settings.areaRect {
                Text("\(Int(r.width)) × \(Int(r.height)) on \(Displays.info(for: settings.areaDisplayID)?.name ?? "display")")
                    .font(.callout)
            } else {
                Text("No area selected yet.").font(.callout).foregroundStyle(.secondary)
            }
            if displays.count > 1 {
                Picker("Display", selection: Binding(get: { Displays.resolve(settings.areaDisplayID)?.id ?? 0 },
                                                      set: { settings.areaDisplayID = $0 })) {
                    ForEach(displays) { Text($0.name).tag($0.id) }
                }
            }
            HStack {
                Button(settings.areaRect == nil ? "Select Area…" : "Adjust Area…") { selectArea() }
                    .keyboardShortcut(.defaultAction)
                if settings.areaRect != nil { Button("Clear") { settings.areaRect = nil } }
            }
            Text("Drag a rectangle, pick an aspect ratio, press Return to confirm.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { if Displays.info(for: settings.areaDisplayID) == nil { settings.areaDisplayID = Displays.resolve(0)?.id ?? 0 } }
    }

    private func selectArea() {
        guard let screen = Displays.screen(for: settings.areaDisplayID) ?? NSScreen.main else { return }
        dismiss()
        let keep = settings.areaDisplayID == screen.displayID ? settings.areaRect : nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            AreaSelector.shared.begin(on: screen, initial: keep) { rect in
                if let rect, let id = screen.displayID {
                    settings.areaDisplayID = id; settings.areaRect = rect
                }
            }
        }
    }
}

private struct WindowCell: View {
    let info: WindowInfo
    let selected: Bool
    let thumbnail: NSImage?
    let action: () -> Void
    @State private var hover = false
    @Environment(\.contrastOpacity) private var contrast
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(contrast.subtleFill))
                    if let t = thumbnail { Image(nsImage: t).resizable().scaledToFit().padding(2) }
                    else { ProgressView().controlSize(.small) }
                }
                .frame(height: 88)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : (hover ? Color.primary.opacity(contrast.outline) : .clear), lineWidth: 2))
                Text(info.displayTitle).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(info.appName).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("\(info.displayTitle), \(info.appName)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - System audio

struct SystemAudioPopover: View {
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PopoverHeader(title: "System audio")
            Toggle("Record system audio", isOn: $settings.systemAudio)
            Text("Sound played by apps and the system, without Yapcam's own sounds. Saved as its own track so you can mix it in the editor.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 260)
    }
}

// MARK: - Microphone

struct MicrophonePopover: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var perms: PermissionsModel
    @ObservedObject var devices = DeviceModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PopoverHeader(title: "Microphone")
            if perms.state(.microphone) != .granted {
                PermissionPrompt(permission: .microphone)
            } else if devices.microphones.isEmpty {
                Text("No microphone found. Connect one and it will appear here.").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                SelectableRow(selected: settings.microphoneID == nil) { settings.microphoneID = nil } content: {
                    Text("Off")
                }
                ForEach(devices.microphones) { m in
                    SelectableRow(selected: settings.microphoneID == m.id) { settings.microphoneID = m.id } content: {
                        Text(m.name).lineLimit(1)
                    }
                }
                if settings.microphoneID != nil && !devices.isAvailable(microphone: settings.microphoneID) {
                    Label("Selected microphone is not connected. Recording without it.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                } else if settings.microphoneID != nil {
                    LevelMeter(level: devices.level).padding(.horizontal, 8).padding(.top, 4)
                    if let e = devices.meterError { Text(e).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(14).frame(width: 280)
        .onAppear { devices.reload(); devices.startMeter(deviceID: settings.microphoneID) }
        .onChange(of: settings.microphoneID) { _, id in devices.startMeter(deviceID: id) }
        .onDisappear { devices.stopMeter() }
    }
}

// MARK: - Camera

struct CameraPopover: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var perms: PermissionsModel
    @ObservedObject var devices = DeviceModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PopoverHeader(title: "Camera")
            if perms.state(.camera) != .granted {
                PermissionPrompt(permission: .camera)
            } else if devices.cameras.isEmpty {
                Text("No camera found. Connect one and it will appear here.").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                SelectableRow(selected: settings.cameraID == nil) { settings.cameraID = nil } content: { Text("Off") }
                ForEach(devices.cameras) { c in
                    SelectableRow(selected: settings.cameraID == c.id) { settings.cameraID = c.id } content: {
                        Text(c.name).lineLimit(1)
                    }
                }
                if settings.cameraID != nil && !devices.isAvailable(camera: settings.cameraID) {
                    Label("Selected camera is not connected. Recording without it.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                } else if settings.cameraID != nil {
                    CameraPreview(session: devices.previewSession)
                        .frame(height: 140).clipShape(RoundedRectangle(cornerRadius: 8))
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.8)))
                }
            }
        }
        .padding(14).frame(width: 280)
        .onAppear { devices.reload(); devices.startPreview(deviceID: settings.cameraID) }
        .onChange(of: settings.cameraID) { _, id in devices.startPreview(deviceID: id) }
        .onDisappear { devices.stopPreview() }
    }
}

private struct PermissionPrompt: View {
    let permission: AppPermission
    @EnvironmentObject var perms: PermissionsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(permission.title) access is off.").font(.callout)
            Text(permission.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(perms.state(permission) == .notDetermined ? "Allow Access" : "Open System Settings") {
                perms.act(permission)
            }
        }
    }
}

// MARK: - Notes

struct NotesPopover: View {
    @EnvironmentObject var rec: RecordingController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PopoverHeader(title: "Speaker notes")
            TextEditor(text: $rec.notes)
                .font(.system(size: 13))
                .frame(height: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            HStack {
                Button { TeleprompterController.shared.toggle() } label: { Label("Teleprompter", systemImage: "text.alignleft") }
                Spacer()
                Text("\(rec.notes.count) characters").font(.caption).foregroundStyle(.secondary)
            }
            Text("The teleprompter floats above your screen, scrolls while you record and never appears in the recording. Notes are saved with the recording.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(width: 300)
    }
}
