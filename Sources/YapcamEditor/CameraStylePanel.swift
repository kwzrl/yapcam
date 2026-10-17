import SwiftUI
import UniformTypeIdentifiers

/// "Camera style": color look presets (twelve original recipes), custom grading, `.cube` LUT, sharpen, grain, background blur,
/// camera crop, mirror and face tracking. Grading is evaluated by core and drawn by render.
struct CameraStylePanel: View {
    @ObservedObject var model: EditorModel
    private var preset: String { model.string("camera.style.preset", default: "original") }

    var body: some View {
        if let size = model.project.cameraPixelSize {
            Section { LabeledContent("Recorded at") { Text("\(size.width) × \(size.height)").monospacedDigit() } }
        }
        Section("Color look") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], spacing: 6) {
                tile("Original", id: "original")
                ForEach(model.project.cameraRecipes) { r in tile(r.name, id: r.id) }
                if preset == "custom" { tile("Custom", id: "custom") }
                if preset == "lut" { tile("LUT", id: "lut") }
            }
            if preset != "original" { NumberRow(model: model, title: "Intensity", path: "camera.style.intensity", range: 0...1, defaultValue: 1) }
        }
        if preset != "original" && preset != "lut" {
            Section("Adjust the look") {
                NumberRow(model: model, title: "Warmth", path: "camera.style.warmth", range: -1...1, defaultValue: 0)
                NumberRow(model: model, title: "Background pop", path: "camera.style.background_pop", range: 0...1, defaultValue: 0.2)
                NumberRow(model: model, title: "Contrast", path: "camera.style.contrast", range: -1...1, defaultValue: 0.25)
                NumberRow(model: model, title: "Color intensity", path: "camera.style.color_intensity", range: -1...1, defaultValue: 0.15)
                Text("Changing a value switches to a custom look.").font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Color lookup table") {
            Button("Import .cube file…") { chooseLUT() }
            if preset == "lut", case .string(let path)? = model.value("camera.style.lut_path") {
                Text((path as NSString).lastPathComponent).font(.caption).foregroundStyle(.secondary)
            }
            Text("The file is copied into the project.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Finish") {
            NumberRow(model: model, title: "Sharpen", path: "camera.style.sharpen", range: 0...1, defaultValue: 0)
            NumberRow(model: model, title: "Grain", path: "camera.style.grain", range: 0...1, defaultValue: 0)
            NumberRow(model: model, title: "Background blur", path: "camera.style.background_blur", range: 0...1, defaultValue: 0)
            ToggleRow(model: model, title: "Mirror", path: "camera.mirrored", defaultValue: true)
            ToggleRow(model: model, title: "Follow face (framing)", path: "camera.face_framing")
            ToggleRow(model: model, title: "Remove background", path: "camera.background_removal")
        }
        Section("Shape") {
            PickerRow(model: model, title: "Shape", path: "camera.shape",
                      options: [("Rounded rectangle", "rounded_rect"), ("Circle", "circle"), ("Squircle", "squircle")])
            NumberRow(model: model, title: "Corner radius", path: "camera.radius", range: 0...64, unit: "pt", format: "%.0f", defaultValue: 24)
            NumberRow(model: model, title: "Opacity", path: "camera.opacity", range: 0...1, defaultValue: 1)
            NumberRow(model: model, title: "Shadow", path: "camera.shadow_radius", range: 0...60, unit: "pt", format: "%.0f", defaultValue: 0)
        }
        CropSection(model: model, path: "camera.style.crop", title: "Crop camera")
    }

    private func tile(_ title: String, id: String) -> some View {
        Button { if id != "custom" && id != "lut" { model.set("camera.style.preset", string: id) } } label: {
            Text(title).font(.caption).lineLimit(1).frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(preset == id ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(preset == id ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain).accessibilityLabel("Color look \(title)")
        .accessibilityAddTraits(preset == id ? [.isButton, .isSelected] : .isButton)
    }

    private func chooseLUT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.importCameraLUT(url) }
    }
}

extension EditorModel {
    public func importCameraLUT(_ url: URL) {
        guard !isClosed else { return }
        do { try project.importCameraLUT(url); noteExternalEdit() }
        catch { lastError = "Couldn't use the LUT: \(error.localizedDescription)" }
    }
}
