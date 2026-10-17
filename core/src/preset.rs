//! Portable look settings share one schema filter for export and import.
use crate::{model::*, project::Result};
use serde_json::{json, Value};

fn schema() -> Value {
    let mut schema = json!({
        "canvas": Canvas::default(), "cursor": Cursor::default(),
        "camera": Camera::default(), "audio": Audio::default(),
        "zoom_settings": ZoomSettings::default(), "export": Export::default()
    });
    // An optional object needs its selected shape even though its default is
    // null, so preset filtering/recursive merge never accepts unknown keys.
    schema["canvas"]["screen_quality"] = serde_json::to_value(ScreenQuality::default()).unwrap();
    for (group, fields) in [
        (
            "canvas",
            &["crop", "highlights", "annotations", "reactions", "captions"][..],
        ),
        ("cursor", &["ranges"][..]),
        (
            "camera",
            &["layouts", "silence_ranges", "speech_activity"][..],
        ),
        ("audio", &["ranges", "music", "mic_replacements"][..]),
    ] {
        for field in fields {
            schema[group].as_object_mut().unwrap().remove(*field);
        }
    }
    schema["canvas"]["background"]
        .as_object_mut()
        .unwrap()
        .remove("asset");
    for field in ["crop", "lut_path"] {
        schema["camera"]["style"]
            .as_object_mut()
            .unwrap()
            .remove(field);
    }
    schema
}

// Objects select known descendants; scalar/array leaves are validated by the
// normal model deserializer and project validator after the transactional merge.
fn filter(input: &Value, schema: &Value) -> Value {
    match schema.as_object() {
        Some(fields) => Value::Object(
            fields
                .iter()
                .filter_map(|(key, shape)| {
                    let value = input.get(key)?;
                    let supplied_fields =
                        value.as_object().is_some_and(|fields| !fields.is_empty());
                    // An invalid style object must fail validation rather than silently
                    // accepting it as an empty patch.
                    let value = if shape.is_object() && !value.is_object() {
                        value.clone()
                    } else {
                        filter(value, shape)
                    };
                    // Ignoring an unknown-only object must not select an optional
                    // setting whose current value is null. Explicit {} still opts in.
                    if shape.is_object()
                        && supplied_fields
                        && value.as_object().is_some_and(|fields| fields.is_empty())
                    {
                        return None;
                    }
                    Some((key.clone(), value))
                })
                .collect(),
        ),
        None => input.clone(),
    }
}

pub(crate) fn export(data: &ProjectData) -> Result<Value> {
    Ok(filter(&serde_json::to_value(data)?, &schema()))
}

fn merge(target: &mut Value, patch: Value) {
    if let (Some(target), Some(fields)) = (target.as_object_mut(), patch.as_object()) {
        for (key, value) in fields {
            merge(target.get_mut(key).unwrap(), value.clone());
        }
    } else {
        *target = patch;
    }
}

