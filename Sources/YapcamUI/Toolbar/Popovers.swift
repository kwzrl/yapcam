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

// MARK: - Source pickers (opened from the toolbar's Display / Window / Device buttons)

struct DisplayPopover: View {
    let dismiss: () -> Void
    @EnvironmentObject var settings: AppSettings
    @State private var displays = Displays.all()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PopoverHeader(title: "Display")
            ForEach(displays) { d in
                SelectableRow(selected: Displays.resolve(settings.displayID)?.id == d.id) {
                    settings.displayID = d.id; settings.sourceMode = .display; dismiss()
                } content: {
                    Image(systemName: "display").frame(width: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(d.name)
                        Text("\(Int(d.pixelSize.width)) × \(Int(d.pixelSize.height))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14).frame(width: 260)
        .onAppear { displays = Displays.all() }
    }
}

struct WindowPopover: View {
    let dismiss: () -> Void
    @EnvironmentObject var settings: AppSettings
    @StateObject private var windows = WindowList()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                PopoverHeader(title: "Window")
                Spacer()
                Button { Task { await windows.reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh window list").accessibilityLabel("Refresh window list")
            }
            if let e = windows.error, windows.windows.isEmpty {
                Text(e).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else if windows.windows.isEmpty {
                ProgressView("Looking for windows…").controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(windows.windows) { w in
                            WindowCell(info: w, selected: settings.windowID == w.id, thumbnail: windows.thumbnails[w.id]) {
                                settings.windowID = w.id; settings.sourceMode = .window; dismiss()
                            }
                            .onAppear { windows.loadThumbnail(for: w.id) }
                        }
                    }.padding(.vertical, 2)
                }
                .frame(height: 340)
            }
        }
        .padding(14).frame(width: 400)
        .task { await windows.reload() }
    }
}

struct DevicePopover: View {
    let dismiss: () -> Void
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var model = DeviceScreensModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PopoverHeader(title: "Device")
            if model.devices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right").font(.system(size: 30)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text("Connect an iPhone or iPad via USB").font(.system(size: 13, weight: .medium))
                    Text(model.error ?? (model.loaded ? "Unlock it and tap Trust if it asks. It appears here when it is ready."
                                                      : "Looking for devices…"))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 130)
            } else {
                ForEach(model.devices) { d in
                    SelectableRow(selected: settings.deviceID == d.id || model.devices.count == 1) {
                        settings.deviceID = d.id; settings.sourceMode = .device; dismiss()
                    } content: {
                        Image(systemName: "iphone").frame(width: 20)
                        Text(d.name).lineLimit(1)
                    }
                }
                Text("Touches on the device are not recorded as cursor events.").font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding(14).frame(width: 280)
        .onAppear { model.startPolling() }
        .onDisappear { if settings.sourceMode != .device { model.stopPolling() } }
    }
}

/// Starts the area overlay right away (Area button); the chosen rectangle is saved in settings.
@MainActor enum AreaPicker {
    static func begin() {
        let settings = AppSettings.shared
        if Displays.info(for: settings.areaDisplayID) == nil { settings.areaDisplayID = Displays.resolve(0)?.id ?? 0 }
        guard let screen = Displays.screen(for: settings.areaDisplayID) ?? NSScreen.main else { return }
        let keep = settings.areaDisplayID == screen.displayID ? settings.areaRect : nil
        AreaSelector.shared.begin(on: screen, initial: keep) { rect in
            if let rect, let id = screen.displayID { settings.areaDisplayID = id; settings.areaRect = rect }
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
                VStack(alignment: .leading, spacing: 3) {
                    Text("No microphone").font(.system(size: 13, weight: .medium))
                    Text("Connect one and it appears here.").font(.caption).foregroundStyle(.secondary)
                }
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
                VStack(alignment: .leading, spacing: 3) {
                    Text("No camera").font(.system(size: 13, weight: .medium))
                    Text("Connect one and it appears here.").font(.caption).foregroundStyle(.secondary)
                }
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
                .overlay(alignment: .topLeading) {
                    if rec.notes.isEmpty {
                        Text("Type what you want to say. It stays visible while you record.")
                            .font(.system(size: 13)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 6).padding(.top, 8).allowsHitTesting(false)
                    }
                }
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
