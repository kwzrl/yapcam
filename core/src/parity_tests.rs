//! Round-5 behavioural parity regressions, using synthetic model inputs only.
use crate::{
    model::*,
    project::{tests::Fixture, Project},
};
use serde_json::json;

#[test]
fn revision_four_smooth_cursor_and_camera_zoom_defaults_preserve_existing_projects() {
    let fixture = Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();
    assert_eq!(p.data.defaults_revision, 4);
    assert!(!p.data.camera.mirrored);
    assert_eq!(p.data.camera.position, [1.0, 1.0]);
    assert_eq!(p.data.camera.size, 0.5);
    assert_eq!(p.data.camera.zoom_scale, 0.6);
    assert_eq!(p.data.camera.layout_settings.aspect, Some(1.0));
    assert_eq!(p.data.camera.layout_settings.corner_ratio, Some(0.15));
    assert_eq!(p.data.camera.layout_settings.edge_padding_ratio, 0.5);
    assert_eq!(
        p.data.camera.layout_settings.edge_distance_ratio,
        Some(0.03)
    );
    assert_eq!(p.data.cursor.loop_duration_ns, 1_000_000_000);
    assert_eq!(p.data.cursor.click_duration_ns, 400_000_000);
    assert!(p.data.cursor.remove_shakes && p.data.cursor.optimize_types);
    assert_eq!(p.data.cursor.rotation_mode, "tilt");
    assert_eq!(p.data.cursor.tilt_amount, 0.5);
    // 0.11.0: a softer custom cursor spring (250/55/3) replaces the "smooth" preset for new projects.
    assert_eq!(p.data.cursor.speed_preset, "custom");
    assert_eq!(p.data.cursor.smoothing, 1.0);
    let cursor_spring = crate::spring::cursor_preset(
        &p.data.cursor.speed_preset,
        &p.data.cursor.spring,
        p.data.cursor.physics_version,
    );
    assert_eq!(
        (
            cursor_spring.tension,
            cursor_spring.friction,
            cursor_spring.mass
        ),
        (250.0, 55.0, 3.0)
    );
    assert_eq!(p.data.canvas.inset_color, [0.0, 0.0, 0.0, 0.5]);
    assert_eq!(p.data.canvas.screen_quality, Some(ScreenQuality::default()));
    p.session.tracks.camera = Some(CameraTrack {
        device_name: "Synthetic".into(),
        pixel_size: [320, 200],
        fps: 30.0,
        mirrored: false,
    });
    for segment in &mut p.session.segments {
        segment
            .files
            .insert("camera".into(), segment.files["screen"].clone());
    }
    let frame = p.frame(0).unwrap();
    assert_eq!(frame.camera.present, 1);
    assert_eq!(frame.camera_mirror, 0);
    assert!((frame.camera_dest.w / frame.camera_dest.h - 1.0).abs() < 1e-9);
    assert!(
        (frame.camera_dest.x + frame.camera_dest.w - frame.canvas_w as f64 + 32.4).abs() < 1e-9
    );
    assert!(
        (frame.camera_dest.y + frame.camera_dest.h - frame.canvas_h as f64 + 32.4).abs() < 1e-9
    );
    assert!((frame.camera_corner_radius as f64 - frame.camera_dest.w * 0.15).abs() < 1e-4);
    p.data.zooms.push(Zoom {
        id: "camera-shrink".into(),
        style: "classic".into(),
        lens: ZoomLens::default(),
        tl_start_ns: 500_000_000,
        tl_end_ns: 1_500_000_000,
        mode: "manual".into(),
        target: [0.5, 0.5],
        scale: 2.0,
        ease_in_ns: 0,
        ease_out_ns: 0,
        enabled: true,
    });
    let zoomed = p.frame(1_000_000_000).unwrap();
    assert!((zoomed.camera_dest.w - frame.camera_dest.w * 0.6).abs() < 1e-9);
    p.apply(&json!({"op":"insert_mask"})).unwrap();
    assert_eq!(p.data.canvas.highlights[0].dim_opacity, 0.5);
    let mut legacy = p.data.clone();
    legacy.defaults_revision = 1;
    legacy.camera = Camera::default();
    legacy.cursor = Cursor::default();
    legacy.canvas.screen_quality = None;
    let decoded = crate::project::decode_project(&serde_json::to_vec(&legacy).unwrap()).unwrap();
    assert_eq!(decoded, legacy);
    let mut raw = serde_json::to_value(&legacy).unwrap();
    raw["camera"]["layout_settings"]
        .as_object_mut()
        .unwrap()
        .remove("edge_padding_ratio");
    let decoded = crate::project::decode_project(&serde_json::to_vec(&raw).unwrap()).unwrap();
    assert_eq!(decoded.camera.layout_settings.edge_padding_ratio, 0.0);
    assert_eq!(decoded.camera.size, 0.22);
    assert!(decoded.camera.mirrored);
    assert_eq!(decoded.cursor.click_duration_ns, 400_000_000);
}

