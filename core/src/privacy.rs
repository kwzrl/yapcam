//! Cold, authoritative mask provenance for source pre-processing and loupe sampling.
use crate::{
    layers::mask_rect_at,
    project::{Project, Result},
};
use serde_json::{json, Value};
impl Project {
    pub fn privacy_masks_at(&self, tl_ns: i64) -> Result<Value> {
        let f = self.frame(tl_ns)?;
        let size = self.session.tracks.screen.pixel_size;
        let crop = f.screen_crop;
        let dest = f.screen_dest;
        let scale = if f.screen.present != 0 && dest.w > 0.0 && dest.h > 0.0 {
            let value = [
                crop.w * size[0] as f64 / dest.w,
                crop.h * size[1] as f64 / dest.h,
            ];
            value
                .iter()
                .all(|v| v.is_finite() && *v > 0.0)
                .then_some(value)
        } else {
            None
        };
        let masks:Vec<_>=self.data.canvas.highlights.iter().enumerate()
            .filter(|(_,h)|h.enabled && tl_ns>=h.tl_start_ns && tl_ns<h.tl_end_ns)
            .map(|(order,h)|json!({"id":h.id,"order":order,"purpose":"privacy_mask",
                "space":h.space,"kind":h.kind,"rect":mask_rect_at(h,tl_ns),
                "tl_start_ns":h.tl_start_ns,"tl_end_ns":h.tl_end_ns,
                "corner_radius":h.radius,"blur_radius":if h.kind=="blur" {Some(h.blur_radius)} else {None},
                "opacity":h.opacity,"dim_opacity":h.dim_opacity,"fill":h.fill,
                "stroke":h.stroke,"stroke_width":h.stroke_width})).collect();
        Ok(json!({"schema_version":1,"tl_ns":tl_ns,"screen":{
            "present":f.screen.present!=0,"segment":f.screen.segment,"src_ns":f.screen.src_ns,
            "file_ns":f.screen.file_ns,"pixel_size":size,"canvas_size":[f.canvas_w,f.canvas_h],
            "crop":[crop.x,crop.y,crop.w,crop.h],"dest":[dest.x,dest.y,dest.w,dest.h],
            "source_pixels_per_canvas_pixel":scale},"masks":masks}))
    }
}
