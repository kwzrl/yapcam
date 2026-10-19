//! Lens instructions share classic zoom selection and spring timing.
use crate::{
    model::Zoom,
    project::{Project, Result},
};
use serde_json::{json, Value};
pub(crate) fn active(p: &Project, tl: i64, can_auto: bool) -> Option<&Zoom> {
    let duration = crate::time::duration(&p.data.timeline.clips);
    p.data
        .zooms
        .iter()
        .filter(|z| is_active(p, z, tl, can_auto, duration))
        .max_by_key(|z| z.tl_start_ns)
}
/// The active classic zoom with its weight. While the next zoom eases in over one that is still on, the view
/// glides from the earlier target and scale to the next one and stays zoomed, instead of zooming out and back in.
/// Returns the zoom, its (glided) target and scale, and its weight; allocation free for frame queries.
pub(crate) fn blended(p: &Project, tl: i64, can_auto: bool) -> Option<(&Zoom, [f64; 2], f64, f64)> {
    let z = active(p, tl, can_auto)?;
    let w = weight(p, z, tl);
    if p.data.zoom_settings.physics_version < 2 || z.style != "classic" || w >= 1.0 {
        return Some((z, z.target, z.scale, w));
    }
    let duration = crate::time::duration(&p.data.timeline.clips);
    let prior = p
        .data
        .zooms
        .iter()
        .filter(|o| o.style == "classic" && o.tl_start_ns < z.tl_start_ns)
        .filter(|o| is_active(p, o, tl, can_auto, duration))
        .max_by_key(|o| o.tl_start_ns);
    let Some(prior) = prior else {
        return Some((z, z.target, z.scale, w));
    };
    let wp = weight(p, prior, tl);
    if wp <= w {
        return Some((z, z.target, z.scale, w));
    }
    let mix = |a: f64, b: f64| a + (b - a) * w;
    let target = [mix(prior.target[0], z.target[0]), mix(prior.target[1], z.target[1])];
    Some((z, target, mix(prior.scale, z.scale), wp))
}
fn is_active(p: &Project, z: &Zoom, tl: i64, can_auto: bool, duration: i64) -> bool {
            z.enabled
                && (z.mode != "auto" || p.data.zoom_settings.automatic && can_auto)
                && if p.data.zoom_settings.physics_version >= 2 {
                    let span = z.tl_end_ns - z.tl_start_ns;
                    let lead = if p.data.zoom_settings.start_early {
                        z.ease_in_ns.max(350_000_000)
                    } else {
                        z.ease_in_ns
                    }
                    .min(span / 2);
                    let trail = z.ease_out_ns.min(span / 2);
                    tl >= z.tl_start_ns.saturating_sub(lead).max(0)
                        && tl < z.tl_end_ns.saturating_add(trail).min(duration)
                } else {
                    tl >= if p.data.zoom_settings.start_early {
                        z.tl_start_ns.saturating_sub(350_000_000).max(0)
                    } else {
                        z.tl_start_ns
                    } && tl < z.tl_end_ns
                }
}
pub(crate) fn weight(p: &Project, z: &Zoom, tl: i64) -> f64 {
    let settings = &p.data.zoom_settings;
    if settings.physics_version >= 2 {
        let span = z.tl_end_ns - z.tl_start_ns;
        let incoming = if settings.start_early {
            z.ease_in_ns.max(350_000_000)
        } else {
            z.ease_in_ns
        }
        .min(span / 2);
        let physics = crate::motion::zoom_spring(settings);
        if tl < z.tl_start_ns {
            return crate::spring::response(
                (tl - z.tl_start_ns.saturating_sub(incoming).max(0)) as f64 / 1e9,
                &physics,
            );
        }
        if tl >= z.tl_end_ns {
            return 1.0 - crate::spring::response((tl - z.tl_end_ns) as f64 / 1e9, &physics);
        }
        return 1.0;
    }
    let start = if settings.start_early {
        z.tl_start_ns.saturating_sub(350_000_000).max(0)
    } else {
        z.tl_start_ns
    };
    let span = z.tl_end_ns - start;
    let incoming = if settings.start_early {
        z.tl_start_ns - start
    } else if settings.physics_version == 1 {
        z.ease_in_ns.min(span / 2)
    } else {
        z.ease_in_ns
    };
    let outgoing = if settings.physics_version == 1 {
        z.ease_out_ns.min(span / 2)
    } else {
        z.ease_out_ns
    };
    let inside = if incoming == 0 {
        1.0
    } else {
        (tl - start) as f64 / incoming as f64
    };
    let outside = if outgoing == 0 {
        1.0
    } else {
        (z.tl_end_ns - tl) as f64 / outgoing as f64
    };
    let ramp = if inside < outside { incoming } else { outgoing };
    let physics = crate::motion::zoom_spring(settings);
    if settings.physics_version == 1 {
        crate::spring::aligned_transition(
            inside.min(outside),
            ramp as f64 / 1e9,
            p.session.tracks.screen.max_fps as f64,
            &physics,
        )
    } else {
        crate::spring::transition(inside.min(outside), ramp as f64 / 1e9, &physics)
    }
}
pub(crate) fn query(p: &Project, tl: i64) -> Result<Value> {
    let frame = p.frame_geometry(tl)?;
    let Some(z) = active(p, tl, p.capabilities().can_auto_zoom)
        .filter(|z| z.style == "lens" && frame.screen.present != 0)
    else {
        return Ok(Value::Null);
    };
    let weight = weight(p, z, tl);
    if weight <= 0.0 {
        return Ok(Value::Null);
    }
    let mut target = z.target;
    if z.mode == "auto" && p.data.zoom_settings.follow_cursor {
        let seg = frame.screen.segment as usize;
        let (_, src) = crate::time::timeline_to_source(&p.data.timeline.clips, tl).unwrap();
        if let Some(point) = p.input[seg].position_filtered(
            src - p.session.segments[seg].src_start_ns,
            p.data.cursor.remove_shakes,
        ) {
            target = [
                point.x / p.session.source.content_rect_points[2],
                point.y / p.session.source.content_rect_points[3],
            ];
        }
    }
    let crop = frame.screen_crop;
    target[0] = target[0].max(crop.x).min(crop.x + crop.w);
    target[1] = target[1].max(crop.y).min(crop.y + crop.h);
    let dest = frame.screen_dest;
    Ok(
        json!({"zoom_id":z.id,"center":[dest.x+(target[0]-crop.x)/crop.w*dest.w,dest.y+(target[1]-crop.y)/crop.h*dest.h],
        "source_center":target,"scale":1.0+(z.scale-1.0)*weight,
        "radius_px":z.lens.radius*dest.w.min(dest.h),"bevel":z.lens.bevel,
        "chromatic_aberration":z.lens.chromatic_aberration,"opacity":weight.clamp(0.0,1.0)}),
    )
}
pub(crate) fn valid(style: &str, lens: &crate::model::ZoomLens) -> bool {
    matches!(style, "classic" | "lens")
        && (0.25..=0.75).contains(&lens.radius)
        && (0.0..=1.0).contains(&lens.bevel)
        && (0.0..=1.0).contains(&lens.chromatic_aberration)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::tests::Fixture;
    #[test]
    fn revision_four_zoom_at_frame_zero_starts_fully_zoomed() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.data.autosave = false;
        p.apply(
            &json!({"op":"insert_zoom","tl_start_ns":0,"duration_ns":2_000_000_000_i64,
            "patch":{"mode":"manual","target":[0.5,0.5],"scale":2}}),
        )
        .unwrap();
        let frame = p.frame(0).unwrap();
        assert!((frame.screen_crop.w - 0.5).abs() < 1e-9);
        assert!((frame.screen_crop.h - 0.5).abs() < 1e-9);
    }
    #[test]
    fn lens_shares_timing_without_changing_base_crop_and_inherits_style() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.data.autosave = false;
        let original = p.frame(500_000_000).unwrap().screen_crop;
        let id=p.apply(&json!({"op":"add_zoom","zoom":{"tl_start_ns":100_000_000,"tl_end_ns":2_000_000_000_i64,"mode":"manual","style":"lens","lens":{"radius":0.4},"target":[0.25,0.75],"scale":2,"ease_in_ns":0,"ease_out_ns":0}})).unwrap().created_ids[0].clone();
        let q = query(&p, 500_000_000).unwrap();
        assert_eq!(p.frame(500_000_000).unwrap().screen_crop, original);
        assert_eq!(q["scale"], 2.0);
        assert_eq!(q["source_center"], json!([0.25, 0.75]));
        assert_eq!(q["zoom_id"], id);
        assert!(query(&p, 0).unwrap().is_null());
        assert!(query(&p, 2_000_000_000).unwrap().is_null());
        let preset = p.query(&json!({"q":"preset"})).unwrap();
        assert!(preset.get("zooms").is_none());
        let second = p
            .apply(&json!({"op":"insert_zoom","tl_start_ns":2_000_000_000_i64}))
            .unwrap()
            .created_ids[0]
            .clone();
        assert_eq!(p.data.zooms[1].style, "lens");
        assert_eq!(p.data.zooms[1].lens.radius, 0.4);
        p.apply(&json!({"op":"update_zoom","id":id,"patch":{"style":"classic"}}))
            .unwrap();
        assert!(query(&p, 500_000_000).unwrap().is_null());
        assert!(p.frame(500_000_000).unwrap().screen_crop.w < original.w);
        p.undo().unwrap();
        assert_eq!(query(&p, 500_000_000).unwrap(), q);
        let before = p.data.clone();
        for patch in [
            json!({"style":"unknown"}),
            json!({"lens":{"radius":0.9}}),
            json!({"lens":{"bevel":-1}}),
        ] {
            assert!(p
                .apply(&json!({"op":"update_zoom","id":second,"patch":patch}))
                .is_err());
            assert_eq!(p.data, before);
        }
        p.save(&f.0).unwrap();
        assert_eq!(
            query(&Project::open(&f.0).unwrap(), 500_000_000).unwrap(),
            q
        );
        assert_eq!(
            crate::allocation_test::count(|| {
                p.frame(500_000_000).unwrap();
            }),
            0
        );
    }
}
