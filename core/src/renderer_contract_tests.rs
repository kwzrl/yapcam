//! Cross-team renderer contracts use real Project queries and persistence.
use crate::project::{tests::Fixture, Project};
use serde_json::{json, Value};

#[test]
fn mkt019_circle_and_ripple_have_distinct_render_contracts() {
    let fixture = Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();
    p.data.autosave = false;
    let q = json!({"q":"render_options_at","tl_ns":1_800_000_000_i64});

    p.apply(&json!({"op":"set","path":"cursor.click_effect","value":"ring"}))
        .unwrap();
    let circle = p.query(&q).unwrap();
    let circle_frame = p.frame(1_800_000_000).unwrap();
    let circle_after_lifetime = p.frame(2_150_000_000).unwrap();
    assert_eq!(circle["cursor_click_effect"], "ring");
    assert_eq!(circle["cursor_click_duration_ns"], 400_000_000_i64);
    assert!((circle_frame.click_progress - 0.25).abs() < 1e-6);
    assert_eq!(circle_after_lifetime.click_progress, -1.0);

    p.apply(&json!({"op":"set","path":"cursor.click_effect","value":"highlight"}))
        .unwrap();
    let ripple = p.query(&q).unwrap();
    let ripple_frame = p.frame(1_800_000_000).unwrap();
    let ripple_last_ring = p.frame(2_150_000_000).unwrap();
    assert_eq!(ripple["cursor_click_effect"], "highlight");
    assert_eq!(ripple["cursor_click_duration_ns"], 450_000_000_i64);
    assert_ne!(circle["cursor_click_effect"], ripple["cursor_click_effect"]);
    assert!((ripple_frame.click_progress - (100.0 / 590.0)).abs() < 1e-6);
    assert!((ripple_last_ring.click_progress - (450.0 / 590.0)).abs() < 1e-6);
}

#[test]
fn mkt019_revision_four_uses_450ms_rings_while_legacy_keeps_400ms_circle() {
    let fixture = Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();
    p.data.autosave = false;
    p.data.cursor.click_effect = "highlight".into();
    assert_eq!(p.data.defaults_revision, 4);
    assert_eq!(p.data.cursor.click_duration_ns, 400_000_000);
    assert_eq!(
        p.query(&json!({"q":"render_options_at","tl_ns":1_800_000_000_i64}))
            .unwrap()["cursor_click_effect"],
        "highlight"
    );
    assert!(p.frame(2_250_000_000).unwrap().click_progress >= 0.0);

    p.data.defaults_revision = 3;
    p.data.cursor.click_duration_ns = 400_000_000;
    let legacy = p
        .query(&json!({"q":"render_options_at","tl_ns":1_800_000_000_i64}))
        .unwrap();
    assert_eq!(legacy["cursor_click_effect"], "ring");
    assert_eq!(legacy["cursor_click_duration_ns"], 400_000_000_i64);
    assert_eq!(p.frame(2_150_000_000).unwrap().click_progress, -1.0);
}
#[test]
fn explicit_cursor_replacement_flags_follow_edits_presets_and_old_documents() {
    let fixture = Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();
    p.data.autosave = false;
    let q = json!({"q":"render_options_at","tl_ns":500_000_000});
    let a = p.query(&q).unwrap();
    assert_eq!(a["cursor_use_default_if_app_has_low_resolution"], true);
    assert_eq!(a["cursor_always_use_default"], false);
    let before = p.clone();
    p.apply(&json!({"op":"batch","commands":[
        {"op":"set","path":"cursor.use_default_if_app_has_low_resolution","value":false},
        {"op":"set","path":"cursor.always_default","value":true}]}))
        .unwrap();
    let b = p.query(&q).unwrap();
    assert_eq!(b["cursor_use_default_if_app_has_low_resolution"], false);
    assert_eq!(b["cursor_always_use_default"], true);
    assert_eq!(b["cursor_shape"], "arrow");
    assert_eq!(before.query(&q).unwrap(), a);
    p.undo().unwrap();
    assert_eq!(p.query(&q).unwrap(), a);
    p.redo().unwrap();
    let preset = p.query(&json!({"q":"preset"})).unwrap();
    assert_eq!(
        preset["cursor"]["use_default_if_app_has_low_resolution"],
        false
    );
    let next_fixture = Fixture::new();
    let mut next = Project::create(&next_fixture.0).unwrap();
    next.data.autosave = false;
    next.apply(&json!({"op":"apply_preset","preset":preset}))
        .unwrap();
    assert_eq!(next.query(&q).unwrap()["cursor_always_use_default"], true);
    let data = p.data.clone();
    assert!(p
        .apply(&json!({"op":"set","path":"cursor.use_default_if_app_has_low_resolution","value":1}))
        .is_err());
    assert_eq!(p.data, data);
    p.save(&fixture.0).unwrap();
    assert_eq!(Project::open(&fixture.0).unwrap().query(&q).unwrap(), b);
    let mut old = serde_json::to_value(&p.data).unwrap();
    old["cursor"]
        .as_object_mut()
        .unwrap()
        .remove("use_default_if_app_has_low_resolution");
    let decoded = crate::project::decode_project(&serde_json::to_vec(&old).unwrap()).unwrap();
    assert!(decoded.cursor.use_default_if_app_has_low_resolution);
    assert!(decoded.cursor.always_default);
    assert_eq!(
        crate::allocation_test::count(|| {
            p.frame(500_000_000).unwrap();
            p.frame_extras(500_000_000).unwrap();
        }),
        0
    );
}

