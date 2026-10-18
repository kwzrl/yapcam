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
        .filter(|l| l.enabled && tl >= l.tl_start_ns && tl < l.tl_end_ns)
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
pub(crate) fn source_crop(p: &Project, tl: i64) -> [f64; 4] {
    let authored = p.data.camera.style.crop;
    if p.data.defaults_revision < 4 || current(&p.data, tl).0 != "camera" {
        return authored;
    }
    let Some(track) = &p.session.tracks.camera else {
        return authored;
    };
    let source_aspect =
        track.pixel_size[0] as f64 / track.pixel_size[1].max(1) as f64 * authored[2] / authored[3];
    let frame = p.frame(tl).ok();
    let destination_aspect = frame.as_ref().map_or(source_aspect, |f| {
        f.canvas_w as f64 / f.canvas_h.max(1) as f64
    });
    if source_aspect > destination_aspect {
        let width = destination_aspect / source_aspect;
        [
            authored[0] + authored[2] * (1.0 - width) / 2.0,
            authored[1],
            authored[2] * width,
            authored[3],
        ]
    } else {
        let height = source_aspect / destination_aspect;
        [
            authored[0],
            authored[1] + authored[3] * (1.0 - height) / 2.0,
            authored[2],
            authored[3] * height,
        ]
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
            && matches!(
                s.split_direction.as_str(),
                "auto" | "horizontal" | "vertical"
            )
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
            && (0.0..=1.0).contains(&s.edge_padding_ratio)
            && s.edge_distance_ratio
                .is_none_or(|v| (0.0..=0.5).contains(&v))
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
    fn cam14_fullscreen_fills_canvas_and_reports_centered_aspect_fill_crop() {
        let (_f, mut p) = make();
        p.session.tracks.camera.as_mut().unwrap().pixel_size = [640, 480];
        p.apply(&json!({"op":"batch","commands":[
            {"op":"set","path":"canvas.aspect","value":"custom"},
            {"op":"set","path":"canvas.output_size","value":[1920,1080]},
            {"op":"set","path":"camera.layouts","value":[{"id":"full","tl_start_ns":0,"tl_end_ns":2_000_000_000_i64,"mode":"camera"}]}
        ]}))
        .unwrap();
        let frame = p.frame(1_000_000_000).unwrap();
        assert_eq!(
            frame.camera_dest,
            Rect {
                x: 0.0,
                y: 0.0,
                w: 1920.0,
                h: 1080.0
            }
        );
        assert_eq!(frame.camera_corner_radius, 0.0);
        assert_eq!(source_crop(&p, 1_000_000_000), [0.0, 0.125, 1.0, 0.75]);
        assert_eq!(
            p.query(&json!({"q":"render_options_at","tl_ns":1_000_000_000_i64}))
                .unwrap()["camera_source_crop"],
            json!([0.0, 0.125, 1.0, 0.75])
        );
        assert_eq!(
            p.query(&json!({"q":"render_options_at","tl_ns":1_000_000_000_i64}))
                .unwrap()["camera_shadow_radius"],
            0.0
        );
    }
    #[test]
    fn camera_roundness_one_tracks_half_the_evaluated_short_edge() {
        let (fixture, mut p) = make();
        p.apply(&json!({"op":"batch","commands":[
            {"op":"set","path":"camera.layout_settings.aspect","value":1},
            {"op":"set","path":"camera.roundness","value":1}
        ]}))
        .unwrap();
        let frame = p.frame(0).unwrap();
        assert!((frame.camera_dest.w - frame.camera_dest.h).abs() < 1e-9);
        assert!((frame.camera_corner_radius as f64 - frame.camera_dest.w / 2.0).abs() < 1e-5);
        p.save(&fixture.0).unwrap();
        let reopened = Project::open(&fixture.0).unwrap().frame(0).unwrap();
        assert_eq!(reopened.camera_corner_radius, frame.camera_corner_radius);
    }
    #[test]
    fn cam21_layout_boundaries_animate_geometry_and_hidden_opacity() {
        let (_f, mut p) = make();
        p.apply(&json!({"op":"set","path":"camera.layouts","value":[{"id":"full","tl_start_ns":2_000_000_000_i64,"tl_end_ns":4_000_000_000_i64,"mode":"camera"}]}))
            .unwrap();
        let before = p.frame(1_825_000_000).unwrap();
        let entering = p.frame(1_900_000_000).unwrap();
        let leaving = p.frame(2_100_000_000).unwrap();
        let after = p.frame(2_175_000_000).unwrap();
        assert!(
            before.camera_dest.w < entering.camera_dest.w
                && entering.camera_dest.w < leaving.camera_dest.w
                && leaving.camera_dest.w < after.camera_dest.w
        );
        assert_eq!(after.camera_dest.w, after.canvas_w as f64);
        assert_eq!(after.camera_corner_radius, 0.0);
        let screen_opacity = p
            .query(&json!({"q":"render_options_at","tl_ns":1_900_000_000_i64}))
            .unwrap()["screen_opacity"]
            .as_f64()
            .unwrap();
        assert!((0.0..1.0).contains(&screen_opacity));

        p.apply(&json!({"op":"set","path":"camera.layouts","value":[{"id":"hidden","tl_start_ns":2_000_000_000_i64,"tl_end_ns":4_000_000_000_i64,"mode":"screen"}]}))
            .unwrap();
        let opacities: Vec<_> = [1_825_000_000, 1_900_000_000, 2_100_000_000, 2_175_000_000]
            .map(|t| p.frame(t).unwrap().camera_opacity)
            .into();
        assert_eq!(opacities[0], 1.0);
        assert!(opacities[0] > opacities[1] && opacities[1] > opacities[2]);
        assert_eq!(opacities[3], 0.0);
        let camera_blur = p
            .query(&json!({"q":"render_options_at","tl_ns":1_900_000_000_i64}))
            .unwrap()["camera_blur"]
            .as_f64()
            .unwrap();
        assert!((0.0..1.0).contains(&camera_blur));
        assert_eq!(
            allocation_test::count(|| {
                std::hint::black_box(p.frame(1_900_000_000).unwrap());
            }),
            0
        );
    }
    #[test]
    fn legacy_revisions_keep_padded_camera_geometry_and_hard_layout_cuts() {
        let assert_rect = |actual: Rect, expected: [f64; 4], label: &str| {
            for (actual, expected) in [actual.x, actual.y, actual.w, actual.h]
                .into_iter()
                .zip(expected)
            {
                assert!(
                    (actual - expected).abs() <= 1e-6,
                    "{label}: {actual} != {expected}"
                );
            }
        };
        let assert_geometry = |p: &Project, revision| {
            let before = p.frame(950_000_000).unwrap();
            let immediately_before = p.frame(999_999_999).unwrap();
            assert_rect(
                before.camera_dest,
                [1363.2, 710.4, 422.4, 264.0],
                &format!("revision {revision} overlay"),
            );
            assert_rect(
                immediately_before.camera_dest,
                [1363.2, 710.4, 422.4, 264.0],
                &format!("revision {revision} immediately before cut"),
            );
            let at_cut = p.frame(1_000_000_000).unwrap();
            assert_rect(
                at_cut.camera_dest,
                [172.8, 48.0, 1574.4, 984.0],
                &format!("revision {revision} at hard cut"),
            );
            let fullscreen = p.frame(1_500_000_000).unwrap();
            assert_rect(
                fullscreen.camera_dest,
                [172.8, 48.0, 1574.4, 984.0],
                &format!("revision {revision} padded fullscreen"),
            );
            assert_eq!(fullscreen.screen.present, 0);
            assert_eq!(fullscreen.camera_corner_radius, 24.0);
            assert_eq!(source_crop(p, 1_500_000_000), [0.0, 0.0, 1.0, 1.0]);
            let options = p
                .query(&json!({"q":"render_options_at","tl_ns":1_500_000_000_i64}))
                .unwrap();
            assert_eq!(options["camera_source_crop"], json!([0.0, 0.0, 1.0, 1.0]));
            assert_eq!(options["camera_shadow_radius"], p.data.camera.shadow_radius);
            assert_eq!(options["screen_opacity"], 0.0);
        };

        for revision in 0..=3 {
            // Mirror Render's frozen-fixture setup exactly: install a camera in
            // the recording manifest, then open v1-minimal with only the
            // defaults revision varied. This catches any factory-only fields
            // that could otherwise perturb legacy geometry.
            let fixture = Fixture::new();
            let session_path = fixture.0.join("recording/session.json");
            let mut session: Value =
                serde_json::from_slice(&std::fs::read(&session_path).unwrap()).unwrap();
            session["tracks"]["camera"] = json!({
                "device_name":"Original synthetic fixture",
                "pixel_size":[320,200],"fps":30,"mirrored":false
            });
            for segment in session["segments"].as_array_mut().unwrap() {
                segment["files"]["camera"] = segment["files"]["screen"].clone();
            }
            std::fs::write(&session_path, serde_json::to_vec(&session).unwrap()).unwrap();
            let schema_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../Tests/Fixtures/schema/v1-minimal.json");
            let mut project_json: Value =
                serde_json::from_slice(&std::fs::read(schema_path).unwrap()).unwrap();
            project_json["defaults_revision"] = revision.into();
            std::fs::write(
                fixture.0.join("project.json"),
                serde_json::to_vec(&project_json).unwrap(),
            )
            .unwrap();
            let mut p = Project::open(&fixture.0).unwrap();
            p.apply(&json!({"op":"set","path":"camera.layouts","value":[{
                "id":"legacy-fullscreen","tl_start_ns":1_000_000_000_i64,
                "tl_end_ns":2_000_000_000_i64,"mode":"camera"
            }]}))
            .unwrap();
            assert_geometry(&p, revision);
            let snapshot = p.clone();
            assert_geometry(&snapshot, revision);
            p.save(&fixture.0).unwrap();
            assert_geometry(&Project::open(&fixture.0).unwrap(), revision);
        }
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
        let hiding = p.frame(1_000_000_000).unwrap();
        assert_eq!(hiding.camera.present, 1);
        assert!((0.0..1.0).contains(&hiding.camera_opacity));
        assert_eq!(p.frame(1_000_000_000).unwrap().screen.present, 1);
        assert_eq!(p.frame(1_175_000_000).unwrap().camera.present, 0);
        assert_eq!(p.frame(3_000_000_000).unwrap().camera.present, 1);
        let preset = p.query(&json!({"q":"preset"})).unwrap();
        assert!(preset["camera"].get("silence_ranges").is_none());
        p.apply(&json!({"op":"set_speed","clip_id":p.data.timeline.clips[0].id,"speed":2}))
            .unwrap();
        assert_eq!(p.data.camera.silence_ranges[0].tl_start_ns, 500_000_000);
        assert_eq!(p.frame(500_000_000).unwrap().camera.present, 1); // now shorter than minimum
        p.undo().unwrap();
        assert_eq!(p.frame(1_175_000_000).unwrap().camera.present, 0);
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