#[test]
fn bs1_factory_cursor_glides_at_full_strength_and_slice_opt_out_stays_raw() {
    let fixture = Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();
    p.data.cursor.remove_shakes = false;
    p.events[0] = vec![
        Event {
            t: 0,
            kind: "move".into(),
            x: Some(0.0),
            y: Some(100.0),
            id: None,
            details: Default::default(),
        },
        Event {
            t: 1_000_000_000,
            kind: "move".into(),
            x: Some(100.0),
            y: Some(100.0),
            id: None,
            details: Default::default(),
        },
    ];
    p.input[0] = crate::input::InputCache::new(&p.events[0]);

    let initial = p.frame(0).unwrap().cursor_x;
    p.data.timeline.clips[0].settings.disable_smoothing = true;
    let raw = p.frame(1_100_000_000).unwrap().cursor_x;
    p.data.timeline.clips[0].settings.disable_smoothing = false;
    let progress = |x: f64| (x - initial) / (raw - initial);
    let early = progress(p.frame(1_100_000_000).unwrap().cursor_x);
    let settled = progress(p.frame(1_800_000_000).unwrap().cursor_x);
    assert!(early > 0.05 && early < 0.95, "early progress {early}");
    assert!((0.99..=1.0).contains(&settled), "settled {settled}");
    for n in 0..=60 {
        assert!(
            progress(p.frame(1_000_000_000 + n * 10_000_000).unwrap().cursor_x) <= 1.0,
            "cursor overshot at sample {n}"
        );
    }
    p.data.timeline.clips[0].settings.disable_smoothing = true;
    assert_eq!(p.frame(1_100_000_000).unwrap().cursor_x, raw);
    assert_eq!(
        crate::allocation_test::count(|| {
            p.frame(1_100_000_000).unwrap();
        }),
        0
    );
}

#[test]
fn cursor_loop_returns_to_first_canvas_hotspot_after_edits_and_beats_stop() {
    let fixture = Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();
    p.data.autosave = false;
    p.apply(&json!({"op":"batch","commands":[
        {"op":"set","path":"cursor.loop_to_start","value":true},
        {"op":"set","path":"cursor.loop_duration_ns","value":2_000_000_000_i64},
        {"op":"set","path":"cursor.stop_before_end_ns","value":4_000_000_000_i64},
        {"op":"set","path":"canvas.crop","value":[0.1,0.1,0.7,0.7]}
    ]}))
    .unwrap();
    p.apply(&json!({"op":"add_zoom","tl_start_ns":2_000_000_000_i64,"tl_end_ns":6_000_000_000_i64,"mode":"manual","target":[0.7,0.7],"scale":2,"ease_in_ns":0,"ease_out_ns":0})).unwrap();
    for edited in [false, true] {
        if edited {
            p.apply(&json!({"op":"delete_range","tl_start_ns":0,"tl_end_ns":500_000_000}))
                .unwrap();
            p.apply(&json!({"op":"set_speed","clip_id":p.data.timeline.clips[0].id,"speed":1.6}))
                .unwrap();
        }
        let duration = crate::time::duration(&p.data.timeline.clips);
        let first = p.frame(0).unwrap();
        let end = p.frame(duration).unwrap();
        assert!((end.cursor_x - first.cursor_x).abs() < 1e-9);
        assert!((end.cursor_y - first.cursor_y).abs() < 1e-9);
        let near = p.frame(duration - 1_000).unwrap();
        assert!((near.cursor_x - first.cursor_x).abs() < 0.001);
        assert!((near.cursor_y - first.cursor_y).abs() < 0.001);
        assert_eq!(
            crate::allocation_test::count(|| {
                p.frame(duration).unwrap();
                p.frame_motion(duration).unwrap();
            }),
            0
        );
    }
    p.save(&fixture.0).unwrap();
    let reopened = Project::open(&fixture.0).unwrap();
    let t = crate::time::duration(&p.data.timeline.clips);
    assert_eq!(
        reopened.frame(t).unwrap().cursor_x,
        p.frame(0).unwrap().cursor_x
    );
}

