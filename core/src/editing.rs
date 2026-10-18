//! Checked interactive edits; legacy precision commands keep their clock semantics.
use crate::{
    commands::{apply_inner, ChangeSet},
    model::*,
    project::{Error, Project, Result},
    time,
};
use serde_json::{json, Value};
pub(crate) const CLIP_MIN: i64 = 100_000_000;
pub(crate) const REGION_MIN: i64 = 500_000_000;
pub(crate) fn constraints() -> Value {
    json!({"clip_min_ns":CLIP_MIN,"zoom_min_ns":CLIP_MIN,"layout_min_ns":REGION_MIN,"mask_min_ns":REGION_MIN,"insert_duration_ns":3_000_000_000_i64})
}
fn fail() -> Error {
    Error::new(1, "Timeline item is shorter than its minimum")
}
fn check_ranges<'a>(
    old: impl Iterator<Item = (&'a str, i64, i64)>,
    new: impl Iterator<Item = (&'a str, i64, i64)>,
    minimum: i64,
) -> Result<()> {
    let old: std::collections::HashMap<_, _> = old.map(|(id, a, b)| (id, (a, b))).collect();
    for (id, a, b) in new {
        if old.get(id) != Some(&(a, b)) && b - a < minimum {
            return Err(fail());
        }
    }
    Ok(())
}
fn check(before: &ProjectData, after: &ProjectData) -> Result<()> {
    let old: std::collections::HashMap<_, _> =
        before.timeline.clips.iter().map(|c| (&c.id, c)).collect();
    for c in &after.timeline.clips {
        let changed = old.get(&c.id).is_none_or(|old| {
            old.src_start_ns != c.src_start_ns
                || old.src_end_ns != c.src_end_ns
                || old.speed != c.speed
        });
        if changed && time::clip_duration(c) < CLIP_MIN as f64 {
            return Err(fail());
        }
    }
    check_ranges(
        before
            .zooms
            .iter()
            .map(|r| (r.id.as_str(), r.tl_start_ns, r.tl_end_ns)),
        after
            .zooms
            .iter()
            .map(|r| (r.id.as_str(), r.tl_start_ns, r.tl_end_ns)),
        CLIP_MIN,
    )?;
    check_ranges(
        before
            .camera
            .layouts
            .iter()
            .map(|r| (r.id.as_str(), r.tl_start_ns, r.tl_end_ns)),
        after
            .camera
            .layouts
            .iter()
            .map(|r| (r.id.as_str(), r.tl_start_ns, r.tl_end_ns)),
        REGION_MIN,
    )?;
    check_ranges(
        before
            .canvas
            .highlights
            .iter()
            .map(|r| (r.id.as_str(), r.tl_start_ns, r.tl_end_ns)),
        after
            .canvas
            .highlights
            .iter()
            .map(|r| (r.id.as_str(), r.tl_start_ns, r.tl_end_ns)),
        REGION_MIN,
    )
}
pub(crate) fn zoom_style(z: &Zoom) -> ZoomInsertionStyle {
    ZoomInsertionStyle {
        style: z.style.clone(),
        lens: z.lens.clone(),
        mode: z.mode.clone(),
        scale: z.scale,
        ease_in_ns: z.ease_in_ns,
        ease_out_ns: z.ease_out_ns,
    }
}
pub(crate) fn mask_style(h: &Highlight) -> MaskInsertionStyle {
    MaskInsertionStyle {
        kind: h.kind.clone(),
        blur_radius: h.blur_radius,
        radius: h.radius,
        opacity: h.opacity,
        dim_opacity: h.dim_opacity,
        fill: h.fill,
        stroke: h.stroke,
        stroke_width: h.stroke_width,
    }
}
pub(crate) fn merge_style(row: &mut Value, style: Value) {
    if let Value::Object(fields) = style {
        for (key, value) in fields {
            row[key] = value;
        }
    }
}
pub(crate) fn command(
    p: &mut ProjectData,
    v: &Value,
    cs: &mut ChangeSet,
    depth: usize,
    context: &Project,
) -> Result<bool> {
    match v["op"].as_str().unwrap_or("") {
        "coalesced_edit" => {
            v["key"]
                .as_str()
                .filter(|s| !s.is_empty() && s.len() <= 256)
                .ok_or_else(|| Error::new(1, "Invalid history group key"))?;
            let command = v
                .get("command")
                .ok_or_else(|| Error::new(1, "Missing grouped command"))?;
            apply_inner(p, command, cs, depth + 1, context)?;
        }
        "timeline_edit" => {
            let before = p.clone();
            let command = v
                .get("command")
                .ok_or_else(|| Error::new(1, "Missing timeline command"))?;
            apply_inner(p, command, cs, depth + 1, context)?;
            crate::project::validate_data(p)?;
            check(&before, p)?;
        }
        "set_clip_settings" => {
            let id = v["clip_id"]
                .as_str()
                .ok_or_else(|| Error::new(1, "Missing clip id"))?;
            let c = p
                .timeline
                .clips
                .iter_mut()
                .find(|c| c.id == id)
                .ok_or_else(|| Error::new(1, "Unknown clip id"))?;
            let patch = v["patch"]
                .as_object()
                .ok_or_else(|| Error::new(1, "Missing clip settings patch"))?;
            let mut settings = serde_json::to_value(&c.settings)?;
            for (key, value) in patch {
                if settings.get(key).is_none() {
                    return Err(Error::new(1, "Unknown clip setting"));
                }
                settings[key] = value.clone();
            }
            c.settings = serde_json::from_value(settings)?;
            cs.changed.push("timeline.clips".into());
        }
        op @ ("insert_zoom" | "insert_layout" | "insert_mask") => {
            let start = match v.get("tl_start_ns") {
                Some(v) => v
                    .as_i64()
                    .ok_or_else(|| Error::new(1, "Invalid insertion time"))?,
                None => 0,
            };
            let duration = match v.get("duration_ns") {
                Some(v) => v
                    .as_i64()
                    .ok_or_else(|| Error::new(1, "Invalid insertion duration"))?,
                None => 3_000_000_000,
            };
            let end = start
                .saturating_add(duration)
                .min(time::duration(&p.timeline.clips));
            let minimum = if op == "insert_zoom" {
                CLIP_MIN
            } else {
                REGION_MIN
            };
            if start < 0 || duration < minimum || end - start < minimum {
                return Err(fail());
            }
            let patch = match v.get("patch") {
                Some(v) => v
                    .as_object()
                    .cloned()
                    .ok_or_else(|| Error::new(1, "Invalid insertion patch"))?,
                None => Default::default(),
            };
            let mut row = match op {
                "insert_zoom" => {
                    json!({"style":"classic","lens":ZoomLens::default(),"mode":"auto","scale":p.zoom_settings.default_scale,"target":[0.5,0.5],"ease_in_ns":300_000_000,"ease_out_ns":300_000_000,"enabled":true})
                }
                "insert_layout" => {
                    json!({"enabled":true,"mode":"overlay","settings":null,"camera_position":null,"camera_size":null,"camera_background_removal":null,"camera_face_framing":null,"camera_shadow_radius":null})
                }
                _ => serde_json::to_value(Highlight::default())?,
            };
            if op == "insert_zoom" {
                if let Some(style) = &p.insertion_styles.zoom {
                    merge_style(&mut row, serde_json::to_value(style)?);
                }
                if !patch.contains_key("target") {
                    if let Some((_clip, src)) = time::timeline_to_source(&p.timeline.clips, start) {
                        let screen = time::sample(&context.session, "screen", src);
                        let segment = screen.segment as usize;
                        let local = src - context.session.segments[segment].src_start_ns;
                        if let Some(point) =
                            context.input[segment].position_filtered(local, p.cursor.remove_shakes)
                        {
                            let bounds = context.session.source.content_rect_points;
                            row["target"] = json!([
                                (point.x / bounds[2]).clamp(0.0, 1.0),
                                (point.y / bounds[3]).clamp(0.0, 1.0)
                            ]);
                        }
                    }
                }
            }
            if op == "insert_mask" {
                if p.defaults_revision >= 2 {
                    row["dim_opacity"] = 0.5.into();
                    row["kind"] = "blur".into();
                }
                if let Some(style) = &p.insertion_styles.mask {
                    merge_style(&mut row, serde_json::to_value(style)?);
                }
            }
            for (key, value) in patch {
                if matches!(key.as_str(), "id" | "tl_start_ns" | "tl_end_ns")
                    || row.get(&key).is_none()
                {
                    return Err(Error::new(1, "Unknown/immutable insertion field"));
                }
                row[key] = value;
            }
            row["tl_start_ns"] = start.into();
            row["tl_end_ns"] = end.into();
            if op == "insert_zoom" {
                apply_inner(
                    p,
                    &json!({"op":"add_zoom","zoom":row}),
                    cs,
                    depth + 1,
                    context,
                )?;
            } else {
                let id = crate::project::unique_id(if op == "insert_layout" {
                    "layout"
                } else {
                    "mask"
                });
                row["id"] = id.clone().into();
                if op == "insert_layout" {
                    p.camera.layouts.push(serde_json::from_value(row)?);
                    cs.changed.push("camera.layouts".into());
                } else {
                    let mask: Highlight = serde_json::from_value(row)?;
                    p.insertion_styles.mask = Some(mask_style(&mask));
                    p.canvas.highlights.push(mask);
                    cs.changed.push("insertion_styles.mask".into());
                    cs.changed.push("canvas.highlights".into());
                }
                cs.created_ids.push(id);
            }
        }
        _ => return Ok(false),
    }
    Ok(true)
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::{input::InputCache, project::tests::Fixture};
    #[test]
    fn insertion_styles_follow_edits_history_and_persistence_without_geometry() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.data.autosave = false;
        let z=p.apply(&json!({"op":"insert_zoom","patch":{"mode":"manual","scale":3,"target":[0.1,0.2],"ease_in_ns":0}})).unwrap().created_ids[0].clone();
        p.apply(&json!({"op":"update_zoom","id":z,"patch":{"scale":2.5,"enabled":false}}))
            .unwrap();
        let frozen = p.clone();
        p.save(&f.0).unwrap();
        let mut reopened = Project::open(&f.0).unwrap();
        reopened
            .apply(&json!({"op":"insert_zoom","tl_start_ns":1_000_000_000}))
            .unwrap();
        let next = reopened.data.zooms.last().unwrap();
        assert_eq!(next.scale, 2.5);
        assert_eq!(next.mode, "manual");
        assert_eq!(next.target, [0.515625, 0.5125]);
        assert!(next.enabled);
        assert_eq!(next.ease_in_ns, 0);
        p.undo().unwrap();
        p.apply(&json!({"op":"insert_zoom"})).unwrap();
        assert_eq!(p.data.zooms.last().unwrap().scale, 3.0);
        assert_eq!(
            frozen.data.insertion_styles.zoom.as_ref().unwrap().scale,
            2.5
        );
        p.apply(&json!({"op":"set","path":"canvas.highlights","value":[{"id":"custom-mask","tl_start_ns":0,"tl_end_ns":1_000_000_000,"radius":30,"opacity":0.6,"rect":[0.1,0.1,0.2,0.2]}]})).unwrap();
        p.apply(&json!({"op":"insert_mask","tl_start_ns":1_000_000_000}))
            .unwrap();
        let next = p.data.canvas.highlights.last().unwrap();
        assert_eq!(next.radius, 30.0);
        assert_eq!(next.opacity, 0.6);
        assert_eq!(next.rect, [0.25, 0.25, 0.5, 0.5]);
    }
    #[test]
    fn inserted_auto_zoom_targets_the_cursor_at_its_start() {
        let fixture = Fixture::new();
        let mut p = Project::create(&fixture.0).unwrap();
        p.data.autosave = false;
        p.events[0] = vec![serde_json::from_value(json!({
            "t": 1_000_000_000_i64,
            "type": "move",
            "x": 256.0,
            "y": 60.0
        }))
        .unwrap()];
        p.input[0] = InputCache::new(&p.events[0]);
        p.apply(&json!({"op":"insert_zoom","tl_start_ns":1_000_000_000_i64}))
            .unwrap();
        assert_eq!(p.data.zooms.last().unwrap().target, [0.8, 0.3]);

        p.apply(&json!({"op":"insert_zoom","tl_start_ns":2_000_000_000_i64,
            "patch":{"target":[0.2,0.4]}}))
            .unwrap();
        assert_eq!(p.data.zooms.last().unwrap().target, [0.2, 0.4]);
    }
    #[test]
    fn coalesced_history_groups_and_caps_without_changing_discrete_commands() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.data.autosave = false;
        let before = p.data.clone();
        for value in [51, 52, 53] {
            p.apply(&json!({"op":"coalesced_edit","key":"padding-drag","command":{"op":"set","path":"canvas.padding","value":value}})).unwrap();
        }
        assert_eq!(p.undo.len(), 1);
        assert_eq!(p.data.canvas.padding, 53.0);
        p.undo().unwrap();
        assert_eq!(p.data, before);
        p.redo().unwrap();
        assert_eq!(p.data.canvas.padding, 53.0);
        p.apply(&json!({"op":"coalesced_edit","key":"padding-drag","command":{"op":"set","path":"canvas.padding","value":54}})).unwrap();
        assert_eq!(p.undo.len(), 2);
        p.undo_group.as_mut().unwrap().1 -= std::time::Duration::from_millis(100);
        p.apply(&json!({"op":"coalesced_edit","key":"padding-drag","command":{"op":"set","path":"canvas.padding","value":55}})).unwrap();
        assert_eq!(p.undo.len(), 3);
        for i in 0..1001 {
            p.apply(&json!({"op":"set","path":"notes","value":format!("step-{i}")}))
                .unwrap();
        }
        assert_eq!(p.undo.len(), 1000);
        let newest = p.data.notes.clone();
        for _ in 0..1000 {
            assert!(p.undo().unwrap());
        }
        assert!(!p.undo().unwrap());
        for _ in 0..1000 {
            assert!(p.redo().unwrap());
        }
        assert_eq!(p.data.notes, newest);
        let before = p.data.clone();
        let history = p.undo.len();
        assert!(p.apply(&json!({"op":"coalesced_edit","key":"","command":{"op":"set","path":"notes","value":"bad"}})).is_err());
        assert_eq!(p.data, before);
        assert_eq!(p.undo.len(), history);
    }
    #[test]
    fn checked_minimums_insert_defaults_and_clip_controls_roundtrip() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.data.autosave = false;
        let before = p.data.clone();
        for command in [
            json!({"op":"split","at_tl_ns":99_999_999}),
            json!({"op":"insert_layout","duration_ns":499_999_999}),
            json!({"op":"insert_mask","tl_start_ns":4_600_000_000_i64}),
        ] {
            assert!(p
                .apply(&json!({"op":"timeline_edit","command":command}))
                .is_err());
            assert_eq!(p.data, before);
            assert!(p.undo.is_empty());
        }
        p.apply(&json!({"op":"timeline_edit","command":{"op":"split","at_tl_ns":100_000_000}}))
            .unwrap();
        p.undo().unwrap();
        for op in ["insert_zoom", "insert_layout", "insert_mask"] {
            let result = p.apply(&json!({"op":op})).unwrap();
            assert_eq!(result.created_ids.len(), 1);
        }
        assert_eq!(p.data.zooms[0].tl_end_ns, 3_000_000_000);
        assert_eq!(p.data.camera.layouts[0].tl_end_ns, 3_000_000_000);
        assert_eq!(p.data.canvas.highlights[0].tl_end_ns, 3_000_000_000);
        let id = p.data.timeline.clips[0].id.clone();
        let keys = p.key_overlay_index.clone();
        p.apply(&json!({"op":"set_clip_settings","clip_id":id,"patch":{"mic_gain":0.5,"system_gain":0,"hide_cursor":true,"disable_smoothing":true}})).unwrap();
        assert!(std::sync::Arc::ptr_eq(&keys, &p.key_overlay_index));
        assert_eq!(p.frame(0).unwrap().mic_gain, 0.5);
        assert_eq!(p.frame(0).unwrap().system_gain, 0.0);
        assert_eq!(p.frame(0).unwrap().cursor_visible, 0);
        assert_eq!(
            p.query(&json!({"q":"audio_ranges"})).unwrap()[0]["gain"],
            0.0
        );
        p.apply(&json!({"op":"set","path":"cursor.speed_preset","value":"smooth"}))
            .unwrap();
        p.apply(&json!({"op":"set_clip_settings","clip_id":id,"patch":{"hide_cursor":false,"disable_smoothing":true}})).unwrap();
        let raw = p.frame(500_000_000).unwrap().cursor_x;
        p.apply(
            &json!({"op":"set_clip_settings","clip_id":id,"patch":{"disable_smoothing":false}}),
        )
        .unwrap();
        assert_ne!(p.frame(500_000_000).unwrap().cursor_x, raw);
        p.apply(&json!({"op":"split","at_tl_ns":1_000_000_000}))
            .unwrap();
        assert_eq!(
            p.data.timeline.clips[0].settings,
            p.data.timeline.clips[1].settings
        );
        p.save(&f.0).unwrap();
        assert_eq!(Project::open(&f.0).unwrap().data.timeline, p.data.timeline);
        let before = p.data.clone();
        assert!(p
            .apply(&json!({"op":"set_clip_settings","clip_id":id,"patch":{"mic_gain":1.1}}))
            .is_err());
        assert_eq!(p.data, before);
    }
}