#[test]
fn generated_purpose_comes_from_collections_even_when_ids_are_spoofed() {
    let fixture = Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();
    p.data.autosave = false;
    p.apply(&json!({"op":"batch","commands":[
        {"op":"set","path":"canvas.highlights","value":[{"id":"core:caption:fake:background","tl_start_ns":0,"tl_end_ns":2_000_000_000_i64,"space":"canvas","fill":[0,0,0,1]}]},
        {"op":"add_caption","record":{"id":"caption","text":"words","tl_start_ns":0,"tl_end_ns":2_000_000_000_i64}},
        {"op":"add_annotation","record":{"id":"note","text":"note","tl_start_ns":0,"tl_end_ns":2_000_000_000_i64}},
        {"op":"add_reaction","record":{"id":"reaction","text":"!","tl_start_ns":0,"tl_end_ns":2_000_000_000_i64}},
        {"op":"set","path":"cursor.key_overlay.enabled","value":true},
        {"op":"add_zoom","zoom":{"tl_start_ns":0,"tl_end_ns":2_000_000_000_i64,"style":"lens","mode":"manual","target":[0.5,0.5],"scale":2,"ease_in_ns":0,"ease_out_ns":0}}
    ]})).unwrap();
    p.events[0].insert(
        0,
        serde_json::from_value(json!({"t":0,"type":"key","key":"k","modifiers":["cmd"]})).unwrap(),
    );
    p.rebuild_key_overlay_index();
    let rows = p.layers_at(500_000_000).unwrap();
    let rows = rows.as_array().unwrap();
    assert_eq!(rows[0]["id"], "core:caption:fake:background");
    assert_eq!(rows[0]["purpose"], "privacy_mask");
    assert_eq!(
        rows.iter()
            .filter(|r| r["purpose"] == "text_background")
            .count(),
        4
    );
    for row in rows.iter().filter(|r| r["purpose"] == "text_background") {
        assert_eq!(row["kind"], "highlight");
        assert_eq!(row["dim_opacity"], 0.0);
    }
    assert!(rows
        .iter()
        .filter(|r| r["kind"] == "text")
        .all(|r| r["purpose"] == "unspecified"));
    let before = p.data.clone();
    let mut forged = serde_json::to_value(&p.data.canvas.highlights).unwrap();
    forged[0]["purpose"] = "text_background".into();
    assert!(p
        .apply(&json!({"op":"set","path":"canvas.highlights","value":forged}))
        .is_err());
    assert_eq!(p.data, before);
    assert!(p.apply(&json!({"op":"add_annotation","record":{"text":"fake","tl_start_ns":0,"tl_end_ns":1,"purpose":"privacy_mask"}})).is_err());
    assert_eq!(p.data, before);
    assert!(!p
        .query(&json!({"q":"zoom_lens_at","tl_ns":500_000_000}))
        .unwrap()
        .is_null());
    let packet = p.privacy_masks_at(500_000_000).unwrap();
    assert_eq!(packet["masks"].as_array().unwrap().len(), 1);
    assert_eq!(packet["masks"][0]["purpose"], "privacy_mask");
}