fn synthetic_camera(p: &mut Project) {
    p.session.tracks.camera = Some(CameraTrack {
        device_name: "Synthetic".into(),
        pixel_size: [320, 200],
        fps: 30.0,
        mirrored: false,
    });
    for segment in &mut p.session.segments {
        segment
            .files
            .insert("camera".into(), segment.files["screen"].clone());
    }
}
#[test]
fn smart_auto_framing_keeps_cursor_clear_across_aspects_and_source_edges() {
    let fixture = Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();
    synthetic_camera(&mut p);
    p.data.autosave = false;
    p.events[0] =
        vec![serde_json::from_value(json!({"type":"move","t":0,"x":310,"y":190})).unwrap()];
    p.input = p
        .events
        .iter()
        .map(|events| crate::input::InputCache::new(events))
        .collect();
    p.apply(&json!({"op":"add_zoom","tl_start_ns":0,"tl_end_ns":3_000_000_000_i64,"mode":"auto","scale":2,"target":[0.96875,0.95],"ease_in_ns":0,"ease_out_ns":0})).unwrap();
    let covered = |f: crate::frame::Frame| {
        f.cursor_x >= f.camera_dest.x
            && f.cursor_x <= f.camera_dest.x + f.camera_dest.w
            && f.cursor_y >= f.camera_dest.y
            && f.cursor_y <= f.camera_dest.y + f.camera_dest.h
    };
    let mut overlaps = 0;
    for aspect in ["16:9", "1:1", "9:16", "4:5"] {
        p.data.canvas.aspect = aspect.into();
        p.data.zoom_settings.smart_framing = false;
        let prior = p.frame(1_000_000_000).unwrap();
        if covered(prior) {
            overlaps += 1;
        }
        p.data.zoom_settings.smart_framing = true;
        let f = p.frame(1_000_000_000).unwrap();
        assert!(
            f.cursor_visible != 0 && !covered(f),
            "{aspect}: cursor {},{} camera {:?}",
            f.cursor_x,
            f.cursor_y,
            f.camera_dest
        );
        assert!(f.camera_dest.x >= 0.0 && f.camera_dest.y >= 0.0);
        assert!(f.camera_dest.x + f.camera_dest.w <= f.canvas_w as f64 + 1e-8);
        assert!(f.screen_crop.x >= 0.0 && f.screen_crop.x + f.screen_crop.w <= 1.0 + 1e-12);
        assert_eq!(
            p.frame(500_000_000).unwrap().cursor_x,
            p.frame(1_000_000_000).unwrap().cursor_x
        );
        assert_eq!(
            crate::allocation_test::count(|| {
                p.frame(1_000_000_000).unwrap();
                p.frame_motion(1_000_000_000).unwrap();
            }),
            0
        );
    }
    assert!(
        overlaps > 0,
        "Fixture must exercise camera occlusion before the policy"
    );
    p.data.zooms[0].mode = "manual".into();
    let manual = p.frame(1_000_000_000).unwrap();
    p.data.zoom_settings.smart_framing = false;
    assert_eq!(
        manual.camera_dest,
        p.frame(1_000_000_000).unwrap().camera_dest
    );
}
#[test]
fn aspect_adaptation_keeps_captions_and_shortcuts_readable_without_rewriting_data() {
    let fixture = Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();
    synthetic_camera(&mut p);
    p.data.canvas.captions = vec![TextRecord {
        id: "caption".into(),
        tl_end_ns: 3_000_000_000,
        text: "Caption".into(),
        style: crate::captions::factory_style(2),
        ..TextRecord::default()
    }];
    p.data.cursor.key_overlay.enabled = true;
    p.events[0].insert(
        0,
        serde_json::from_value(json!({"t":0,"type":"key","key":"k","modifiers":["cmd"]})).unwrap(),
    );
    p.key_overlay_index =
        crate::key_overlay::KeyOverlayIndex::new(&p.session, &p.events, &p.data.timeline.clips);
    for aspect in ["16:9", "1:1", "9:16", "4:5"] {
        p.data.canvas.aspect = aspect.into();
        let before = p.data.clone();
        let f = p.frame(500_000_000).unwrap();
        let layers = p.layers_at(500_000_000).unwrap();
        let text: Vec<_> = layers
            .as_array()
            .unwrap()
            .iter()
            .filter(|r| r["kind"] == "text")
            .collect();
        assert_eq!(text.len(), 2);
        for row in &text {
            let r: Vec<_> = row["rect"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v.as_f64().unwrap())
                .collect();
            assert!(
                r[0] >= 0.0
                    && r[1] >= 0.0
                    && r[0] + r[2] <= f.canvas_w as f64 + 1e-8
                    && r[1] + r[3] <= f.canvas_h as f64 + 1e-8
            );
            let c = f.camera_dest;
            assert!(
                !(r[0] < c.x + c.w && c.x < r[0] + r[2] && r[1] < c.y + c.h && c.y < r[1] + r[3]),
                "text overlaps camera: {row}"
            );
        }
        assert_eq!(text[0]["font_size"], f.canvas_h as f64 * 0.05);
        assert_eq!(text[1]["font_size"], f.canvas_h as f64 * 0.1);
        assert_eq!(
            p.data, before,
            "queries must never rewrite authored positions/targets"
        );
    }
}
#[test]
fn avoid_empty_zoom_area_fills_allocated_region_without_leaking_outside_crop() {
    let fixture = Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();
    p.data.canvas.aspect = "9:16".into();
    p.data.canvas.crop = [0.1, 0.1, 0.7, 0.7];
    p.apply(&json!({"op":"add_zoom","tl_start_ns":0,"tl_end_ns":3_000_000_000_i64,"mode":"manual","scale":2,"target":[0.4,0.4],"ease_in_ns":0,"ease_out_ns":0})).unwrap();
    let fitted = p.frame(1_000_000_000).unwrap();
    p.data.canvas.avoid_empty_zoom_area = true;
    let filled = p.frame(1_000_000_000).unwrap();
    assert!(filled.screen_dest.h > fitted.screen_dest.h);
    assert!(filled.screen_crop.x >= 0.1 && filled.screen_crop.y >= 0.1);
    assert!(
        filled.screen_crop.x + filled.screen_crop.w <= 0.8 + 1e-12
            && filled.screen_crop.y + filled.screen_crop.h <= 0.8 + 1e-12
    );
    assert!(
        (filled.screen_dest.w / filled.screen_dest.h
            - filled.screen_crop.w / filled.screen_crop.h * 1.6)
            .abs()
            < 1e-9
    );
}

