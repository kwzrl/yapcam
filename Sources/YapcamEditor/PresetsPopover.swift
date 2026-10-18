import AppKit
import SwiftUI
import YapcamDesign

/// Presets dropdown (S-10): one click applies, create inline, never overwrite silently, Show in Finder.
public enum PresetCreateResult: Equatable, Sendable { case created, needsReplace, invalid }

extension EditorModel {
    /// Saves the current look as a preset. An existing name is only overwritten with `replace: true`.
    @discardableResult
    public func createPreset(named raw: String, replace: Bool = false) -> PresetCreateResult {
        let name = presetStore.clean(raw)
        guard !name.isEmpty else { return .invalid }
        if FileManager.default.fileExists(atPath: presetStore.url(name).path), !replace { return .needsReplace }
        savePreset(named: name)
        return lastError == nil ? .created : .invalid
    }
    /// Adds a preset file to the library (a unique name; never replaces one) and applies it. Returns the library name.
    @discardableResult
    public func importPresetFile(_ url: URL) -> String? {
        let base = presetStore.clean(url.deletingPathExtension().lastPathComponent)
        guard !base.isEmpty else { return nil }
        var name = base, n = 2
        while FileManager.default.fileExists(atPath: presetStore.url(name).path) { name = "\(base) \(n)"; n += 1 }
        do {
            try FileManager.default.createDirectory(at: presetStore.directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: presetStore.url(name))
        } catch { lastError = "Could not add the preset: \(error.localizedDescription)"; return nil }
        applyPreset(at: presetStore.url(name))
        return name
    }
    public func revealPreset(named name: String) { NSWorkspace.shared.activateFileViewerSelecting([presetStore.url(name)]) }
}

struct PresetsPopover: View {
    @ObservedObject var model: EditorModel
    @Binding var shown: Bool
    @State private var names: [String] = []
    @State private var newName = ""
    @State private var confirmReplace = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let recent = model.recentPresets().filter { names.contains($0) }
            if !recent.isEmpty {
                Text("Recently used").font(Yap.Font.caption).foregroundStyle(Yap.caption)
                ForEach(recent, id: \.self) { row($0) }
                Divider().opacity(0.3)
            }
            Text("Presets").font(Yap.Font.caption).foregroundStyle(Yap.caption)
            if names.isEmpty { Text("No presets yet").font(Yap.Font.body).foregroundStyle(Yap.caption) }
            ScrollView { VStack(alignment: .leading, spacing: 2) { ForEach(names, id: \.self) { row($0) } } }.frame(maxHeight: 220)
            Text("A preset is a snapshot. After changing the project, use Update in the gear menu to save the change into it.")
                .font(Yap.Font.caption).foregroundStyle(Yap.caption).fixedSize(horizontal: false, vertical: true)
            Divider().opacity(0.3)
            Button("Import preset…") { importPreset() }.buttonStyle(.plain).foregroundStyle(Yap.label)
            HStack(spacing: 6) {
                TextField("New preset name…", text: $newName).textFieldStyle(.roundedBorder).focused($focused).onSubmit { create() }
                Button("Create preset") { create() }.disabled(model.presetStore.clean(newName).isEmpty)
            }
        }
        .padding(14).frame(width: 340)
        .onAppear(perform: refresh)
        .confirmationDialog("Replace the preset “\(model.presetStore.clean(newName))”?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Replace", role: .destructive) { _ = model.createPreset(named: newName, replace: true); newName = ""; refresh() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func importPreset() {
        let panel = NSOpenPanel(); panel.allowsOtherFileTypes = true; panel.message = "Choose a Yapcam preset file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if model.importPresetFile(url) != nil { shown = false }
        refresh()
    }

    private func create() {
        switch model.createPreset(named: newName) {
        case .created: newName = ""; refresh()
        case .needsReplace: confirmReplace = true
        case .invalid: break
        }
    }

    private func row(_ n: String) -> some View {
        let badges = [model.presetMatchesProject(named: n) ? "Matches project" : nil, model.presetStore.defaultName == n ? "Default" : nil].compactMap { $0 }
        return HStack(spacing: 6) {
            Button { model.applyPreset(at: model.presetStore.url(n)); shown = false } label: {
                HStack {
                    Text(n).font(Yap.Font.body).foregroundStyle(Yap.label).lineLimit(1)
                    Spacer(minLength: 4)
                    if !badges.isEmpty { Text(badges.joined(separator: " · ")).font(Yap.Font.caption).foregroundStyle(Yap.caption) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Click to apply")
            Menu {
                Button("Rename…") { if let new = EditorPresets.promptName(title: "Rename preset", initial: n, confirm: "Rename") { model.renamePreset(from: n, to: new); refresh() } }
                Button("Update to match current project") { model.updatePreset(named: n) }
                Button(model.presetStore.defaultName == n ? "Don't use as default" : "Use as default for new projects") {
                    model.presetStore.defaultName = model.presetStore.defaultName == n ? nil : n
                }
                Button("Show in Finder") { model.revealPreset(named: n) }
                Divider()
                Button("Remove…", role: .destructive) { model.removePreset(named: n); refresh() }
            } label: { Image(systemName: "gearshape").font(.system(size: 11)).foregroundStyle(Yap.caption) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Options for preset \(n)")
        }
        .padding(.vertical, 3)
    }

    private func refresh() { let n = model.presetStore.names(); if n != names { names = n } }
}
