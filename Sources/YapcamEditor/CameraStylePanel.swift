import SwiftUI
import UniformTypeIdentifiers
import YapcamDesign

/// "Camera style": color look presets (twelve original recipes), custom grading, `.cube` LUT, sharpen, grain, background blur,
/// camera crop, mirror and face tracking. Grading is evaluated by core and drawn by render.
struct CameraStylePanel: View {
    @ObservedObject var model: EditorModel
    private var preset: String { model.string("camera.style.preset", default: "original") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorGroup("Color look", first: true) { look }
            InspectorGroup("Finish") {
                ToggleRow(model: model, title: "Mirror", path: "camera.mirrored", defaultValue: true)
                ToggleRow(model: model, title: "Follow face (framing)", path: "camera.face_framing")
                ToggleRow(model: model, title: "Remove background", path: "camera.background_removal")
                InspectorMore {
                    NumberRow(model: model, title: "Sharpen", path: "camera.style.sharpen", range: 0...1, defaultValue: 0)
                    NumberRow(model: model, title: "Grain", path: "camera.style.grain", range: 0...1, defaultValue: 0)
                    NumberRow(model: model, title: "Background blur", path: "camera.style.background_blur", range: 0...1, defaultValue: 0)
                }
            }
            InspectorGroup("Shape") { shape }
        }
    }

    @ViewBuilder private var look: some View {
        if let size = model.project.cameraPixelSize { InspectorInfo("Recorded at", "\(size.width) × \(size.height)") }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            tile("Original", id: "original")
            ForEach(model.project.cameraRecipes) { r in tile(r.name, id: r.id) }
            if preset == "custom" { tile("Custom", id: "custom") }
            if preset == "lut" { tile("LUT", id: "lut") }
        }
        if preset != "original" { NumberRow(model: model, title: "Intensity", path: "camera.style.intensity", range: 0...1, defaultValue: 1) }
        if preset != "original" && preset != "lut" {
            InspectorMore("Adjust the look") {
                NumberRow(model: model, title: "Warmth", path: "camera.style.warmth", range: -1...1, defaultValue: 0)
                NumberRow(model: model, title: "Background pop", path: "camera.style.background_pop", range: 0...1, defaultValue: 0.2)
                NumberRow(model: model, title: "Contrast", path: "camera.style.contrast", range: -1...1, defaultValue: 0.25)
                NumberRow(model: model, title: "Color intensity", path: "camera.style.color_intensity", range: -1...1, defaultValue: 0.15)
                InspectorNote("Changing a value switches to a custom look.")
            }
        }
        InspectorMore("Color lookup table", value: lutName) {
            InspectorAction("Import .cube file…", symbol: "square.and.arrow.down") { chooseLUT() }
            InspectorNote("The file is copied into the project.")
        }
    }

    @ViewBuilder private var shape: some View {
        PickerRow(model: model, title: "Shape", path: "camera.shape",
                  options: [("Rounded rectangle", "rounded_rect"), ("Circle", "circle"), ("Squircle", "squircle")])
        NumberRow(model: model, title: "Corner radius", path: "camera.radius", range: 0...64, unit: "pt", format: "%.0f", defaultValue: 24)
        NumberRow(model: model, title: "Opacity", path: "camera.opacity", range: 0...1, defaultValue: 1)
        NumberRow(model: model, title: "Shadow", path: "camera.shadow_radius", range: 0...60, unit: "pt", format: "%.0f", defaultValue: 0)
        InspectorMore("Crop camera", value: cropValue) { CropSection(model: model, path: "camera.style.crop", title: "") }
    }

    private var lutName: String {
        if preset == "lut", case .string(let path)? = model.value("camera.style.lut_path") { return (path as NSString).lastPathComponent }
        return ""
    }
    private var cropValue: String {
        let c = model.cropInsets(path: "camera.style.crop")
        return c.left + c.top + c.right + c.bottom == 0 ? "" : "On"
    }

    private func tile(_ title: String, id: String) -> some View {
        InspectorTile(selected: preset == id, label: "Color look \(title)") {
            if id != "custom" && id != "lut" { model.set("camera.style.preset", string: id) }
        } content: {
            Text(title).font(Yap.Font.caption).lineLimit(1).padding(.vertical, 2)
        }
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