#[test]
fn smart_camera_and_cursor_loop_do_not_reocclude_the_final_hotspot() {
    let fixture = Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();
    synthetic_camera(&mut p);
    for (i, events) in p.events.iter_mut().enumerate() {
        *events = vec![serde_json::from_value(
            json!({"type":"move","t":0,"x":if i==0 {40}else{280},"y":if i==0 {40}else{170}}),
        )
        .unwrap()];
        if i == 0 {
            events.push(
                serde_json::from_value(json!({"type":"move","t":1_000_000_000,"x":280,"y":170}))
                    .unwrap(),
            );
        }
    }
    p.input = p
        .events
        .iter()
        .map(|e| crate::input::InputCache::new(e))
        .collect();
    p.apply(&json!({"op":"add_zoom","tl_start_ns":0,"tl_end_ns":6_000_000_000_i64,"mode":"auto","scale":2,"target":[0.5,0.5],"ease_in_ns":0,"ease_out_ns":0})).unwrap();
    p.data.cursor.loop_to_start = true;
    let first = p.frame(0).unwrap();
    let last = p.frame(5_000_000_000).unwrap();
    let c = last.camera_dest;
    assert_eq!(
        (last.cursor_x, last.cursor_y),
        (first.cursor_x, first.cursor_y)
    );
    assert!(
        !(last.cursor_x >= c.x
            && last.cursor_x <= c.x + c.w
            && last.cursor_y >= c.y
            && last.cursor_y <= c.y + c.h)
    );
}

