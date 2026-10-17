//! Stateless ABI-v2 extras and cold-path drawing instructions.
//! Geometry comes from the same frame evaluator used by preview and export.
use crate::{
    frame::{Frame, Rect},
    model::{Animation, Highlight, TextRecord},
    project::{Error, Project, Result},
    time,
};
use serde_json::{json, Value};

pub const MAX_FRAME_HIGHLIGHTS: usize = 32;
#[derive(Clone, Copy, Debug, Default, PartialEq)]
#[repr(C)]
pub struct FrameHighlight {
    pub rect: Rect,
    pub corner_radius: f32,
    pub opacity: f32,
    pub dim_opacity: f32,
    pub fill: [f32; 4],
    pub stroke: [f32; 4],
    pub stroke_width: f32,
}
#[derive(Clone, Copy, Debug, Default, PartialEq)]
#[repr(C)]
pub struct FrameExtras {
    pub tl_ns: i64,
    pub cursor_style: u32,
    pub cursor_motion_blur: f32,
    pub cursor_spotlight_radius: f32,
    pub background_noise: f32,
    pub window_chrome: u8,
    pub camera_background_removal: u8,
    pub camera_face_framing: u8,
    pub reserved: u8,
    pub camera_shadow_radius: f32,
    pub fade_opacity: f32,
    pub highlight_count: u32,
    pub highlights: [FrameHighlight; MAX_FRAME_HIGHLIGHTS],
}
/// Additive companion: indices correspond to the unchanged FrameExtras prefix.
#[derive(Clone, Copy, Debug, Default, PartialEq, serde::Serialize)]
#[repr(C)]
pub struct FrameMaskEffect {
    pub kind: u32,
    pub blur_radius: f32,
}
#[derive(Clone, Copy, Debug, Default, PartialEq)]
#[repr(C)]
pub struct FrameMaskEffects {
    pub tl_ns: i64,
    pub highlight_count: u32,
    pub reserved: u32,
    pub effects: [FrameMaskEffect; MAX_FRAME_HIGHLIGHTS],
}
fn smooth(t: f64) -> f64 {
    let t = t.clamp(0.0, 1.0);
    t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
}
/// Normalized, seek-independent mask curve, shared by frame evaluation and retiming.
pub(crate) fn mask_rect_at(h: &Highlight, tl_ns: i64) -> [f64; 4] {
    let i = h.keyframes.partition_point(|key| key.tl_ns <= tl_ns);
    let (a, at) = if i > 0 {
        (h.keyframes[i - 1].rect, h.keyframes[i - 1].tl_ns)
    } else {
        (h.rect, h.tl_start_ns)
    };
    if let Some(next) = h.keyframes.get(i) {
        let k = ((tl_ns - at) as f64 / (next.tl_ns - at).max(1) as f64).clamp(0.0, 1.0);
        std::array::from_fn(|j| a[j] + (next.rect[j] - a[j]) * k)
    } else {
        a
    }
}
fn highlight_at(h: &Highlight, f: &Frame) -> Option<FrameHighlight> {
    if !h.enabled || f.tl_ns < h.tl_start_ns || f.tl_ns >= h.tl_end_ns {
        return None;
    }
    let bounds = mask_rect_at(h, f.tl_ns);
    let rect = if h.space == "canvas" {
        Rect {
            x: bounds[0] * f.canvas_w as f64,
            y: bounds[1] * f.canvas_h as f64,
            w: bounds[2] * f.canvas_w as f64,
            h: bounds[3] * f.canvas_h as f64,
        }
    } else {
        if f.screen.present == 0 {
            return None;
        }
        let crop = f.screen_crop;
        let x = bounds[0].max(crop.x);
        let y = bounds[1].max(crop.y);
        let right = (bounds[0] + bounds[2]).min(crop.x + crop.w);
        let bottom = (bounds[1] + bounds[3]).min(crop.y + crop.h);
        if right <= x || bottom <= y {
            return None;
        }
        let d = f.screen_dest;
        Rect {
            x: d.x + (x - crop.x) / crop.w * d.w,
            y: d.y + (y - crop.y) / crop.h * d.h,
            w: (right - x) / crop.w * d.w,
            h: (bottom - y) / crop.h * d.h,
        }
    };
    Some(FrameHighlight {
        rect,
        corner_radius: h.radius as f32,
        opacity: h.opacity as f32,
        dim_opacity: h.dim_opacity as f32,
        fill: h.fill,
        stroke: h.stroke,
        stroke_width: h.stroke_width as f32,
    })
}
fn append_text(
    layers: &mut Vec<Value>,
    r: &TextRecord,
    f: &Frame,
    id: &str,
    p: &crate::model::ProjectData,
    adapt: bool,
) {
    let h = Highlight {
        tl_start_ns: r.tl_start_ns,
        tl_end_ns: r.tl_end_ns,
        rect: r.rect,
        space: r.space.clone(),
        radius: r.style.radius,
        opacity: r.style.opacity,
        dim_opacity: 0.0,
        fill: r.style.background,
        stroke: [0.0; 4],
        stroke_width: 0.0,
        ..Highlight::default()
    };
    if let Some(evaluated) = highlight_at(&h, f) {
        let d = if adapt && r.space == "canvas" {
            crate::adaptive::text_rect(p, evaluated.rect, f, id == "core:key-overlay")
        } else {
            evaluated.rect
        };
        let font_size = r
            .style
            .font_size_ratio
            .map_or(r.style.font_size, |ratio| ratio * f.canvas_h as f64);
        let rect = [d.x, d.y, d.w, d.h];
        if r.style.background[3] > 0.0 {
            layers.push(json!({"id":format!("{id}:background"),"kind":"highlight","rect":rect,"corner_radius":r.style.radius,"opacity":r.style.opacity,"dim_opacity":0.0,"fill":r.style.background,"stroke":[0.0,0.0,0.0,0.0],"stroke_width":0.0}));
        }
        layers.push(json!({"id":id,"kind":"text","rect":rect,"corner_radius":r.style.radius,"opacity":r.style.opacity,"dim_opacity":0.0,"fill":[0.0,0.0,0.0,0.0],"stroke":[0.0,0.0,0.0,0.0],"stroke_width":0.0,"text":r.text,"font_size":font_size,"font_family":r.style.font_family,"color":r.style.color}));
    }
}
/// Apply content entrance/exit to the legacy geometry. No additional ABI slots,
/// allocations, or renderer-side animation clock are needed.
pub(crate) fn animate_frame(f: &mut Frame, a: &Animation, duration: i64) {
    let enter = smooth(f.tl_ns as f64 / a.entrance_duration_ns.min(duration).max(1) as f64);
    let leave =
        smooth((duration - f.tl_ns) as f64 / a.exit_duration_ns.min(duration).max(1) as f64);
    for (mode, progress) in [(a.entrance.as_str(), enter), (a.exit.as_str(), leave)] {
        let remaining = 1.0 - progress;
        let (scale, dx, dy) = match mode {
            "zoom" => (0.85 + 0.15 * progress, 0.0, 0.0),
            "slide_left" => (1.0, -remaining * f.canvas_w as f64, 0.0),
            "slide_right" => (1.0, remaining * f.canvas_w as f64, 0.0),
            "slide_up" => (1.0, 0.0, -remaining * f.canvas_h as f64),
            "slide_down" => (1.0, 0.0, remaining * f.canvas_h as f64),
            _ => continue,
        };
        let cx = f.canvas_w as f64 / 2.0;
        let cy = f.canvas_h as f64 / 2.0;
        let transform = |x: f64, y: f64| (cx + (x - cx) * scale + dx, cy + (y - cy) * scale + dy);
        for r in [&mut f.screen_dest, &mut f.camera_dest] {
            let (x, y) = transform(r.x, r.y);
            r.x = x;
            r.y = y;
            r.w *= scale;
            r.h *= scale;
        }
        (f.cursor_x, f.cursor_y) = transform(f.cursor_x, f.cursor_y);
        (f.click_x, f.click_y) = transform(f.click_x, f.click_y);
        f.cursor_scale *= scale as f32;
        f.screen_corner_radius *= scale as f32;
        f.camera_corner_radius *= scale as f32;
        f.inset_width *= scale as f32;
        f.shadow_radius *= scale as f32;
        f.shadow_offset_y *= scale as f32;
    }
}
fn fade_opacity(a: &Animation, duration: i64, tl_ns: i64) -> f64 {
    // Short projects clamp durations; overlapping fades take the darker result.
    let entrance = if a.entrance == "fade" {
        smooth(tl_ns as f64 / a.entrance_duration_ns.min(duration).max(1) as f64)
    } else {
        1.0
    };
    let exit = if a.exit == "fade" {
        smooth((duration - tl_ns) as f64 / a.exit_duration_ns.min(duration).max(1) as f64)
    } else {
        1.0
    };
    1.0 - entrance.min(exit)
}
impl Project {
    /// Successful evaluation performs no heap allocation, file IO, or mutation.
    pub fn frame_extras(&self, tl_ns: i64) -> Result<FrameExtras> {
        let f = self.frame(tl_ns)?;
        let p = &self.data;
        let (camera_remove, camera_face, camera_shadow) = crate::effects::camera_options(p, tl_ns);
        let mut extras = FrameExtras {
            tl_ns,
            cursor_style: match if p.cursor.always_default {
                "pointer"
            } else {
                p.cursor.style.as_str()
            } {
                "pointer" => 1,
                "touch" => 2,
                "arrow" => 3,
                _ => 0,
            },
            cursor_motion_blur: (p.cursor.motion_blur * p.canvas.global_motion_blur.unwrap_or(1.0))
                as f32,
            cursor_spotlight_radius: p.cursor.spotlight_radius as f32,
            background_noise: p.canvas.background.noise as f32,
            window_chrome: p.canvas.window_chrome as u8,
            camera_background_removal: camera_remove as u8,
            camera_face_framing: camera_face as u8,
            camera_shadow_radius: camera_shadow as f32,
            fade_opacity: fade_opacity(
                &p.canvas.animation,
                time::duration(&p.timeline.clips),
                tl_ns,
            ) as f32,
            ..FrameExtras::default()
        };
        for h in &p.canvas.highlights {
            if let Some(mut highlight) = highlight_at(h, &f) {
                // Old fixed-layout consumers cannot represent a Gaussian. Keep
                // a visible cover rather than silently exposing a masked region.
                if h.kind == "blur" {
                    highlight.fill = [0.0, 0.0, 0.0, 1.0];
                    highlight.stroke = [0.0; 4];
                    highlight.stroke_width = 0.0;
                    highlight.dim_opacity = 0.0;
                }
                let slot = extras
                    .highlights
                    .get_mut(extras.highlight_count as usize)
                    .ok_or_else(|| Error::new(1, "At most 32 highlights may overlap"))?;
                *slot = highlight;
                extras.highlight_count += 1;
            }
        }
        Ok(extras)
    }
    /// No allocation or IO; shares geometry/visibility with the legacy extras.
    pub fn frame_mask_effects(&self, tl_ns: i64) -> Result<FrameMaskEffects> {
        let f = self.frame(tl_ns)?;
        let mut extras = FrameMaskEffects {
            tl_ns,
            ..FrameMaskEffects::default()
        };
        for h in &self.data.canvas.highlights {
            if highlight_at(h, &f).is_some() {
                let slot = extras
                    .effects
                    .get_mut(extras.highlight_count as usize)
                    .ok_or_else(|| Error::new(1, "At most 32 highlights may overlap"))?;
                *slot = FrameMaskEffect {
                    kind: u32::from(h.kind == "blur"),
                    blur_radius: if h.kind == "blur" {
                        h.blur_radius as f32
                    } else {
                        0.0
                    },
                };
                extras.highlight_count += 1;
            }
        }
        Ok(extras)
    }
    pub fn mask_effects_at(&self, tl_ns: i64) -> Result<Value> {
        let extras = self.frame_mask_effects(tl_ns)?;
        Ok(
            json!({"tl_ns":tl_ns,"highlight_count":extras.highlight_count,
            "effects":extras.effects[..extras.highlight_count as usize]}),
        )
    }
    pub fn layers_at(&self, tl_ns: i64) -> Result<Value> {
        let f = self.frame(tl_ns)?;
        let mut layers = vec![];
        for h in &self.data.canvas.highlights {
            if let Some(highlight) = highlight_at(h, &f) {
                let r = highlight.rect;
                let mut row = json!({"id":h.id,"kind":h.kind,"rect":[r.x,r.y,r.w,r.h],
                    "corner_radius":h.radius,"opacity":h.opacity,"dim_opacity":h.dim_opacity,
                    "fill":h.fill,"stroke":h.stroke,"stroke_width":h.stroke_width});
                if h.kind == "blur" {
                    row["blur_radius"] = h.blur_radius.into();
                }
                layers.push(row);
            }
        }
        for (kind, records) in [
            ("annotation", &self.data.canvas.annotations),
            ("reaction", &self.data.canvas.reactions),
            ("caption", &self.data.canvas.captions),
        ] {
            for r in records {
                if kind == "caption" {
                    let Some(evaluation) = crate::captions::evaluate(r, tl_ns) else {
                        continue;
                    };
                    if evaluation.visible_text.is_empty() {
                        continue;
                    }
                    let first = layers.len();
                    let mut visible = r.clone();
                    visible.text = evaluation.visible_text.clone();
                    visible.style.opacity *= evaluation.line_opacity;
                    append_text(
                        &mut layers,
                        &visible,
                        &f,
                        &format!("core:{kind}:{}", r.id),
                        &self.data,
                        true,
                    );
                    for row in &mut layers[first..] {
                        let y = row["rect"][1].as_f64().unwrap();
                        let height = row["rect"][3].as_f64().unwrap();
                        row["rect"][1] = (y + height * evaluation.line_offset_y).into();
                        if row["kind"] == "text" {
                            row["caption"] = serde_json::to_value(&evaluation)?;
                        }
                    }
                } else {
                    append_text(
                        &mut layers,
                        r,
                        &f,
                        &format!("core:{kind}:{}", r.id),
                        &self.data,
                        false,
                    );
                }
            }
        }
        let key = &self.data.cursor.key_overlay;
        if key.enabled {
            if let Some(text) =
                self.key_overlay_index
                    .latest(tl_ns, key.duration_ns, key.shortcuts_only)
            {
                if !text.trim().is_empty() && !key.hidden_shortcuts.iter().any(|s| s == text) {
                    let record = TextRecord {
                        text: text.to_owned(),
                        rect: key.rect,
                        style: key.style.clone(),
                        tl_start_ns: tl_ns,
                        tl_end_ns: tl_ns.saturating_add(1),
                        ..TextRecord::default()
                    };
                    append_text(
                        &mut layers,
                        &record,
                        &f,
                        "core:key-overlay",
                        &self.data,
                        true,
                    );
                }
            }
        }
        let opacity = fade_opacity(
            &self.data.canvas.animation,
            time::duration(&self.data.timeline.clips),
            tl_ns,
        );
        if opacity > 0.0 {
            layers.push(json!({"id":"canvas-fade","kind":"highlight",
                "rect":[0.0,0.0,f.canvas_w as f64,f.canvas_h as f64],
                "corner_radius":0.0,"opacity":opacity,"dim_opacity":0.0,
                "fill":[0.0,0.0,0.0,1.0],"stroke":[0.0,0.0,0.0,0.0],"stroke_width":0.0}));
        }
        Ok(layers.into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::tests::Fixture;
    #[test]
    fn blur_masks_share_geometry_order_and_zero_allocation_extras_without_abi_changes() {
        use std::mem::{offset_of, size_of};
        assert_eq!(size_of::<FrameMaskEffect>(), 8);
        assert_eq!(size_of::<FrameMaskEffects>(), 272);
        assert_eq!(std::mem::align_of::<FrameMaskEffects>(), 8);
        assert_eq!(offset_of!(FrameMaskEffects, effects), 16);
        assert_eq!(size_of::<FrameExtras>(), 2600);
        let fixture = Fixture::new();
        let mut p = Project::create(&fixture.0).unwrap();
        p.apply(&json!({"op":"set","path":"canvas.highlights","value":[
            {"id":"cover","tl_start_ns":1_000_000_000,"tl_end_ns":3_000_000_000_i64,"space":"canvas","fill":[0,0,0,1]},
            {"id":"hidden-blur","kind":"blur","tl_start_ns":1_000_000_000,"tl_end_ns":3_000_000_000_i64,"rect":[0,0,0.1,0.1]},
            {"id":"blur","kind":"blur","tl_start_ns":1_000_000_000,"tl_end_ns":3_000_000_000_i64,"rect":[0.25,0.25,0.5,0.5]}
        ]})).unwrap();
        p.apply(&json!({"op":"add_zoom","tl_start_ns":0,"tl_end_ns":4_000_000_000_i64,"mode":"manual","target":[0.5,0.5],"scale":2,"ease_in_ns":0,"ease_out_ns":0})).unwrap();
        let t = 1_500_000_000;
        let f = p.frame(t).unwrap();
        let extras = p.frame_extras(t).unwrap();
        let masks = p.frame_mask_effects(t).unwrap();
        assert_eq!(masks.highlight_count, 2);
        assert_eq!(masks.highlight_count, extras.highlight_count);
        assert_eq!(masks.effects[0], FrameMaskEffect::default());
        assert_eq!(
            masks.effects[1],
            FrameMaskEffect {
                kind: 1,
                blur_radius: 32.0
            }
        );
        assert!(masks.effects[2..]
            .iter()
            .all(|effect| *effect == FrameMaskEffect::default()));
        assert_eq!(masks.reserved, 0);
        assert_eq!(extras.highlights[1].rect, f.screen_dest);
        assert_eq!(extras.highlights[1].fill, [0.0, 0.0, 0.0, 1.0]);
        assert_eq!(extras.highlights[1].stroke_width, 0.0);
        assert_eq!(extras.highlights[1].dim_opacity, 0.0);
        let rows = p.layers_at(t).unwrap();
        assert_eq!(rows.as_array().unwrap().len(), 2);
        assert_eq!(rows[0]["id"], "cover");
        assert_eq!(rows[0]["kind"], "highlight");
        assert!(rows[0].get("blur_radius").is_none());
        assert_eq!(rows[1]["id"], "blur");
        assert_eq!(rows[1]["kind"], "blur");
        assert_eq!(rows[1]["blur_radius"], 32.0);
        assert_eq!(
            rows[1]["rect"],
            json!([
                f.screen_dest.x,
                f.screen_dest.y,
                f.screen_dest.w,
                f.screen_dest.h
            ])
        );
        assert_eq!(
            p.query(&json!({"q":"effects_at","tl_ns":t})).unwrap()["layers"],
            rows
        );
        assert_eq!(
            p.query(&json!({"q":"mask_effects_at","tl_ns":t})).unwrap()["effects"],
            json!([{"kind":0,"blur_radius":0.0},{"kind":1,"blur_radius":32.0}])
        );
        for time in [0, 999_999_999, 3_000_000_000, 5_000_000_000] {
            assert_eq!(p.frame_mask_effects(time).unwrap().highlight_count, 0);
        }
        assert_eq!(
            p.frame_mask_effects(1_000_000_000).unwrap().highlight_count,
            2
        );
        let initial = p.data.clone();
        p.apply(&json!({"op":"delete_range","tl_start_ns":0,"tl_end_ns":1_000_000_000}))
            .unwrap();
        p.apply(&json!({"op":"set_speed","clip_id":p.data.timeline.clips[0].id,"speed":2}))
            .unwrap();
        assert_eq!(p.data.canvas.highlights[2].tl_end_ns, 1_000_000_000);
        assert_eq!(
            p.frame_mask_effects(500_000_000).unwrap().effects[1].blur_radius,
            32.0
        );
        p.undo().unwrap();
        p.undo().unwrap();
        assert_eq!(p.data, initial);
        let handle = crate::ffi::YcProject::new(p);
        let mut output = FrameMaskEffects::default();
        let allocated = crate::allocation_test::count(|| {
            for time in [0, 1_000_000_000, t, 3_000_000_000, 5_000_000_000] {
                assert_eq!(
                    unsafe { crate::ffi::yc_frame_mask_effects_at(&handle, time, &mut output) },
                    0
                );
            }
        });
        assert_eq!(allocated, 0);
        assert_eq!(output.effects, [FrameMaskEffect::default(); 32]);
        let sentinel = FrameMaskEffects {
            tl_ns: 123,
            highlight_count: 17,
            ..output
        };
        for time in [-1, 5_000_000_001, i64::MAX] {
            output = sentinel;
            assert_eq!(
                unsafe { crate::ffi::yc_frame_mask_effects_at(&handle, time, &mut output) },
                1
            );
            assert_eq!(output, sentinel);
        }
        assert_eq!(
            unsafe { crate::ffi::yc_frame_mask_effects_at(&handle, 0, std::ptr::null_mut()) },
            1
        );
        assert_eq!(
            unsafe { crate::ffi::yc_frame_mask_effects_at(std::ptr::null(), 0, &mut output) },
            1
        );
        assert_eq!(output, sentinel);
    }

    #[test]
    fn blur_masks_inherit_validate_snapshot_save_and_decode_legacy_styles() {
        let fixture = Fixture::new();
        let mut p = Project::create(&fixture.0).unwrap();
        p.apply(&json!({"op":"insert_mask","patch":{"kind":"blur","blur_radius":128,"space":"canvas","opacity":0.8}})).unwrap();
        p.apply(&json!({"op":"insert_mask","tl_start_ns":1_000_000_000}))
            .unwrap();
        assert_eq!(p.data.canvas.highlights[1].kind, "blur");
        assert_eq!(p.data.canvas.highlights[1].blur_radius, 128.0);
        let frozen = p.clone();
        p.apply(&json!({"op":"insert_mask","patch":{"blur_radius":0}}))
            .unwrap();
        assert_eq!(p.frame_mask_effects(0).unwrap().effects[1].blur_radius, 0.0);
        assert_eq!(
            frozen
                .data
                .insertion_styles
                .mask
                .as_ref()
                .unwrap()
                .blur_radius,
            128.0
        );
        p.undo().unwrap();
        assert_eq!(p.data, frozen.data);
        p.redo().unwrap();
        p.save(&fixture.0).unwrap();
        let opened = Project::open(&fixture.0).unwrap();
        assert_eq!(opened.data, p.data);
        assert_eq!(
            opened.frame_mask_effects(0).unwrap(),
            p.frame_mask_effects(0).unwrap()
        );
        assert_eq!(opened.layers_at(0).unwrap(), p.layers_at(0).unwrap());
        let before = p.data.clone();
        let history = p.undo.len();
        for patch in [
            json!({"kind":"cover"}),
            json!({"kind":null}),
            json!({"blur_radius":-0.1}),
            json!({"blur_radius":128.01}),
            json!({"blur_radius":null}),
            json!({"blur_radius":true}),
        ] {
            assert!(p.apply(&json!({"op":"batch","commands":[{"op":"set","path":"notes","value":"rollback"},{"op":"insert_mask","patch":patch}]})).is_err());
            assert_eq!(p.data, before);
            assert_eq!(p.undo.len(), history);
        }
        for (kind, radius) in [
            ("blur", f64::NAN),
            ("blur", f64::INFINITY),
            ("blur", -1.0),
            ("invalid", 32.0),
        ] {
            let mut data = p.data.clone();
            data.canvas.highlights[0].kind = kind.into();
            data.canvas.highlights[0].blur_radius = radius;
            assert!(crate::project::validate_data(&data).is_err());
            data = p.data.clone();
            let style = data.insertion_styles.mask.as_mut().unwrap();
            style.kind = kind.into();
            style.blur_radius = radius;
            assert!(crate::project::validate_data(&data).is_err());
        }
        let mut legacy = serde_json::to_value(&p.data).unwrap();
        for row in legacy["canvas"]["highlights"].as_array_mut().unwrap() {
            row.as_object_mut().unwrap().remove("kind");
            row.as_object_mut().unwrap().remove("blur_radius");
        }
        for key in ["kind", "blur_radius"] {
            legacy["insertion_styles"]["mask"]
                .as_object_mut()
                .unwrap()
                .remove(key);
        }
        let data = crate::project::decode_project(&serde_json::to_vec(&legacy).unwrap()).unwrap();
        assert!(data
            .canvas
            .highlights
            .iter()
            .all(|h| h.kind == "highlight" && h.blur_radius == 32.0));
        assert_eq!(
            data.insertion_styles.mask.as_ref().unwrap().kind,
            "highlight"
        );
        assert_eq!(
            data.insertion_styles.mask.as_ref().unwrap().blur_radius,
            32.0
        );
        assert_eq!(
            data.canvas.highlights[0].fill,
            p.data.canvas.highlights[0].fill
        );
        assert_eq!(
            data.canvas.highlights[0].radius,
            p.data.canvas.highlights[0].radius
        );
    }

    #[test]
    fn extras_layout_capacity_and_ffi_hot_path() {
        use std::mem::{offset_of, size_of};
        assert_eq!(size_of::<crate::frame::Frame>(), 328);
        assert_eq!(size_of::<FrameHighlight>(), 80);
        assert_eq!(size_of::<FrameExtras>(), 2600);
        assert_eq!(offset_of!(FrameExtras, cursor_style), 8);
        assert_eq!(offset_of!(FrameExtras, window_chrome), 24);
        assert_eq!(offset_of!(FrameExtras, fade_opacity), 32);
        assert_eq!(offset_of!(FrameExtras, highlight_count), 36);
        assert_eq!(offset_of!(FrameExtras, highlights), 40);
        let fixture = Fixture::new();
        let mut p = Project::create(&fixture.0).unwrap();
        let regions =
            |count: usize, sequential: bool| {
                (0..count).map(|i| json!({
            "id":format!("h-{i}"),"tl_start_ns":if sequential {i as i64*100} else {0},
            "tl_end_ns":if sequential {(i as i64+1)*100} else {2_000_000_000},
        })).collect::<Vec<_>>()
            };
        p.apply(&json!({"op":"set","path":"canvas.highlights","value":regions(32,false)}))
            .unwrap();
        let before = p.data.clone();
        assert!(p
            .apply(&json!({"op":"set","path":"canvas.highlights","value":regions(33,false)}))
            .is_err());
        assert_eq!(p.data, before);
        let e = p.frame_extras(1_000_000_000).unwrap();
        assert_eq!(e.highlight_count, 32);
        assert_eq!(e.reserved, 0);
        let rows = p.layers_at(1_000_000_000).unwrap();
        for (row, h) in rows.as_array().unwrap().iter().zip(e.highlights) {
            assert_eq!(row["rect"], json!([h.rect.x, h.rect.y, h.rect.w, h.rect.h]));
        }
        let handle = crate::ffi::YcProject::new(p);
        let mut output = FrameExtras::default();
        let allocated = crate::allocation_test::count(|| {
            for t in [0, 500_000_000, 1_000_000_000, 2_000_000_000, 5_000_000_000] {
                assert_eq!(
                    unsafe { crate::ffi::yc_frame_extras_at(&handle, t, &mut output) },
                    0
                );
            }
        });
        assert_eq!(allocated, 0);
        assert_eq!(output.highlight_count, 0);
        assert_eq!(output.highlights, [FrameHighlight::default(); 32]);
        output.tl_ns = 123;
        assert_eq!(
            unsafe { crate::ffi::yc_frame_extras_at(&handle, -1, &mut output) },
            1
        );
        assert_eq!(output.tl_ns, 123); // error never overwrites caller's output
        assert_eq!(
            unsafe { crate::ffi::yc_frame_extras_at(&handle, 0, std::ptr::null_mut()) },
            1
        );
        let mut p = handle.inner.into_inner().unwrap();
        p.apply(&json!({"op":"set","path":"canvas.highlights","value":regions(40,true)}))
            .unwrap();
        assert_eq!(p.frame_extras(100).unwrap().highlight_count, 1);
        p.undo().unwrap();
        assert_eq!(p.frame_extras(100).unwrap().highlight_count, 32);
    }
    #[test]
    fn highlights_share_frame_geometry_and_retime_with_edits() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.apply(&json!({"op":"set","path":"canvas.highlights","value":[{
            "id":"h1","tl_start_ns":1_000_000_000,"tl_end_ns":3_000_000_000_i64,
            "rect":[0.25,0.25,0.5,0.5]}]}))
            .unwrap();
        let initial = p.data.clone();
        assert_eq!(p.layers_at(0).unwrap(), json!([]));
        let frame = p.frame(1_500_000_000).unwrap();
        let layers = p.layers_at(1_500_000_000).unwrap();
        assert_eq!(
            layers[0]["rect"][0],
            json!(frame.screen_dest.x + frame.screen_dest.w * 0.25)
        );
        assert_eq!(p.layers_at(3_000_000_000).unwrap(), json!([]));
        p.apply(
            &json!({"op":"add_zoom","tl_start_ns":0,"tl_end_ns":3_000_000_000_i64,
            "mode":"manual","target":[0.5,0.5],"scale":2,"ease_in_ns":0,"ease_out_ns":0}),
        )
        .unwrap();
        let zoomed = p.frame(1_500_000_000).unwrap();
        let layers = p.layers_at(1_500_000_000).unwrap();
        assert_eq!(
            layers[0]["rect"],
            json!([
                zoomed.screen_dest.x,
                zoomed.screen_dest.y,
                zoomed.screen_dest.w,
                zoomed.screen_dest.h
            ])
        );
        p.apply(&json!({"op":"delete_range","tl_start_ns":0,"tl_end_ns":1_000_000_000}))
            .unwrap();
        assert_eq!(p.data.canvas.highlights[0].tl_start_ns, 0);
        assert_eq!(p.data.canvas.highlights[0].tl_end_ns, 2_000_000_000);
        p.apply(&json!({"op":"set_speed","clip_id":p.data.timeline.clips[0].id,"speed":2}))
            .unwrap();
        assert_eq!(p.data.canvas.highlights[0].tl_end_ns, 1_000_000_000);
        p.undo().unwrap();
        p.undo().unwrap();
        p.undo().unwrap();
        assert_eq!(p.data, initial);
        let before = p.data.clone();
        assert!(p
            .apply(&json!({"op":"set","path":"canvas.highlights","value":[{
            "id":"h","tl_start_ns":0,"tl_end_ns":1,"rect":[0.5,0.0,0.6,1.0]}]}))
            .is_err());
        assert_eq!(p.data, before);
        p.save(&f.0).unwrap();
        assert_eq!(
            Project::open(&f.0).unwrap().data.canvas.highlights,
            before.canvas.highlights
        );
        assert!(p.query(&json!({"q":"preset"})).unwrap()["canvas"]
            .get("highlights")
            .is_none());
    }
    #[test]
    fn fixed_arrow_roundtrips_and_always_default_keeps_precedence() {
        let fixture = Fixture::new();
        let mut p = Project::create(&fixture.0).unwrap();
        let original = p.frame(500_000_000).unwrap();
        p.apply(&json!({"op":"set","path":"cursor.style","value":"arrow"}))
            .unwrap();
        let copy = p.clone();
        assert_eq!(p.frame(500_000_000).unwrap().cursor_id, original.cursor_id);
        for t in [0, 500_000_000, 5_000_000_000] {
            assert_eq!(p.frame_extras(t).unwrap().cursor_style, 3);
            assert_eq!(
                p.query(&json!({"q":"render_options","tl_ns":t})).unwrap()["cursor_style"],
                json!("arrow")
            );
            assert_eq!(
                p.query(&json!({"q":"effects_at","tl_ns":t})).unwrap()["render_options"]
                    ["cursor_style"],
                json!("arrow")
            );
        }
        assert_eq!(
            p.query(&json!({"q":"render_options"})).unwrap()["cursor_style"],
            json!("arrow")
        );
        assert_eq!(
            p.query(&json!({"q":"preset"})).unwrap()["cursor"]["style"],
            json!("arrow")
        );
        assert_eq!(
            crate::allocation_test::count(|| {
                p.frame_extras(500_000_000).unwrap();
            }),
            0
        );
        p.save(&fixture.0).unwrap();
        assert_eq!(
            Project::open(&fixture.0)
                .unwrap()
                .frame_extras(0)
                .unwrap()
                .cursor_style,
            3
        );
        p.apply(&json!({"op":"set","path":"cursor.always_default","value":true}))
            .unwrap();
        assert_eq!(p.frame_extras(0).unwrap().cursor_style, 1);
        assert_eq!(p.frame(0).unwrap().cursor_id, 0);
        assert_eq!(
            p.query(&json!({"q":"render_options"})).unwrap()["cursor_style"],
            json!("pointer")
        );
        assert_eq!(copy.frame_extras(0).unwrap().cursor_style, 3);
        p.undo().unwrap();
        assert_eq!(p.frame_extras(0).unwrap().cursor_style, 3);
        p.undo().unwrap();
        assert_eq!(p.frame_extras(0).unwrap().cursor_style, 0);
        p.redo().unwrap();
        assert_eq!(p.frame_extras(0).unwrap().cursor_style, 3);
        let before = p.data.clone();
        assert!(p
            .apply(&json!({"op":"set","path":"cursor.style","value":"unknown"}))
            .is_err());
        assert_eq!(p.data, before);
    }
    #[test]
    fn fade_endpoints_options_and_snapshot_are_deterministic() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.apply(&json!({"op":"batch","commands":[
            {"op":"set","path":"canvas.animation","value":{"entrance":"fade","exit":"fade","entrance_duration_ns":1_000_000_000,"exit_duration_ns":1_000_000_000}},
            {"op":"set","path":"cursor.style","value":"touch"},
            {"op":"set","path":"camera.shadow_radius","value":18.0},
            {"op":"set","path":"canvas.background.noise","value":0.3}
        ]})).unwrap();
        assert_eq!(p.layers_at(0).unwrap()[0]["opacity"], json!(1.0));
        assert_eq!(p.layers_at(500_000_000).unwrap()[0]["opacity"], json!(0.5));
        let extras = p.frame_extras(500_000_000).unwrap();
        assert_eq!(extras.fade_opacity, 0.5);
        assert_eq!(extras.cursor_style, 2);
        assert_eq!(extras.camera_shadow_radius, 18.0);
        assert_eq!(extras.background_noise, 0.3);
        assert_eq!(p.layers_at(1_000_000_000).unwrap(), json!([]));
        assert_eq!(
            p.layers_at(4_500_000_000).unwrap()[0]["opacity"],
            json!(0.5)
        );
        assert_eq!(
            p.layers_at(5_000_000_000).unwrap()[0]["opacity"],
            json!(1.0)
        );
        assert!(p.layers_at(-1).is_err());
        assert!(p.query(&json!({"q":"layers_at","tl_ns":0.5})).is_err());
        let options = p.query(&json!({"q":"render_options"})).unwrap();
        assert_eq!(options["cursor_style"], json!("touch"));
        assert_eq!(options["camera_shadow_radius"], json!(18.0));
        let mut copy = p.clone();
        copy.snapshot = true;
        for t in [0, 500_000_000, 1_000_000_000, 4_500_000_000, 5_000_000_000] {
            assert_eq!(copy.layers_at(t).unwrap(), p.layers_at(t).unwrap());
            assert_eq!(copy.frame_extras(t).unwrap(), p.frame_extras(t).unwrap());
        }
        // A valid one-source-ns clip at high speed rounds to zero timeline ns.
        // Its endpoint evaluation must still have finite fade values.
        p.data.timeline.clips[0].src_end_ns = 1;
        p.data.timeline.clips[0].speed = 32.0;
        assert_eq!(time::duration(&p.data.timeline.clips), 0);
        assert_eq!(p.frame_extras(0).unwrap().fade_opacity, 1.0);
        assert_eq!(p.layers_at(0).unwrap()[0]["opacity"], json!(1.0));
        // Supplemental layers do not change the allocation-free C frame path.
        assert_eq!(
            crate::allocation_test::count(|| {
                p.frame(0).unwrap();
                p.frame_extras(0).unwrap();
            }),
            0
        );
    }
}