#[test]
fn lens_queries_distinguish_highlights_and_spotlights_from_sensitive_masks() {
    let fixture = Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();
    p.data.autosave = false;
    p.apply(&json!({"op":"batch","commands":[
        {"op":"set","path":"canvas.highlights","value":[
            {"id":"spotlight","tl_start_ns":0,"tl_end_ns":2_000_000_000_i64},
            {"id":"outline","tl_start_ns":0,"tl_end_ns":2_000_000_000_i64,"dim_opacity":0},
            {"id":"translucent","tl_start_ns":0,"tl_end_ns":2_000_000_000_i64,"dim_opacity":0,"fill":[0,0,0,1],"opacity":0.5},
            {"id":"cover","tl_start_ns":0,"tl_end_ns":2_000_000_000_i64,"fill":[0,0,0,1]},
            {"id":"blur","kind":"blur","tl_start_ns":0,"tl_end_ns":2_000_000_000_i64}]},
        {"op":"add_zoom","zoom":{"tl_start_ns":0,"tl_end_ns":2_000_000_000_i64,"style":"lens","mode":"manual","target":[0.5,0.5],"scale":2,"ease_in_ns":0,"ease_out_ns":0}}
    ]})).unwrap();

    assert!(!p
        .query(&json!({"q":"zoom_lens_at","tl_ns":500_000_000}))
        .unwrap()
        .is_null());
    let rows = p.layers_at(500_000_000).unwrap();
    let rows = rows.as_array().unwrap();
    let purpose = |id: &str| {
        rows.iter().find(|row| row["id"] == id).unwrap()["purpose"]
            .as_str()
            .unwrap()
    };
    assert_eq!(purpose("spotlight"), "spotlight");
    assert_eq!(purpose("outline"), "highlight");
    assert_eq!(purpose("translucent"), "highlight");
    assert_eq!(purpose("cover"), "privacy_mask");
    assert_eq!(purpose("blur"), "privacy_mask");

    let packet = p.privacy_masks_at(500_000_000).unwrap();
    assert_eq!(
        packet["masks"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| (row["id"].as_str().unwrap(), row["order"].as_u64().unwrap()))
            .collect::<Vec<_>>(),
        vec![("cover", 3), ("blur", 4)]
    );
}

#[test]
fn original_space_mask_packet_preserves_order_styles_bounds_and_edited_source_clock() {
    let fixture = Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();
    p.data.autosave = false;
    p.apply(&json!({"op":"batch","commands":[
        {"op":"set","path":"canvas.crop","value":[0.1,0.1,0.5,0.5]},
        {"op":"set","path":"canvas.highlights","value":[
            {"id":"disabled","enabled":false,"tl_start_ns":0,"tl_end_ns":5_000_000_000_i64},
            {"id":"moving","kind":"blur","space":"source","tl_start_ns":0,"tl_end_ns":5_000_000_000_i64,"rect":[0.2,0.2,0.2,0.2],"keyframes":[{"tl_ns":3_000_000_000_i64,"rect":[0.5,0.4,0.2,0.2]}],"blur_radius":17,"radius":8,"opacity":0.6,"dim_opacity":0.2,"stroke_width":2.5},
            {"id":"canvas","space":"canvas","tl_start_ns":0,"tl_end_ns":5_000_000_000_i64,"rect":[0.1,0.1,0.8,0.8],"fill":[0,0,0,1]},
            {"id":"offscreen","kind":"blur","space":"source","tl_start_ns":0,"tl_end_ns":5_000_000_000_i64,"rect":[0.8,0.8,0.1,0.1]}]},
        {"op":"add_zoom","zoom":{"tl_start_ns":0,"tl_end_ns":5_000_000_000_i64,"mode":"manual","style":"lens","target":[0.4,0.4],"scale":2,"ease_in_ns":0,"ease_out_ns":0}}
    ]})).unwrap();
    for edited in [false, true] {
        if edited {
            p.apply(&json!({"op":"split","at_tl_ns":2_000_000_000_i64}))
                .unwrap();
            p.apply(&json!({"op":"set_speed","clip_id":p.data.timeline.clips[0].id,"speed":2}))
                .unwrap();
        }
        let before = p.data.clone();
        let t = 1_500_000_000;
        let f = p.frame(t).unwrap();
        let q = p.query(&json!({"q":"privacy_masks_at","tl_ns":t})).unwrap();
        assert_eq!(q["schema_version"], 1);
        assert_eq!(q["tl_ns"], t);
        assert_eq!(q["screen"]["src_ns"], f.screen.src_ns);
        assert_eq!(q["screen"]["file_ns"], f.screen.file_ns);
        assert_eq!(q["screen"]["segment"], f.screen.segment);
        assert_eq!(
            q["screen"]["pixel_size"],
            json!(p.session.tracks.screen.pixel_size)
        );
        let rows = q["masks"].as_array().unwrap();
        assert_eq!(rows.len(), 3);
        assert_eq!(
            rows.iter()
                .map(|r| r["order"].as_u64().unwrap())
                .collect::<Vec<_>>(),
            vec![1, 2, 3]
        );
        let h = &rows[0];
        let source = f.screen.src_ns as f64 / 3_000_000_000.0;
        assert!((h["rect"][0].as_f64().unwrap() - (0.2 + 0.3 * source)).abs() < 1e-9);
        assert_eq!(h["blur_radius"], 17.0);
        assert_eq!(h["corner_radius"], 8.0);
        assert_eq!(h["opacity"], 0.6);
        assert_eq!(h["dim_opacity"], 0.2);
        assert_eq!(h["stroke_width"], 2.5);
        assert_eq!(rows[1]["space"], "canvas");
        assert!(rows[1]["blur_radius"].is_null());
        assert_eq!(rows[2]["rect"], json!([0.8, 0.8, 0.1, 0.1]));
        assert!(p
            .layers_at(t)
            .unwrap()
            .as_array()
            .unwrap()
            .iter()
            .all(|r| r["id"] != "offscreen"));
        let scales = &q["screen"]["source_pixels_per_canvas_pixel"];
        assert!(
            (scales[0].as_f64().unwrap() - f.screen_crop.w * 320.0 / f.screen_dest.w).abs() < 1e-12
        );
        assert_eq!(p.effects_at(t).unwrap()["privacy_masks"], q);
        assert_eq!(p.data, before);
        assert_eq!(
            crate::allocation_test::count(|| {
                p.frame(t).unwrap();
                p.frame_extras(t).unwrap();
            }),
            0
        );
        let end = crate::time::duration(&p.data.timeline.clips);
        assert!(p.privacy_masks_at(end).unwrap()["masks"]
            .as_array()
            .unwrap()
            .is_empty());
    }
    let snapshot = p.clone();
    p.apply(&json!({"op":"delete_range","tl_start_ns":0,"tl_end_ns":500_000_000}))
        .unwrap();
    let after = p.privacy_masks_at(1_000_000_000).unwrap();
    assert_eq!(
        snapshot.privacy_masks_at(1_500_000_000).unwrap()["masks"][0]["rect"],
        after["masks"][0]["rect"]
    );
    p.undo().unwrap();
    assert_eq!(
        p.privacy_masks_at(1_500_000_000).unwrap(),
        snapshot.privacy_masks_at(1_500_000_000).unwrap()
    );
    p.redo().unwrap();
    p.save(&fixture.0).unwrap();
    assert_eq!(
        Project::open(&fixture.0)
            .unwrap()
            .privacy_masks_at(1_000_000_000)
            .unwrap(),
        after
    );
    for time in [Value::Null, json!(0.5), json!(-1), json!(i64::MAX)] {
        assert!(p
            .query(&json!({"q":"privacy_masks_at","tl_ns":time}))
            .is_err());
    }
}

