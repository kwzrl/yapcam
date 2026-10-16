import AppKit
import SwiftUI
import YapcamCapture

/// What "System audio" records (GAP-CAP-1). Existing users keep "All apps" when their old on/off toggle was on.
enum SystemAudioChoice: String, CaseIterable, Identifiable {
    case off, all, selected
    var id: String { rawValue }
    var title: String { switch self { case .off: "Off"; case .all: "All apps"; case .selected: "Selected apps" } }
}

extension AppSettings {
    var systemAudioChoice: SystemAudioChoice {
        get { !systemAudio ? .off : (systemAudioSelectedOnly ? .selected : .all) }
        set {
            systemAudio = newValue != .off
            if newValue != .off { systemAudioSelectedOnly = newValue == .selected }
        }
    }
    /// nil = all apps (or audio off); otherwise the bundle ids to record.
    var systemAudioAppsForRecording: [String]? { systemAudio && systemAudioSelectedOnly ? systemAudioApps : nil }

    func setApp(_ bundleID: String, selected: Bool) {
        var ids = systemAudioApps.filter { $0 != bundleID }
        if selected { ids.append(bundleID) }
        systemAudioApps = ids
    }
}

/// Running apps that can be picked for system audio. Loading needs Screen Recording permission, like capture itself.
@MainActor final class AudioAppsModel: ObservableObject {
    static let shared = AudioAppsModel()
    @Published private(set) var running: [CaptureApplication] = []
    @Published private(set) var loaded = false
    var load: () async -> [CaptureApplication] = {
        ((try? await CaptureSources.load(includeWindowThumbnails: false))?.applications) ?? []
    }

    func refresh() async {
        running = await load()
        loaded = true
    }

    /// Running apps plus chosen ones that are not running now (shown so they can be unchecked).
    func rows(selected: [String], search: String) -> [CaptureApplication] {
        let known = Set(running.map(\.bundleID))
        let missing = selected.filter { !known.contains($0) }.map { CaptureApplication(bundleID: $0, name: $0) }
        let all = running + missing
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.bundleID.localizedCaseInsensitiveContains(q) }
    }
}

/// Off / All apps / Selected apps, with a checklist for the last.
struct SystemAudioPicker: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var apps = AudioAppsModel.shared
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("System audio", selection: $settings.systemAudioChoice) {
                ForEach(SystemAudioChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityLabel("System audio source")
            if settings.systemAudioChoice == .selected { checklist }
        }
        .task { if settings.systemAudioChoice == .selected { await apps.refresh() } }
        .onChange(of: settings.systemAudioChoice) { _, c in if c == .selected { Task { await apps.refresh() } } }
    }

    @ViewBuilder private var checklist: some View {
        let rows = apps.rows(selected: settings.systemAudioApps, search: search)
        if apps.running.count > 8 { TextField("Search apps", text: $search).textFieldStyle(.roundedBorder) }
        if apps.loaded && apps.running.isEmpty && settings.systemAudioApps.isEmpty {
            Text("No running apps found. Screen recording permission is needed to list them.").font(.caption).foregroundStyle(.secondary)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { app in
                    let isRunning = apps.running.contains { $0.bundleID == app.bundleID }
                    Toggle(isOn: Binding(get: { settings.systemAudioApps.contains(app.bundleID) },
                                         set: { settings.setApp(app.bundleID, selected: $0) })) {
                        HStack(spacing: 6) {
                            Image(nsImage: Self.icon(app.bundleID)).resizable().frame(width: 16, height: 16)
                            Text(isRunning ? app.name : "\(app.name) (not running)").lineLimit(1)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        .frame(maxHeight: 180)
        if settings.systemAudioApps.isEmpty {
            Label("Choose at least one app, or recording will ask what to do.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    static func icon(_ bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
    }
}
