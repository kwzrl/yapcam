import Foundation
import CYapcamCore

func validateFrame(_ f: YcFrame,configuration c: RenderConfiguration) throws {
    if let id=c.cursorSetID,VectorCursorLibrary.preset(id: id)==nil { throw RenderError.invalidSettings("Unknown original cursor set: \(id)") }
    func color(_ rgba: (Float,Float,Float,Float)) -> Bool { [rgba.0,rgba.1,rgba.2,rgba.3].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    func rect(_ r: YcRect,nonempty: Bool = false) -> Bool { [r.x,r.y,r.w,r.h].allSatisfy { $0.isFinite } && (nonempty ? r.w>0 && r.h>0 : r.w>=0 && r.h>=0) }
    let lengths=[f.screen_corner_radius,f.shadow_radius,f.inset_width,f.background_blur,f.camera_corner_radius,c.cameraShadowRadius,c.cursorSpotlightRadius]
    let unit=[f.shadow_opacity,f.motion_blur,f.cursor_opacity,f.camera_opacity,c.cursorMotionBlur,c.backgroundNoise,c.zoomMotionBlur ?? f.motion_blur,c.panMotionBlur ?? f.motion_blur]
    guard f.canvas_w>0, f.canvas_h>0, f.background_kind<=3, color(f.background_color), color(f.background_color2), color(f.inset_color), f.background_angle_deg.isFinite, f.shadow_offset_y.isFinite,
          lengths.allSatisfy({ $0.isFinite && $0>=0 }), unit.allSatisfy({ $0.isFinite && (0...1).contains($0) }), c.cursorRotationRadians.isFinite, f.click_progress.isFinite else { throw RenderError.invalidSettings("Frame contains invalid canvas, color or effect values") }
    if f.screen.present != 0 {
        guard rect(f.screen_dest), rect(f.screen_crop,nonempty: true), f.screen_crop.x>=0, f.screen_crop.y>=0, f.screen_crop.x+f.screen_crop.w<=1.000_001, f.screen_crop.y+f.screen_crop.h<=1.000_001 else { throw RenderError.invalidSettings("Screen crop or destination is invalid") }
    }
    if f.camera.present != 0 { guard rect(f.camera_dest), f.camera_shape<=2 else { throw RenderError.invalidSettings("Camera destination or shape is invalid") } }
    if f.cursor_visible != 0 { guard f.cursor_x.isFinite, f.cursor_y.isFinite, f.cursor_scale.isFinite, f.cursor_scale>=0 else { throw RenderError.invalidSettings("Cursor transform is invalid") } }
    if f.click_progress>=0 { guard f.click_x.isFinite, f.click_y.isFinite, f.click_progress<=1 else { throw RenderError.invalidSettings("Click effect is invalid") } }
}