#[test]
fn moving_masks_follow_source_through_speed_cuts_and_restore_and_disabled_items_are_inert() {
    let fixture = Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();
    p.data.autosave = false;
    synthetic_camera(&mut p);
    p.apply(&json!({"op":"set","path":"canvas.highlights","value":[{
        "id":"moving","tl_start_ns":0,"tl_end_ns":5_000_000_000_i64,"space":"canvas",
        "rect":[0.1,0.1,0.2,0.2],"keyframes":[{"tl_ns":5_000_000_000_i64,"rect":[0.6,0.1,0.2,0.2]}]
    }]}))
    .unwrap();
    p.apply(&json!({"op":"split","at_tl_ns":1_000_000_000}))
        .unwrap();
    p.apply(&json!({"op":"set_speed","clip_id":p.data.timeline.clips[0].id,"speed":2}))
        .unwrap();
    for t in [250_000_000, 500_000_000, 750_000_000, 2_000_000_000] {
        let source = p.frame(t).unwrap().screen.src_ns;
        let rect = crate::layers::mask_rect_at(&p.data.canvas.highlights[0], t);
        assert!(
            (rect[0] - (0.1 + source as f64 / 1e10)).abs() < 1e-9,
            "{t} {source} {rect:?}"
        );
    }
    p.apply(
        &json!({"op":"delete_range","tl_start_ns":1_000_000_000,"tl_end_ns":2_000_000_000_i64}),
    )
    .unwrap();
    for t in [0, 999_999_999, 1_000_000_000, 2_000_000_000] {
        let source = p.frame(t).unwrap().screen.src_ns;
        assert!(
            (crate::layers::mask_rect_at(&p.data.canvas.highlights[0], t)[0]
                - (0.1 + source as f64 / 1e10))
                .abs()
                < 1e-9
        );
    }
    p.apply(&json!({"op":"delete_range","tl_start_ns":0,"tl_end_ns":500_000_000}))
        .unwrap();
    assert!((crate::layers::mask_rect_at(&p.data.canvas.highlights[0], 0)[0] - 0.2).abs() < 1e-9);
    p.apply(
        &json!({"op":"insert_source","src_start_ns":0,"src_end_ns":1_000_000_000,"at_tl_ns":0}),
    )
    .unwrap();
    assert!(
        (crate::layers::mask_rect_at(&p.data.canvas.highlights[0], 1_000_000_000)[0] - 0.2).abs()
            < 1e-9
    );
    p.apply(&json!({"op":"set","path":"camera.layouts","value":[{"id":"off","tl_start_ns":0,"tl_end_ns":4_000_000_000_i64,"mode":"screen","enabled":false}]})).unwrap();
    assert_eq!(p.frame(2_000_000_000).unwrap().camera.present, 1);
    let before = p.data.clone();
    let mut masks = serde_json::to_value(&p.data.canvas.highlights).unwrap();
    masks[0]["enabled"] = false.into();
    p.apply(&json!({"op":"set","path":"canvas.highlights","value":masks}))
        .unwrap();
    assert_eq!(p.frame_extras(2_000_000_000).unwrap().highlight_count, 0);
    assert_eq!(
        crate::allocation_test::count(|| {
            p.frame_extras(2_000_000_000).unwrap();
        }),
        0
    );
    p.undo().unwrap();
    assert_eq!(p.data, before);
    let mut invalid = serde_json::to_value(&p.data.canvas.highlights).unwrap();
    invalid[0]["keyframes"] = json!([{"tl_ns":-1,"rect":[0.0,0.0,0.2,0.2]}]);
    assert!(p
        .apply(&json!({"op":"set","path":"canvas.highlights","value":invalid}))
        .is_err());
    assert_eq!(p.data, before);
    p.save(&fixture.0).unwrap();
    assert_eq!(Project::open(&fixture.0).unwrap().data, before);
}

#[test]
fn source_speech_activity_maps_known_silence_through_edits_and_transcript_respects_vad() {
    let fixture = Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();
    p.data.autosave = false;
    synthetic_camera(&mut p);
    p.apply(&json!({"op":"batch","commands":[
        {"op":"set","path":"camera.hide_during_silence","value":true},
        {"op":"set","path":"camera.min_silence_ns","value":2_000_000_000_i64},
        {"op":"set","path":"camera.speech_activity","value":{"source":"vad","coverage_start_ns":0,"coverage_end_ns":5_000_000_000_i64,"ranges":[
            {"src_start_ns":4_000_000_000_i64,"src_end_ns":5_000_000_000_i64},
            {"src_start_ns":500_000_000,"src_end_ns":1_000_000_000},
            {"src_start_ns":0,"src_end_ns":800_000_000}]}}
    ]})).unwrap();
    assert_eq!(
        p.data.camera.speech_activity.as_ref().unwrap().ranges.len(),
        2
    );
    assert_eq!(p.data.camera.silence_ranges[0].tl_start_ns, 1_000_000_000);
    assert_eq!(p.frame(3_500_000_000).unwrap().camera.present, 0);
    assert_eq!(p.frame(4_900_000_000).unwrap().camera.present, 1);
    p.apply(&json!({"op":"split","at_tl_ns":2_000_000_000_i64}))
        .unwrap();
    p.apply(&json!({"op":"set_speed","clip_id":p.data.timeline.clips[0].id,"speed":2}))
        .unwrap();
    assert_eq!(p.data.camera.silence_ranges[0].tl_start_ns, 500_000_000);
    assert_eq!(p.data.camera.silence_ranges[0].tl_end_ns, 3_000_000_000_i64);
    let snapshot = p.clone();
    p.apply(&json!({"op":"delete_range","tl_start_ns":0,"tl_end_ns":500_000_000}))
        .unwrap();
    assert_eq!(p.data.camera.silence_ranges[0].tl_start_ns, 0);
    p.apply(
        &json!({"op":"insert_source","src_start_ns":0,"src_end_ns":1_000_000_000,"at_tl_ns":0}),
    )
    .unwrap();
    assert_eq!(p.data.camera.silence_ranges[0].tl_start_ns, 1_000_000_000);
    let vad = p.data.camera.speech_activity.clone();
    p.apply(&json!({"op":"import_transcript","transcript":{"schema_version":1,"words":[{"src_start_ns":0,"src_end_ns":5_000_000_000_i64,"text":"hello"}]}})).unwrap();
    assert_eq!(p.data.camera.speech_activity, vad);
    let before = p.data.clone();
    assert!(p.apply(&json!({"op":"set","path":"camera.speech_activity","value":{"source":"vad","coverage_start_ns":0,"coverage_end_ns":6_000_000_001_i64,"ranges":[]}})).is_err());
    assert_eq!(p.data, before);
    p.save(&fixture.0).unwrap();
    assert_eq!(Project::open(&fixture.0).unwrap().data, before);
    assert_eq!(
        snapshot.data.camera.silence_ranges[0].tl_start_ns,
        500_000_000
    );
    p.apply(&json!({"op":"set","path":"camera.silence_ranges","value":[]}))
        .unwrap();
    assert!(p.data.camera.speech_activity.is_none());
    p.apply(&json!({"op":"import_transcript","transcript":{"schema_version":1,"words":[{"src_start_ns":1_000_000_000,"src_end_ns":2_000_000_000_i64,"text":"speech"}]}})).unwrap();
    assert_eq!(
        p.data.camera.speech_activity.as_ref().unwrap().source,
        "transcript"
    );
    p.apply(&json!({"op":"set","path":"camera.speech_activity","value":null}))
        .unwrap();
    assert!(p.data.camera.silence_ranges.is_empty());
}

