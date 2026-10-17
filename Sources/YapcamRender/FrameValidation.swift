import Foundation
import CYapcamCore

func validateFrame(_ f: YcFrame,configuration c: RenderConfiguration,layers: [RenderLayer] = []) throws {
    try c.glassLoupe?.validate()
    try c.cameraColor.validate()
    try c.validateCameraGeometry()
    try c.screenQuality?.validate()
    try c.cameraMatte?.validate()
    for layer in layers {
        try layer.validatePurpose()
        if case .blur(let radius) = layer.content {
            try MaskBlur.validate(radius: radius)
            // Like opaque covers, source-space privacy masks must not be
            // bypassed by a local lens sampling an uncovered source region.
            if c.glassLoupe != nil,f.screen.present != 0,layer.opacity>0,radius>0 {
                let coversCanvas=layer.cornerRadius == 0 && layer.rect.minX<=0 && layer.rect.minY<=0 && layer.rect.maxX>=CGFloat(f.canvas_w) && layer.rect.maxY>=CGFloat(f.canvas_h)
                guard coversCanvas else { throw RenderError.unavailable("Glass magnifier cannot be combined with a blur mask yet; use classic zoom for that range") }
            }
        }
    }
    guard c.screenShadowOffsetX.isFinite, (-1...1).contains(c.screenInsetOrigin.x), (-1...1).contains(c.screenInsetOrigin.y) else {
        throw RenderError.invalidSettings("Screen shadow offset or inset origin is invalid")
    }
    if c.glassLoupe != nil, f.screen.present != 0 {
        for layer in layers {
            if case .highlight(let dim,let fill,let stroke,let width) = layer.content,
               layer.purpose != .textBackground,
               fill.w*layer.opacity >= 0.999 || (layer.purpose == .privacyMask && layer.opacity > 0 && (fill.w>0 || dim>0 || (stroke.w>0 && width>0))) {
                let coversCanvas = layer.cornerRadius == 0 && layer.rect.minX <= 0 && layer.rect.minY <= 0 && layer.rect.maxX >= CGFloat(f.canvas_w) && layer.rect.maxY >= CGFloat(f.canvas_h)
                guard coversCanvas else { throw RenderError.unavailable("Glass magnifier cannot be combined with a cover mask yet; use classic zoom for that range") }
            }
        }
    }
    if let id=c.cursorSetID,!VectorCursorLibrary.catalog.contains(where: { $0.id == id }) { throw RenderError.invalidSettings("Unknown original cursor set: \(id)") }
    guard c.cursorVariants.keys.allSatisfy({ VectorCursorStyle(shapeID: $0) != nil }) else { throw RenderError.invalidSettings("Unknown cursor variant shape") }
    func color(_ rgba: (Float,Float,Float,Float)) -> Bool { [rgba.0,rgba.1,rgba.2,rgba.3].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    func rect(_ r: YcRect,nonempty: Bool = false) -> Bool { [r.x,r.y,r.w,r.h].allSatisfy { $0.isFinite } && (nonempty ? r.w>0 && r.h>0 : r.w>=0 && r.h>=0) }
    let lengths=[f.screen_corner_radius,f.shadow_radius,f.inset_width,f.background_blur,f.camera_corner_radius,c.cameraShadowRadius,c.cursorSpotlightRadius]
    let unit=[f.shadow_opacity,f.motion_blur,f.cursor_opacity,f.camera_opacity,c.cursorMotionBlur,c.backgroundNoise,c.zoomMotionBlur ?? f.motion_blur,c.panMotionBlur ?? f.motion_blur]
    guard f.canvas_w>0, f.canvas_h>0, f.background_kind<=3, color(f.background_color), color(f.background_color2), color(f.inset_color), f.background_angle_deg.isFinite, f.shadow_offset_y.isFinite,
          lengths.allSatisfy({ $0.isFinite && $0>=0 }), unit.allSatisfy({ $0.isFinite && (0...1).contains($0) }), c.cursorRotationRadians.isFinite, f.click_progress.isFinite else { throw RenderError.invalidSettings("Frame contains invalid canvas, color or effect values") }
    if f.screen.present != 0 {
        guard rect(f.screen_dest), rect(f.screen_crop,nonempty: true), f.screen_crop.x>=0, f.screen_crop.y>=0, f.screen_crop.x+f.screen_crop.w<=1.000_001, f.screen_crop.y+f.screen_crop.h<=1.000_001 else { throw RenderError.invalidSettings("Screen crop or destination is invalid") }
        if let loupe = c.glassLoupe {
            let b = loupe.samplingBase(f), r = f.screen_crop
            guard r.x >= Double(b.x)-0.000001, r.y >= Double(b.y)-0.000001,
                  r.x+r.w <= Double(b.x+b.z)+0.000001, r.y+r.h <= Double(b.y+b.w)+0.000001 else { throw RenderError.invalidSettings("Magnifier zoom lies outside the selected source crop") }
            if let instruction=loupe.instruction {
                let p=instruction.sourceCenter
                guard p.x>=b.x-0.000001,p.y>=b.y-0.000001,p.x<=b.x+b.z+0.000001,p.y<=b.y+b.w+0.000001 else { throw RenderError.invalidSettings("Lens focus lies outside selected source crop") }
            }
        }
    }
    if f.camera.present != 0 { guard rect(f.camera_dest), f.camera_shape<=2 else { throw RenderError.invalidSettings("Camera destination or shape is invalid") } }
    if f.cursor_visible != 0 { guard f.cursor_x.isFinite, f.cursor_y.isFinite, f.cursor_scale.isFinite, f.cursor_scale>=0 else { throw RenderError.invalidSettings("Cursor transform is invalid") } }
    if f.click_progress>=0 { guard f.click_x.isFinite, f.click_y.isFinite, f.click_progress<=1 else { throw RenderError.invalidSettings("Click effect is invalid") } }
}