#[test]
fn two_stop_gradient_updates_are_atomic_and_reach_frames_with_one_undo_step() {
    let fixture = Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();
    p.data.autosave = false;
    let before = p.data.clone();
    p.apply(&json!({"op":"batch","commands":[
        {"op":"set","path":"canvas.background.kind","value":"gradient"},
        {"op":"set","path":"canvas.background.color","value":[0.0,1.0,0.0,1.0]},
        {"op":"set","path":"canvas.background.color2","value":[0.0,0.0,1.0,0.8]}]}))
        .unwrap();
    let f = p.frame(0).unwrap();
    assert_eq!(f.background_color, [0.0, 1.0, 0.0, 1.0]);
    assert_eq!(f.background_color2, [0.0, 0.0, 1.0, 0.8]);
    let both = p.data.clone();
    assert!(p
        .apply(&json!({"op":"batch","commands":[
        {"op":"set","path":"canvas.background.color","value":[1,0,0,1]},
        {"op":"set","path":"canvas.background.color2","value":[0,0,2,1]}]}))
        .is_err());
    assert_eq!(p.data, both);
    p.undo().unwrap();
    assert_eq!(p.data, before);
    p.redo().unwrap();
    assert_eq!(p.data, both);
    p.save(&fixture.0).unwrap();
    let reopened = Project::open(&fixture.0).unwrap();
    assert_eq!(
        reopened.frame(0).unwrap().background_color2,
        f.background_color2
    );
}

#[test]
fn new_sensitive_mask_default_keeps_explicit_inherited_and_legacy_highlight_styles() {
    let fixture = Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();
    p.data.autosave = false;
    p.apply(&json!({"op":"insert_mask"})).unwrap();
    assert_eq!(p.data.canvas.highlights[0].kind, "blur");
    assert_eq!(p.data.canvas.highlights[0].blur_radius, 32.0);
    p.apply(&json!({"op":"insert_mask","patch":{"kind":"highlight","dim_opacity":0.7}}))
        .unwrap();
    p.apply(&json!({"op":"insert_mask"})).unwrap();
    assert_eq!(p.data.canvas.highlights[2].kind, "highlight");
    assert_eq!(p.data.canvas.highlights[2].dim_opacity, 0.7);
    let mut old = p.data.clone();
    old.defaults_revision = 1;
    old.insertion_styles.mask = None;
    p.data = old;
    p.apply(&json!({"op":"insert_mask"})).unwrap();
    assert_eq!(p.data.canvas.highlights[3].kind, "highlight");
    assert_eq!(p.data.canvas.highlights[3].dim_opacity, 0.4);
    let decoded: crate::model::Highlight =
        serde_json::from_value(json!({"id":"legacy","tl_start_ns":0,"tl_end_ns":1})).unwrap();
    assert_eq!(decoded.kind, "highlight");
}
