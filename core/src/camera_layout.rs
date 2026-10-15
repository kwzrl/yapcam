//! Shared camera layout selection, geometry policy and decoded-silence gates.
use crate::{
    frame::Rect,
    model::*,
    project::{Error, Project, Result},
};
use serde_json::{json, Value};
pub(crate) fn current(p: &ProjectData, tl: i64) -> (&str, &CameraLayoutSettings) {
    p.camera
        .layouts
        .iter()
        .filter(|l| tl >= l.tl_start_ns && tl < l.tl_end_ns)
        .max_by_key(|l| l.tl_start_ns)
        .map_or(
            (
                p.camera.layout_settings.mode.as_str(),
                &p.camera.layout_settings,
            ),
            |l| {
                (
                    l.mode.as_str(),
                    l.settings.as_ref().unwrap_or(&p.camera.layout_settings),
                )
            },
        )
}
pub(crate) fn hidden_by_silence(p: &ProjectData, tl: i64) -> bool {
    if !p.camera.hide_during_silence {
        return false;
    }
    let ranges = &p.camera.silence_ranges;
    ranges
        .partition_point(|r| r.tl_start_ns <= tl)
        .checked_sub(1)
        .is_some_and(|i| {
            tl < ranges[i].tl_end_ns
                && ranges[i].tl_end_ns - ranges[i].tl_start_ns >= p.camera.min_silence_ns
        })
}
pub(crate) fn split_regions(area: Rect, ratio: f64, horizontal: bool, flip: bool) -> (Rect, Rect) {
    let fraction = if flip { 1.0 - ratio } else { ratio };
    let (first, second) = if horizontal {
        (
            Rect {
                w: area.w * fraction,
                ..area
            },
            Rect {
                x: area.x + area.w * fraction,
                w: area.w * (1.0 - fraction),
                ..area
            },
        )
    } else {
        (
            Rect {
                h: area.h * fraction,
                ..area
            },
            Rect {
                y: area.y + area.h * fraction,
                h: area.h * (1.0 - fraction),
                ..area
            },
        )
    };
    if flip {
        (second, first)
    } else {
        (first, second)
    }
}
pub(crate) fn query(p: &Project, tl: Option<i64>) -> Result<Value> {
    let (mode, settings) = tl.map_or(
        (
            p.data.camera.layout_settings.mode.as_str(),
            &p.data.camera.layout_settings,
        ),
        |t| current(&p.data, t),
    );
    let visible = match tl {
        Some(t) => p.frame(t)?.camera.present != 0,
        None => p.data.camera.visible && p.session.tracks.camera.is_some(),
    };
    Ok(json!({"mode":mode,"settings":settings,"visible":visible}))
}
pub(crate) fn validate(p: &ProjectData) -> Result<()> {
    fn valid(s: &CameraLayoutSettings) -> bool {
        matches!(s.mode.as_str(), "overlay" | "cutout" | "split")
            && s.aspect.is_none_or(|a| {
                [16.0 / 9.0, 4.0 / 3.0, 1.0, 3.0 / 4.0, 9.0 / 16.0]
                    .iter()
                    .any(|v| (a - v).abs() < 1e-9)
            })
            && s.split_ratio
                .is_none_or(|r| (r - 0.5).abs() < 1e-9 || (r - 2.0 / 3.0).abs() < 1e-9)
            && s.cutout_position.iter().all(|v| (0.0..=1.0).contains(v))
            && (0.2..=1.0).contains(&s.cutout_size)
            && (0.0..=1.0).contains(&s.edge_softness)
            && (0.0..=8.0).contains(&s.edge_inset)
            && s.corner_ratio.is_none_or(|v| (0.0..=0.5).contains(&v))
    }
    if !valid(&p.camera.layout_settings)
        || p.camera
            .layouts
            .iter()
            .any(|l| l.settings.as_ref().is_some_and(|s| !valid(s)))
        || !(2_000_000_000..=15_000_000_000_i64).contains(&p.camera.min_silence_ns)
        || p.camera
            .silence_ranges
            .iter()
            .any(|r| r.tl_start_ns < 0 || r.tl_end_ns <= r.tl_start_ns)
        || p.camera
            .silence_ranges
            .windows(2)
            .any(|r| r[0].tl_end_ns > r[1].tl_start_ns)
    {
        return Err(Error::new(
            1,
            "Invalid camera layout settings or silence ranges",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{allocation_test, model::CameraTrack, project::tests::Fixture};
    fn make() -> (Fixture, Project) {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.data.autosave = false;
        p.session.tracks.camera = Some(CameraTrack {
            device_name: "Synthetic camera".into(),
            pixel_size: [320, 200],
            fps: 30.0,
            mirrored: false,
        });
        for seg in &mut p.session.segments {
            seg.files
                .insert("camera".into(), seg.files["screen"].clone());
        }
        (f, p)
    }
    #[test]
    fn cutout_split_orientation_overrides_and_legacy_geometry_are_allocation_free() {
        let (_f, mut p) = make();
        let legacy = p.frame(0).unwrap();
        let original = p.data.clone();
        for (aspect, mode, flip, padded) in [
            ("16:9", "split", false, false),
            ("9:16", "split", true, true),
            ("16:9", "cutout", false, false),
            ("9:16", "overlay", false, false),
        ] {
            p.apply(&json!({"op":"batch","commands":[{"op":"set","path":"canvas.aspect","value":aspect},
                {"op":"set","path":"camera.layout_settings","value":{"mode":mode,"aspect":1,"split_ratio":0.5,"split_flip":flip,"split_padded":padded,"corner_ratio":0.2}}]})).unwrap();
            let frame = p.frame(0).unwrap();
            assert_eq!(frame.camera.present, 1);
            assert!((frame.camera_dest.w / frame.camera_dest.h - 1.0).abs() < 1e-9);
            assert!(frame.camera_dest.x >= 0.0 && frame.camera_dest.y >= 0.0);
            assert!(frame.camera_dest.x + frame.camera_dest.w <= frame.canvas_w as f64 + 1e-9);
            assert!(frame.camera_dest.y + frame.camera_dest.h <= frame.canvas_h as f64 + 1e-9);
            if mode == "cutout" {
                assert_eq!(frame.camera_corner_radius, 0.0);
                assert_eq!(p.frame_extras(0).unwrap().camera_background_removal, 1);
            }
            if mode == "split" {
                if aspect == "16:9" {
                    assert!(
                        frame.screen_dest.x + frame.screen_dest.w <= frame.camera_dest.x + 1e-9
                    );
                } else {
                    assert!(
                        frame.camera_dest.y + frame.camera_dest.h <= frame.screen_dest.y + 1e-9
                    );
                }
            }
            let query = query(&p, Some(0)).unwrap();
            assert_eq!(query["mode"], mode);
            assert_eq!(query["visible"], true);
            assert_eq!(
                allocation_test::count(|| {
                    p.frame(0).unwrap();
                    p.frame_extras(0).unwrap();
                }),
                0
            );
            p.undo().unwrap();
        }
        assert_eq!(p.data, original);
        assert_eq!(p.frame(0).unwrap().camera_dest, legacy.camera_dest);
        for crop in [
            [0.0, 0.0, f64::from_bits(1), 1.0],
            [0.0, 0.0, 1.0, f64::from_bits(1)],
        ] {
            p.data.camera.style.crop = crop;
            let rect = p.frame(0).unwrap().camera_dest;
            assert!([rect.x, rect.y, rect.w, rect.h]
                .iter()
                .all(|v| v.is_finite()));
        }
        p.data.camera.style.crop = original.camera.style.crop;
        p.apply(&json!({"op":"set","path":"camera.layouts","value":[{"id":"range","tl_start_ns":1_000_000_000,"tl_end_ns":2_000_000_000,"mode":"split","settings":{"split_ratio":0.5,"split_flip":true}}]})).unwrap();
        assert_eq!(query(&p, Some(0)).unwrap()["mode"], "overlay");
        assert_eq!(query(&p, Some(1_000_000_000)).unwrap()["mode"], "split");
        assert_eq!(query(&p, Some(2_000_000_000)).unwrap()["mode"], "overlay");
        p.session.tracks.camera = None;
        let frame = p.frame(1_000_000_000).unwrap();
        assert_eq!(frame.camera.present, 0);
        assert_eq!(frame.screen.present, 1);
    }
    #[test]
    fn silence_gates_retime_validate_and_never_enter_presets() {
        let (_f, mut p) = make();
        p.apply(&json!({"op":"batch","commands":[
            {"op":"set","path":"camera.hide_during_silence","value":true},
            {"op":"set","path":"camera.min_silence_ns","value":2_000_000_000},
            {"op":"set","path":"camera.silence_ranges","value":[{"tl_start_ns":1_000_000_000,"tl_end_ns":3_000_000_000_i64}]},
            {"op":"set","path":"camera.layouts","value":[{"id":"full","tl_start_ns":0,"tl_end_ns":4_000_000_000_i64,"mode":"camera"}]}
        ]})).unwrap();
        assert_eq!(p.frame(0).unwrap().screen.present, 0);
        assert_eq!(p.frame(1_000_000_000).unwrap().camera.present, 0);
        assert_eq!(p.frame(1_000_000_000).unwrap().screen.present, 1);
        assert_eq!(p.frame(3_000_000_000).unwrap().camera.present, 1);
        let preset = p.query(&json!({"q":"preset"})).unwrap();
        assert!(preset["camera"].get("silence_ranges").is_none());
        p.apply(&json!({"op":"set_speed","clip_id":p.data.timeline.clips[0].id,"speed":2}))
            .unwrap();
        assert_eq!(p.data.camera.silence_ranges[0].tl_start_ns, 500_000_000);
        assert_eq!(p.frame(500_000_000).unwrap().camera.present, 1); // now shorter than minimum
        p.undo().unwrap();
        assert_eq!(p.frame(1_000_000_000).unwrap().camera.present, 0);
        let before = p.data.clone();
        for (path, value) in [
            ("min_silence_ns", json!(1)),
            (
                "silence_ranges",
                json!([{"tl_start_ns":2,"tl_end_ns":4},{"tl_start_ns":1,"tl_end_ns":3}]),
            ),
            ("layout_settings.split_ratio", json!(0.1)),
            ("layout_settings.aspect", json!(0)),
            ("layout_settings.edge_inset", json!(9)),
        ] {
            assert!(p
                .apply(&json!({"op":"set","path":format!("camera.{path}"),"value":value}))
                .is_err());
            assert_eq!(p.data, before);
        }
    }
}
