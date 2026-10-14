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
        var extras=try frameExtras(atNs: atNs)
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
        func color(_ value: (Float,Float,Float,Float)) -> SIMD4<Float> { SIMD4(value.0,value.1,value.2,value.3) }
        let count=Int(extras.highlight_count)
        var layers=withUnsafePointer(to: &extras.highlights) { tuple in
            let highlights=UnsafeRawPointer(tuple).assumingMemoryBound(to: YcFrameHighlight.self)
            return (0..<count).map { index in
                let h=highlights[index]
                return RenderLayer(content: .highlight(dimOpacity: h.dim_opacity,fill: color(h.fill),stroke: color(h.stroke),strokeWidth: h.stroke_width),rect: CGRect(x: h.rect.x,y: h.rect.y,width: h.rect.w,height: h.rect.h),cornerRadius: h.corner_radius,opacity: h.opacity)
            }
        }
        guard extras.fade_opacity.isFinite, (0...1).contains(extras.fade_opacity) else { throw RenderError.invalidSettings("Core returned invalid fade opacity") }
        if extras.fade_opacity>0 {
            layers.append(RenderLayer(content: .highlight(dimOpacity: 0,fill: SIMD4(0,0,0,1),stroke: .zero,strokeWidth: 0),rect: CGRect(origin: .zero,size: canvasSize),opacity: extras.fade_opacity))
        }
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