#[test]
fn edited_zoom_magnification_remembers_default_in_same_undo_without_item_metadata() {
    let fixture = Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();
    p.data.autosave = false;
    let result = p
        .apply(&json!({"op":"add_zoom","tl_start_ns":0,"tl_end_ns":1_000_000_000,"scale":2,"mode":"manual","target":[0.5,0.5],"ease_in_ns":0,"ease_out_ns":0}))
        .unwrap();
    let id = &result.created_ids[0];
    let before = p.data.clone();
    p.apply(&json!({"op":"update_zoom","id":id,"patch":{"scale":3.2}}))
        .unwrap();
    assert_eq!(p.data.zoom_settings.default_scale, 3.2);
    p.undo().unwrap();
    assert_eq!(p.data, before);
    p.redo().unwrap();
    p.apply(
        &json!({"op":"add_zoom","tl_start_ns":2_000_000_000_i64,"tl_end_ns":3_000_000_000_i64,"mode":"manual","target":[0.5,0.5],"ease_in_ns":0,"ease_out_ns":0}),
    )
    .unwrap();
    assert_eq!(p.data.zooms[1].scale, 3.2);
    p.save(&fixture.0).unwrap();
    assert_eq!(Project::open(&fixture.0).unwrap().data, p.data);
}

#[test]
fn new_caption_without_style_uses_factory_and_legacy_project_keeps_legacy_style() {
    let fixture = Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();
    p.data.autosave = false;
    p.apply(&json!({"op":"add_caption","record":{"text":"new","tl_start_ns":0,"tl_end_ns":1_000_000_000}})).unwrap();
    assert_eq!(
        p.data.canvas.captions[0].style,
        crate::captions::factory_style(2)
    );
    p.data.defaults_revision = 1;
    p.apply(&json!({"op":"add_caption","record":{"text":"legacy","tl_start_ns":1_000_000_000,"tl_end_ns":2_000_000_000_i64}})).unwrap();
    assert_eq!(p.data.canvas.captions[1].style, TextStyle::default());
}

