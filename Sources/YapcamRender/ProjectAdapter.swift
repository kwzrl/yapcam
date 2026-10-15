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
    public func renderAudioOverlays() throws -> [AudioOverlay] {
        try query("{\"q\":\"audio_overlays\"}",as: [EvaluatedAudioOverlay].self).map { try $0.overlay() }
    }
    public func renderEffects(atNs: Int64,canvasSize: CGSize) throws -> RenderFrameEffects {
        let extras=try frameExtras(atNs: atNs)
        guard extras.highlight_count<=YC_MAX_FRAME_HIGHLIGHTS else {
            throw RenderError.invalidSettings("Core returned unsupported frame effects")
        }
        var configuration=RenderConfiguration()
        // Core "pointer", including always_default, denotes the system arrow.
        // The separately authored pointing hand is an explicit cursor.shape.
        switch extras.cursor_style {
        case 0: configuration.cursorStyle = .recorded
        case 1,3: configuration.cursorStyle = .arrow
        case 2: configuration.cursorStyle = .touch
        default: throw RenderError.invalidSettings("Core returned unsupported cursor style: \(extras.cursor_style)")
        }
        // These selections are root settings. Read Core's effective shape so
        // always_default wins over a stored shape, without changing frame scale.
        let evaluated=try query("{\"q\":\"render_options_at\",\"tl_ns\":\(atNs)}",as: ProjectRenderOptions.self)
        let options=evaluated.base
        configuration.glassLoupe=evaluated.glassLoupe
        configuration.cameraColor=try evaluated.cameraColor?.value(package: packageURL) ?? .init()
        configuration.cursorSetID=options.cursorSetId
        if let shape=options.cursorShape {
            switch shape {
            case .arrow: configuration.cursorStyle = .arrow
            case .pointingHand: configuration.cursorStyle = .pointer
            case .touch: configuration.cursorStyle = .touch
            case .text: configuration.cursorStyle = .text
            case .resizeHorizontal: configuration.cursorStyle = .resizeHorizontal
            case .resizeVertical: configuration.cursorStyle = .resizeVertical
            case .resizeDiagonalNWSE: configuration.cursorStyle = .resizeDiagonalNWSE
            case .resizeDiagonalNESW: configuration.cursorStyle = .resizeDiagonalNESW
            case .openHand: configuration.cursorStyle = .openHand
            case .closedHand: configuration.cursorStyle = .closedHand
            }
        }
        switch options.cursorLogicalSize {
        case .small: configuration.cursorSize = .small
        case .regular: configuration.cursorSize = .regular
        case .large: configuration.cursorSize = .large
        case .extraLarge: configuration.cursorSize = .extraLarge
        }
        let motion=try frameMotion(atNs: atNs)
        configuration.cursorRotationRadians=motion.cursor_rotation_rad
        configuration.zoomMotionBlur=motion.zoom_motion_blur
        configuration.panMotionBlur=motion.pan_motion_blur
        configuration.cursorMotionBlur=motion.cursor_motion_blur
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
    convenience init(project: Project,speechEnhancement: SpeechEnhancementSettings? = nil) throws {
        try self.init(project: project as any RenderProjectSource,speechEnhancement: speechEnhancement)
        observeChanges(name: Project.didChange,object: project)
    }
}

public extension Exporter {
    convenience init(project: Project,settings: ExportSettings,destination: URL) throws { try self.init(project: project as any RenderProjectSource,settings: settings,destination: destination) }
}
