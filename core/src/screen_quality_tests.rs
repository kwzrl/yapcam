use crate::{
    model::ProjectData,
    project::{tests::Fixture, Project},
};
use serde_json::json;

#[test]
fn screen_quality_is_opt_in_and_keeps_frames_history_and_legacy_appearance() {
    let f = Fixture::new();
    let mut p = Project::create(&f.0).unwrap();
    let q = json!({"q":"render_options_at","tl_ns":500_000_000});
    assert!(p.query(&q).unwrap()["screen_quality"].is_null());
    let frame = p.frame(500_000_000).unwrap();
    let snapshot = p.clone();
    p.apply(&json!({"op":"set","path":"canvas.screen_quality","value":{}}))
        .unwrap();
    let default = json!({"improve_quality":0.5,"upscaling":"quality"});
    assert_eq!(p.query(&q).unwrap()["screen_quality"], default);
    let evaluated = p.frame(500_000_000).unwrap();
    assert_eq!(evaluated.screen_crop, frame.screen_crop);
    assert_eq!(evaluated.screen_dest, frame.screen_dest);
    assert_eq!(evaluated.screen.src_ns, frame.screen.src_ns);
    assert!(snapshot.query(&q).unwrap()["screen_quality"].is_null());
    p.apply(&json!({"op":"batch","commands":[{"op":"set","path":"canvas.screen_quality.improve_quality","value":0.75},{"op":"set","path":"canvas.screen_quality.upscaling","value":"fast"}]})).unwrap();
    let selected = json!({"improve_quality":0.75,"upscaling":"fast"});
    assert_eq!(p.query(&q).unwrap()["screen_quality"], selected);
    assert_eq!(
        p.query(&json!({"q":"render_options"})).unwrap()["screen_quality"],
        selected
    );
    assert_eq!(
        p.query(&json!({"q":"effects_at","tl_ns":500_000_000}))
            .unwrap()["render_options"]["screen_quality"],
        selected
    );
    p.undo().unwrap();
    assert_eq!(p.query(&q).unwrap()["screen_quality"], default);
    p.redo().unwrap();
    p.save(&f.0).unwrap();
    assert_eq!(
        Project::open(&f.0).unwrap().query(&q).unwrap()["screen_quality"],
        selected
    );
    let mut legacy = serde_json::to_value(&p.data).unwrap();
    legacy["canvas"]
        .as_object_mut()
        .unwrap()
        .remove("screen_quality");
    let decoded: ProjectData =
        crate::project::decode_project(&serde_json::to_vec(&legacy).unwrap()).unwrap();
    assert!(decoded.canvas.screen_quality.is_none());
    p.apply(&json!({"op":"set","path":"canvas.screen_quality","value":null}))
        .unwrap();
    assert!(p.query(&q).unwrap()["screen_quality"].is_null());
    assert_eq!(p.frame(500_000_000).unwrap().screen_dest, frame.screen_dest);
}

#[test]
fn screen_quality_presets_filter_partial_objects_and_invalid_edits_are_atomic() {
    let f = Fixture::new();
    let mut p = Project::create(&f.0).unwrap();
    p.apply(&json!({"op":"set","path":"canvas.screen_quality","value":{}}))
        .unwrap();
    for invalid in [
        json!(-1),
        json!([]),
        json!({"improve_quality":-0.1}),
        json!({"improve_quality":1.1}),
        json!({"upscaling":"unknown"}),
        json!({"foreign_id":"clip"}),
    ] {
        let before = p.data.clone();
        let undo = p.undo.len();
        assert!(p.apply(&json!({"op":"batch","commands":[{"op":"set","path":"notes","value":"rollback"},{"op":"set","path":"canvas.screen_quality","value":invalid}]})).is_err());
        assert_eq!(p.data, before);
        assert_eq!(p.undo.len(), undo);
    }
    // Optional object shapes must filter unknown descendants before recursively
    // merging; arbitrary input must never unwrap a missing target child.
    p.apply(&json!({"op":"apply_preset","preset":{"canvas":{"screen_quality":{"foreign_id":"clip","improve_quality":0.25}}}})).unwrap();
    assert_eq!(
        p.data
            .canvas
            .screen_quality
            .as_ref()
            .unwrap()
            .improve_quality,
        0.25
    );
    assert_eq!(
        p.data.canvas.screen_quality.as_ref().unwrap().upscaling,
        "quality"
    );
    let preset = p.query(&json!({"q":"preset"})).unwrap();
    assert_eq!(
        preset["canvas"]["screen_quality"],
        json!({"improve_quality":0.25,"upscaling":"quality"})
    );
    p.apply(&json!({"op":"set","path":"canvas.screen_quality","value":null}))
        .unwrap();
    p.apply(&json!({"op":"apply_preset","preset":preset}))
        .unwrap();
    assert_eq!(
        p.data
            .canvas
            .screen_quality
            .as_ref()
            .unwrap()
            .improve_quality,
        0.25
    );
    p.apply(&json!({"op":"apply_preset","preset":{"canvas":{"screen_quality":null}}}))
        .unwrap();
    assert!(p.data.canvas.screen_quality.is_none());
    let before = p.data.clone();
    assert!(p
        .apply(&json!({"op":"set","path":"canvas.screen_quality.upscaling","value":"off"}))
        .is_err());
    assert_eq!(p.data, before);
    for mode in ["off", "fast", "quality"] {
        p.apply(&json!({"op":"set","path":"canvas.screen_quality","value":{"improve_quality":0,"upscaling":mode}})).unwrap();
    }
    assert!(
        p.query(&json!({"q":"preset"})).unwrap()["canvas"]["screen_quality"]
            .get("foreign_id")
            .is_none()
    );
}