#[test]
fn split_direction_forces_axis_across_aspects_and_legacy_auto_is_preserved() {
    let fixture = Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();
    p.data.autosave = false;
    synthetic_camera(&mut p);
    for direction in ["auto", "horizontal", "vertical"] {
        p.apply(&json!({"op":"batch","commands":[
            {"op":"set","path":"camera.layout_settings.mode","value":"split"},
            {"op":"set","path":"camera.layout_settings.split_direction","value":direction}]}))
            .unwrap();
        for aspect in ["16:9", "9:16"] {
            p.apply(&json!({"op":"set","path":"canvas.aspect","value":aspect}))
                .unwrap();
            let f = p.frame(0).unwrap();
            let horizontal = direction == "horizontal" || direction == "auto" && aspect == "16:9";
            if horizontal {
                assert!(f.screen_dest.x + f.screen_dest.w <= f.camera_dest.x + 1e-8);
            } else {
                assert!(f.screen_dest.y + f.screen_dest.h <= f.camera_dest.y + 1e-8);
            }
            assert_eq!(
                crate::allocation_test::count(|| {
                    p.frame(0).unwrap();
                }),
                0
            );
        }
    }
    let before = p.data.clone();
    assert!(p
        .apply(
            &json!({"op":"set","path":"camera.layout_settings.split_direction","value":"diagonal"})
        )
        .is_err());
    assert_eq!(p.data, before);
    p.apply(&json!({"op":"set","path":"camera.layouts","value":[{"id":"axis","tl_start_ns":0,"tl_end_ns":1_000_000_000,"mode":"split","settings":{"split_direction":"horizontal","split_flip":true}}]})).unwrap();
    let f = p.frame(0).unwrap();
    assert!(f.camera_dest.x + f.camera_dest.w <= f.screen_dest.x + 1e-8);
    let snapshot = p.clone();
    p.undo().unwrap();
    assert_ne!(
        p.frame(0).unwrap().camera_dest,
        snapshot.frame(0).unwrap().camera_dest
    );
    p.redo().unwrap();
    p.save(&fixture.0).unwrap();
    assert_eq!(Project::open(&fixture.0).unwrap().data, p.data);
    let mut legacy = serde_json::to_value(&p.data).unwrap();
    legacy["camera"]["layout_settings"]
        .as_object_mut()
        .unwrap()
        .remove("split_direction");
    assert_eq!(
        crate::project::decode_project(&serde_json::to_vec(&legacy).unwrap())
            .unwrap()
            .camera
            .layout_settings
            .split_direction,
        "auto"
    );
    // Cutout supports the recorded ratio explicitly; the UI must choose null
    // when selecting its separate defaults instead of reusing overlay's square.
    p.apply(&json!({"op":"batch","commands":[{"op":"set","path":"camera.layouts","value":[]},{"op":"set","path":"camera.layout_settings.mode","value":"cutout"},{"op":"set","path":"camera.layout_settings.aspect","value":null}]})).unwrap();
    let f = p.frame(0).unwrap();
    assert!((f.camera_dest.w / f.camera_dest.h - 1.6).abs() < 1e-9);
}

#[test]
fn adaptive_text_keeps_shortcuts_clear_of_caption_and_camera_at_multiple_positions() {
    let fixture = Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();
    synthetic_camera(&mut p);
    let overlap = |a: crate::frame::Rect, b: crate::frame::Rect| {
        a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
    };
    for aspect in ["16:9", "1:1", "9:16", "4:5"] {
        p.data.canvas.aspect = aspect.into();
        for position in [
            [0.0, 0.0],
            [0.5, 0.0],
            [1.0, 0.0],
            [0.0, 0.5],
            [0.5, 0.5],
            [1.0, 0.5],
            [0.0, 1.0],
            [0.5, 1.0],
            [1.0, 1.0],
        ] {
            p.data.camera.position = position;
            let caption = TextRecord {
                id: "test".into(),
                text: "Caption".into(),
                tl_end_ns: 1_000_000_000,
                ..Default::default()
            };
            p.data.canvas.captions = vec![caption.clone()];
            let f = p.frame(0).unwrap();
            let rect = |r: [f64; 4]| crate::frame::Rect {
                x: r[0] * f.canvas_w as f64,
                y: r[1] * f.canvas_h as f64,
                w: r[2] * f.canvas_w as f64,
                h: r[3] * f.canvas_h as f64,
            };
            let caption = crate::adaptive::text_rect(&p.data, rect(caption.rect), &f, false);
            let key =
                crate::adaptive::text_rect(&p.data, rect(p.data.cursor.key_overlay.rect), &f, true);
            assert!(
                !overlap(key, f.camera_dest),
                "{aspect} {position:?}: key {key:?}, camera {:?}",
                f.camera_dest
            );
            assert!(
                !overlap(key, caption),
                "{aspect} {position:?}: key {key:?}, caption {caption:?}"
            );
        }
    }
}

