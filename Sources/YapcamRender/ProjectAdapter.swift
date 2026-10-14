import YapcamCore
import Metal
import Foundation

extension Project: RenderProjectSource {
    public func renderSnapshot() throws -> any RenderProjectSource { try snapshot() }
    public func renderClips() throws -> [RenderClip] {
        try query("{\"q\":\"clips\"}",as: [ClipInfo].self).map { RenderClip(srcStartNs: $0.srcStartNs,srcEndNs: $0.srcEndNs,speed: $0.speed) }
    }
    public func renderBackgroundAsset(index: UInt32) throws -> URL {
        try mediaURL(atIndex: index)
    }
    public func renderAudioRanges() throws -> [RenderAudioRange]? {
        try query("{\"q\":\"audio_ranges\"}",as: [RenderAudioRange].self)
    }
    public func renderEffects(atNs: Int64,canvasSize: CGSize) throws -> RenderFrameEffects {
        let extras=try frameExtras(atNs: atNs)
        guard extras.cursor_style<=2, extras.highlight_count<=YC_MAX_FRAME_HIGHLIGHTS else {
            throw RenderError.invalidSettings("Core returned unsupported frame effects")
        }
        var configuration=RenderConfiguration()
        configuration.cursorStyle=extras.cursor_style==1 ? .pointer : extras.cursor_style==2 ? .touch : .recorded
        configuration.cursorMotionBlur=extras.cursor_motion_blur
        configuration.cursorSpotlightRadius=extras.cursor_spotlight_radius
        configuration.backgroundNoise=extras.background_noise
        configuration.windowChrome=extras.window_chrome != 0
        configuration.cameraBackgroundRemoval=extras.camera_background_removal != 0
        configuration.cameraFaceFraming=extras.camera_face_framing != 0
        configuration.cameraShadowRadius=extras.camera_shadow_radius
        guard extras.fade_opacity.isFinite, (0...1).contains(extras.fade_opacity) else { throw RenderError.invalidSettings("Core returned invalid fade opacity") }
        // UTF-8 text/emoji payloads use Core's evaluated cold layers. This complete list
        // includes annotation/caption backgrounds, highlights and the final fade once.
        let rows=try query("{\"q\":\"layers_at\",\"tl_ns\":\(atNs)}",as: [CoreDrawingLayer].self)
        let layers=try rows.map { try $0.drawingLayer() }
        return RenderFrameEffects(configuration: configuration,layers: layers)
    }
}

public extension FrameCompositor {
    convenience init(device: MTLDevice,project: Project) throws { try self.init(device: device,project: project as any RenderProjectSource) }
}

@MainActor public extension PreviewPlayer {
    convenience init(project: Project) throws {
        try self.init(project: project as any RenderProjectSource)
        observeChanges(name: Project.didChange,object: project)
    }
}

public extension Exporter {
    convenience init(project: Project,settings: ExportSettings,destination: URL) throws { try self.init(project: project as any RenderProjectSource,settings: settings,destination: destination) }
}