pub(crate) fn apply(data: &mut ProjectData, input: &Value) -> Result<Vec<String>> {
    let mut patch = filter(input, &schema());
    if let Some(cursor) = patch.get_mut("cursor") {
        let legacy_threshold = cursor.get("remove_shakes").is_some();
        crate::model::migrate_cursor(cursor, legacy_threshold);
    }
    // Only add_media may select imported image bytes. Never reinterpret a source
    // media index (or accidentally select an existing destination image).
    if patch["canvas"]["background"]["kind"] == "image" {
        patch["canvas"]["background"]
            .as_object_mut()
            .unwrap()
            .remove("kind");
    }
    if patch["camera"]["style"]["preset"] == "lut" {
        patch["camera"]["style"]
            .as_object_mut()
            .unwrap()
            .remove("preset");
    }
    let changed = patch.as_object().unwrap().keys().cloned().collect();
    let mut next = serde_json::to_value(&*data)?;
    merge(&mut next, patch);
    *data = serde_json::from_value(next)?;
    Ok(changed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::{tests::Fixture, Project};

    #[test]
    fn preset_saved_in_project_a_applies_to_project_b() {
        let a = Fixture::new();
        let b = Fixture::new();
        let mut source = Project::create(&a.0).unwrap();
        let mut target = Project::create(&b.0).unwrap();
        source.data.autosave = false;
        target.data.autosave = false;
        source.data.timeline.clips[0].id = "only-in-A".into();
        target.data.timeline.clips[0].id = "only-in-B".into();
        source
            .apply(&json!({"op":"batch","commands":[
                {"op":"set","path":"canvas.padding","value":75},
                {"op":"set","path":"canvas.crop","value":[0.1,0.1,0.7,0.7]},
                {"op":"insert_zoom"}, {"op":"insert_layout"}, {"op":"insert_mask"},
                {"op":"set_clip_settings","clip_id":"only-in-A","patch":{"hide_cursor":true}}
            ]}))
            .unwrap();
        target.apply(&json!({"op":"batch","commands":[
            {"op":"split","at_tl_ns":1_000_000_000},
            {"op":"insert_zoom","tl_start_ns":500_000_000},
            {"op":"insert_layout","tl_start_ns":500_000_000},
            {"op":"insert_mask","tl_start_ns":500_000_000},
            {"op":"set","path":"cursor.ranges","value":[{"tl_start_ns":0,"tl_end_ns":1_000_000_000,"visible":false}]},
            {"op":"set","path":"audio.ranges","value":[{"id":"B-fade","track":"mic","tl_start_ns":0,"tl_end_ns":1_000_000_000,"start_gain_db":-10,"end_gain_db":0}]},
            {"op":"add_caption","record":{"text":"B caption","tl_start_ns":0,"tl_end_ns":1_000_000_000}},
            {"op":"add_music","record":{"source":"calm","tl_start_ns":0,"tl_end_ns":1_000_000_000}}
        ]})).unwrap();
        let before = target.data.clone();
        let preset = source.query(&json!({"q":"preset"})).unwrap();
        for path in [
            "/timeline",
            "/zooms",
            "/id",
            "/recording",
            "/media",
            "/canvas/crop",
            "/canvas/highlights",
            "/canvas/annotations",
            "/canvas/reactions",
            "/canvas/captions",
            "/cursor/ranges",
            "/camera/layouts",
            "/audio/ranges",
            "/audio/music",
            "/canvas/background/asset",
        ] {
            assert!(preset.pointer(path).is_none(), "leaked {path}");
        }
        target
            .apply(&json!({"op":"apply_preset","preset":preset}))
            .unwrap();
        let mut expected = before.clone();
        expected.canvas.padding = 75.0;
        expected.canvas.padding_ratio = source.data.canvas.padding_ratio;
        expected.modified_at = target.data.modified_at.clone();
        assert_eq!(target.data, expected);
        target.undo().unwrap();
        assert_eq!(target.data, before);
        target.redo().unwrap();
        assert_eq!(target.data, expected);

        // Legacy/full-project payloads may contain foreign IDs and invalid times.
        // Ignore them even when nested under a supported setting group.
        let mut legacy = serde_json::to_value(&source.data).unwrap();
        legacy["canvas"]["highlights"] = json!([{"id":"foreign","tl_end_ns":-1}]);
        legacy["cursor"]["ranges"] = json!("invalid foreign ranges");
        legacy["camera"]["layouts"] = json!([{"id":"foreign"}]);
        legacy["audio"]["music"] = json!([{"path":"recording/foreign.m4a"}]);
        legacy["canvas"]["background"]["asset"] = json!(999999);
        legacy["canvas"]["background"]["kind"] = json!("image");
        legacy["cursor"]["key_overlay"]["clip_id"] = json!("only-in-A");
        legacy["canvas"]["shadow"]["tl_start_ns"] = json!(-1);
        target
            .apply(&json!({"op":"apply_preset","preset":legacy}))
            .unwrap();
        assert_eq!(target.data, expected);
    }

    #[test]
    fn partial_style_merges_and_invalid_styles_are_atomic() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.data.autosave = false;
        let before = p.data.clone();
        p.apply(&json!({"op":"apply_preset","preset":{"canvas":{"shadow":{"opacity":0.7}},"timeline":{"clips":[]}}})).unwrap();
        let mut expected = before;
        expected.canvas.shadow.opacity = 0.7;
        expected.modified_at = p.data.modified_at.clone();
        assert_eq!(p.data, expected);
        for patch in [
            json!({"canvas":{"radius":-1}}),
            json!({"canvas":null}),
            json!({"cursor":{"spring":false}}),
        ] {
            assert!(p
                .apply(&json!({"op":"apply_preset","preset":patch}))
                .is_err());
            assert_eq!(p.data, expected);
        }
        let undo = p.undo.len();
        assert!(p
            .apply(&json!({"op":"apply_preset","preset":{"timeline":{},"zooms":[null]}}))
            .unwrap()
            .changed
            .is_empty());
        assert_eq!(p.undo.len(), undo);
    }
}
