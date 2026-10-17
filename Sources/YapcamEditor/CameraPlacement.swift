import SwiftUI
import YapcamCore
import YapcamDesign

/// Camera placement helpers shared by the global camera position grid and the per-layout one (CAM-15/16), plus Roundness (CAM-04).
public enum CameraPlacement {
    /// Stored positions of the 3×3 grid (columns, rows). Centre is (0.5, 0.5).
    public static let xs = [0.18, 0.5, 0.82], ys = [0.22, 0.5, 0.78]
    public static let roundnessMaxRadius = 64.0
    public static let defaultRadius = 24.0

    /// Grid cell (row, column) closest to a stored position within tolerance; nil when unset or between cells.
    public static func cell(of position: [Double]?) -> (Int, Int)? {
        guard let p = position, p.count == 2,
              let c = xs.firstIndex(where: { abs($0 - p[0]) < 0.02 }), let r = ys.firstIndex(where: { abs($0 - p[1]) < 0.02 }) else { return nil }
        return (r, c)
    }
}

extension EditorModel {
    /// Own camera position of a layout section, or nil when it inherits `camera.position`.
    public func layoutCameraPosition(id: String) -> [Double]? { layouts.first { $0.id == id }?.cameraPosition }
    public func layoutCameraSize(id: String) -> Double? { layouts.first { $0.id == id }?.cameraSize }

    /// Position for one layout section (nil = inherit). One undo step.
    public func setLayoutCameraPosition(id: String, _ position: [Double]?) {
        writeLayoutList(layouts.map { var l = $0; if l.id == id { l.cameraPosition = position }; return l })
    }
    /// Size for one layout section as a fraction of the canvas (nil = inherit `camera.size`). Clamped to the global range.
    public func setLayoutCameraSize(id: String, _ size: Double?) {
        writeLayoutList(layouts.map { var l = $0; if l.id == id { l.cameraSize = size.map { min(max($0, 0.1), 0.75) } }; return l })
    }

    // MARK: roundness (CAM-04): one 0…100 % control; 100 % is a circle.
    public var cameraRoundness: Double {
        if string("camera.shape", default: "rounded_rect") == "circle" { return 1 }
        return min(1, number("camera.radius", default: CameraPlacement.defaultRadius) / CameraPlacement.roundnessMaxRadius)
    }
    /// Sets the corner radius; at 100 % the shape becomes a circle, below it a circle goes back to a rounded rectangle.
    public func setCameraRoundness(_ r: Double) {
        let r = min(max(r, 0), 1)
        if r >= 0.995 { set("camera.shape", string: "circle"); return }
        var cmds: [EditorCommand] = [.set(path: "camera.radius", value: .number((r * CameraPlacement.roundnessMaxRadius).rounded()))]
        if string("camera.shape", default: "rounded_rect") == "circle" { cmds.append(.set(path: "camera.shape", value: .string("rounded_rect"))) }
        perform(.batch(cmds))
    }
}

/// Overlay controls of one layout section: its own position (9 cells) and an optional own size.
struct LayoutPlacementRows: View {
    @ObservedObject var model: EditorModel
    let layout: LayoutSegment
    var body: some View {
        PositionGrid(title: "Camera position", current: layout.cameraPosition) { model.setLayoutCameraPosition(id: layout.id, $0) }
        if layout.cameraPosition != nil {
            InspectorAction("Use the default position") { model.setLayoutCameraPosition(id: layout.id, nil) }
        }
        SwitchRow("Custom camera size", isOn: Binding(get: { layout.cameraSize != nil },
                                                      set: { model.setLayoutCameraSize(id: layout.id, $0 ? model.number("camera.size", default: 0.22) : nil) }))
        if let size = layout.cameraSize {
            CommitSlider(title: "Size", range: 0.1...0.75, get: { size }, commit: { model.setLayoutCameraSize(id: layout.id, $0) },
                         text: { "\(Int(($0 * 100).rounded())) %" }, defaultValue: model.number("camera.size", default: 0.22))
                .id(layout.id)
        }
        InspectorNote("Uses a different position or size while this layout is active.")
    }
}