#[test]
fn wave_three_defaults_presets_masks_and_layout_modes_match_the_reference_contract() {
    let fixture = Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();

    // E4.1/E4.3: Wave 3 chose Render's own dark Deep Slate wallpaper. Its
    // analytic gradient remains renderable by old frame consumers, while the
    // stable identity and catalog index restore the Wallpaper selection.
    assert_eq!(p.data.defaults_revision, 4);
    assert_eq!(p.data.canvas.background.kind, "gradient");
    assert_eq!(
        p.data.canvas.background.wallpaper_id.as_deref(),
        Some(FACTORY_WALLPAPER_ID)
    );
    assert_eq!(
        p.data.canvas.background.wallpaper_index,
        Some(FACTORY_WALLPAPER_INDEX)
    );
    assert_eq!(
        p.data.canvas.background.color,
        [
            0x18 as f32 / 255.0,
            0x2b as f32 / 255.0,
            0x42 as f32 / 255.0,
            1.0
        ]
    );
    assert_eq!(p.data.canvas.background.angle_deg, 115.0);
    assert_eq!(p.frame(0).unwrap().background_kind, 1);
    let options = p.query(&json!({"q":"render_options"})).unwrap();
    assert_eq!(options["background_wallpaper_id"], FACTORY_WALLPAPER_ID);
    assert_eq!(
        options["background_wallpaper_index"],
        FACTORY_WALLPAPER_INDEX
    );
    let background = p.data.canvas.background.clone();
    p.apply(&json!({"op":"set","path":"canvas.background.color","value":[0.1,0.2,0.3,1]}))
        .unwrap();
    assert_eq!(p.data.canvas.background.wallpaper_id, None);
    assert_eq!(p.data.canvas.background.wallpaper_index, None);
    p.undo().unwrap();
    assert_eq!(p.data.canvas.background, background);

    // E8.2 and E13.3 are factory-aware so legacy decoding stays unchanged.
    let captions = p.query(&json!({"q":"caption_defaults"})).unwrap();
    assert_eq!(captions["font_size_ratio"], 0.05);
    assert_eq!(captions["growth"], "expanding");
    p.apply(&json!({"op":"insert_mask","patch":{"kind":"highlight"}}))
        .unwrap();
    assert_eq!(p.data.canvas.highlights[0].kind, "highlight");
    assert_eq!(p.data.canvas.highlights[0].dim_opacity, 0.5);

    // E11.1: §2a.11's model default is a custom spring, not either preset.
    assert_eq!(
        (
            p.data.zoom_settings.spring.tension,
            p.data.zoom_settings.spring.friction,
            p.data.zoom_settings.spring.mass
        ),
        (70.0, 30.0, 3.0)
    );
    let mut settings = p.data.zoom_settings.clone();
    settings.animation_style = "focused".into();
    let focused = crate::motion::zoom_spring(&settings);
    assert_eq!(
        (focused.tension, focused.friction, focused.mass),
        (250.0, 40.0, 2.25)
    );
    settings.animation_style = "smooth".into();
    let smooth = crate::motion::zoom_spring(&settings);
    assert_eq!(
        (smooth.tension, smooth.friction, smooth.mass),
        (170.0, 50.0, 3.0)
    );

    // E6.6: disabled ranges fall through, "camera" is fullscreen-camera and
    // "screen" is screen-only/hide-camera in the compact persisted vocabulary.
    synthetic_camera(&mut p);
    p.apply(&json!({"op":"set","path":"camera.layouts","value":[
        {"id":"disabled","enabled":false,"tl_start_ns":0,"tl_end_ns":1_000_000_000_i64,"mode":"camera"},
        {"id":"full","tl_start_ns":1_000_000_000_i64,"tl_end_ns":2_000_000_000_i64,"mode":"camera"},
        {"id":"screen-only","tl_start_ns":2_000_000_000_i64,"tl_end_ns":3_000_000_000_i64,"mode":"screen"}
    ]}))
    .unwrap();
    let disabled = p.frame(500_000_000).unwrap();
    assert_eq!((disabled.screen.present, disabled.camera.present), (1, 1));
    let full = p.frame(1_500_000_000).unwrap();
    assert_eq!((full.screen.present, full.camera.present), (0, 1));
    let screen_only = p.frame(2_500_000_000).unwrap();
    assert_eq!(
        (screen_only.screen.present, screen_only.camera.present),
        (1, 0)
    );

    p.save(&fixture.0).unwrap();
    let reopened = Project::open(&fixture.0).unwrap();
    assert_eq!(reopened.data, p.data);
    assert_eq!(
        reopened.query(&json!({"q":"render_options"})).unwrap()["background_wallpaper_id"],
        FACTORY_WALLPAPER_ID
    );

    // Previously saved revision-2 projects are values, not migration targets.
    let mut old = p.data.clone();
    old.defaults_revision = 2;
    old.canvas.background = Background::default();
    let old = crate::project::decode_project(&serde_json::to_vec(&old).unwrap()).unwrap();
    assert_eq!(old.defaults_revision, 2);
    assert_eq!(old.canvas.background.kind, "solid");
    assert_eq!(old.canvas.background.wallpaper_id, None);
    assert_eq!(old.canvas.background.color, [0.12, 0.14, 0.18, 1.0]);
}
