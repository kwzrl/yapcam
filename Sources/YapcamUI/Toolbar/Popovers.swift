import AVFoundation
import SwiftUI
import YapcamDesign

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
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.white) } }
                .padding(.vertical, 5).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(contrast.hoverFill) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Starts the area overlay right away (Area button); the chosen rectangle is saved in settings.
@MainActor enum AreaPicker {
    /// `onDisplay`: a given display (adjusting a window as area). Otherwise the display under the pointer,
    /// like the display overlay, so every display can be recorded as an area.
    static func begin(onDisplay: UInt32? = nil) {
        SourceOverlay.shared.hide(restoreFocus: false)
        let settings = AppSettings.shared
        if let onDisplay { settings.areaDisplayID = onDisplay }
        else if let id = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.displayID { settings.areaDisplayID = id }
        if Displays.info(for: settings.areaDisplayID) == nil { settings.areaDisplayID = Displays.resolve(0)?.id ?? 0 }
        guard let screen = Displays.screen(for: settings.areaDisplayID) ?? NSScreen.main else { return }
        let keep = settings.areaDisplayID == screen.displayID ? settings.areaRect : nil
        AreaSelector.shared.begin(on: screen, initial: keep) { rect in
            guard let id = screen.displayID, let choice = SourceChoice.confirmedArea(display: id, rect: rect) else { return }
            choice.apply(to: settings)
            // The overlay has left the screen by the time the countdown/recording starts.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { RecordingController.shared.begin() }
        }
    }
}

// MARK: - System audio

struct SystemAudioPopover: View {
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PopoverHeader(title: "System audio")
            SystemAudioPicker()
            Text("Sound played by apps and the system, without Yapcam's own sounds. Saved as its own track so you can mix it in the editor.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 280)
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
                ForEach(devices.microphones) { m in
                    SelectableRow(selected: settings.microphoneID == m.id) { settings.microphoneID = m.id } content: {
                        Text(DeviceLabels.menuName(m.name, isDefault: m.id == devices.defaultMicrophoneID)).lineLimit(1)
                    }
                }
                Divider()
                if settings.microphoneID != nil {
                    SelectableRow(selected: settings.cleanVoiceOnRecord) { settings.cleanVoiceOnRecord.toggle() } content: {
                        Text("Clean up voice (noise + level)")
                    }
                    .help("New recordings start with the editor's Clean up voice turned on")
                    SelectableRow(selected: settings.recordStereoMicrophone) { settings.recordStereoMicrophone.toggle() } content: {
                        Text("Record stereo microphone")
                    }
                    .help("Keeps both channels when the microphone has two. A mono microphone records mono.")
                }
                SelectableRow(selected: settings.microphoneID == nil) { settings.microphoneID = nil } content: {
                    Text("Don't record microphone")
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
        .onAppear { devices.reload() }       // the bar owns the level meter
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
                ForEach(devices.cameras) { c in
                    SelectableRow(selected: settings.cameraID == c.id) { settings.cameraID = c.id } content: {
                        Text(DeviceLabels.menuName(c.name, isDefault: c.id == devices.defaultCameraID)).lineLimit(1)
                    }
                }
                Divider()
                SelectableRow(selected: settings.cameraID == nil) { settings.cameraID = nil } content: { Text("Don't record camera") }
                if settings.cameraID != nil && !devices.isAvailable(camera: settings.cameraID) {
                    Label("Selected camera is not connected. Recording without it.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                } else if settings.cameraID != nil && !settings.hideCameraPreview {
                    CameraPreview(session: devices.previewSession, mirrored: settings.mirrorCamera)
                        .frame(height: 140).clipShape(RoundedRectangle(cornerRadius: 8))
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.8)))
                }
            }
            Divider()
            CameraResolutionRow()
            Toggle("Hide camera preview", isOn: $settings.hideCameraPreview)
            Toggle("Mirror camera", isOn: $settings.mirrorCamera)
                .help("Shows the camera like a mirror, in the preview and in new recordings")
        }
        .padding(14).frame(width: 280)
        .onAppear { devices.reload(); devices.startPreview(deviceID: settings.hideCameraPreview ? nil : settings.cameraID) }
        .onChange(of: settings.cameraID) { _, id in devices.startPreview(deviceID: settings.hideCameraPreview ? nil : id) }
        .onChange(of: settings.hideCameraPreview) { _, hide in devices.startPreview(deviceID: hide ? nil : settings.cameraID) }
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

// MARK: - After recording

struct AfterRecordingPopover: View {
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PopoverHeader(title: "After recording")
            ForEach(AfterRecording.allCases) { a in
                SelectableRow(selected: settings.afterRecording == a) { settings.afterRecording = a } content: { Text(a.title) }
            }
            Divider()
            SwitchRow("Create zooms automatically", isOn: $settings.createAutoZooms)
            SwitchRow("Show quick export widget", isOn: $settings.showQuickExportWidget)
            Text("Quick export: \(QuickExport.shortSummary(settings.quickExport)), set in Settings. The widget offers Copy, Save and Edit instead of opening the editor.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(width: 290)
    }
}
