import SwiftUI
import YapcamCore
import YapcamRender
import YapcamDesign

/// Zoom panel commands (BS-11).
extension EditorModel {
    /// "Use for new zooms": this zoom's level becomes `zoom_settings.default_scale` (new zooms and the 0 key use it). One undo step.
    /// Mode and transition length are not stored as defaults yet (needs a core field; see docs/status/inspector.md).
    public func useZoomForNewZooms(id: String) {
        guard let z = zooms.first(where: { $0.id == id }) else { return }
        set("zoom_settings.default_scale", number: min(max(z.scale, zoomLevelRange.lowerBound), zoomLevelRange.upperBound))
    }
}

// MARK: manual target thumbnail (BS-12)

extension EditorModel {
    /// Sets the focus of a zoom from a point in the unzoomed frame (0…1 on both axes, top-left origin). Clamped by `0.5 / scale`
    /// like every other focus edit; one undo step.
    public func setZoomTarget(id: String, unit: CGPoint) {
        setZoomFocus(id: id, x: Double(min(max(unit.x, 0), 1)), y: Double(min(max(unit.y, 0), 1)))
    }

    /// The recording's screen frame at the zoom's midpoint, without zoom, cursor or background. Nil for projects that cannot render.
    func unzoomedFrame(for zoom: TimelineZoom) async -> CGImage? {
        guard let core = project as? CoreEditingProject, let snapshot = try? core.project.snapshot() else { return nil }
        let mid = (zoom.startNs + zoom.endNs) / 2
        struct Box: @unchecked Sendable { let p: Project }
        let box = Box(p: snapshot)
        return await Task.detached(priority: .userInitiated) {
            guard let renderer = try? AgentFrameRenderer(snapshot: box.p) else { return nil }
            return try? renderer.grab(atNs: mid, source: "screen")
        }.value
    }
}

/// 16:9-ish picture of the unzoomed frame with a dot at the zoom target; click or drag to move it.
struct ZoomTargetThumbnail: View {
    @ObservedObject var model: EditorModel
    let zoom: TimelineZoom
    @State private var image: CGImage?
    @State private var dragging: CGPoint?

    var body: some View {
        let focus = dragging ?? CGPoint(x: zoom.focusX, y: zoom.focusY)
        let aspect = image.map { CGFloat($0.width) / max(CGFloat($0.height), 1) } ?? 16.0 / 9
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() } else { Rectangle().fill(Color.white.opacity(0.06)) }
                Circle().fill(Color(red: 0.62, green: 0.48, blue: 1)).overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .frame(width: 14, height: 14)
                    .position(x: focus.x * geo.size.width, y: focus.y * geo.size.height)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in dragging = Self.unit(v.location, in: geo.size) }
                .onEnded { v in dragging = nil; model.setZoomTarget(id: zoom.id, unit: Self.unit(v.location, in: geo.size)) })
        }
        .aspectRatio(aspect, contentMode: .fit)
        .task(id: zoom.id) { image = await model.unzoomedFrame(for: zoom) }
        .accessibilityLabel("Zoom target")
        .accessibilityValue(String(format: "%.0f %%, %.0f %%", zoom.focusX * 100, zoom.focusY * 100))
    }

    static func unit(_ p: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: min(max(p.x / size.width, 0), 1), y: min(max(p.y / size.height, 0), 1))
    }
}
