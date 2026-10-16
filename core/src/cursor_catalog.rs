//! IDs for Render's original artwork catalog; no pixels or renderer dependency.
use serde_json::{json, Value};
pub(crate) const SETS: [(&str, &str); 14] = [
    ("original", "Original"),
    ("touch", "Touch"),
    ("classic", "Classic"),
    ("paper", "Paper"),
    ("soft-slate", "Soft Slate"),
    ("soft-cloud", "Soft Cloud"),
    ("lagoon", "Lagoon"),
    ("coral", "Coral"),
    ("sage", "Sage"),
    ("violet", "Violet"),
    ("gold", "Gold"),
    ("precision-dark", "Precision Dark"),
    ("precision-light", "Precision Light"),
    ("signal", "Signal"),
];
pub(crate) const SHAPES: [&str; 10] = [
    "arrow",
    "pointing_hand",
    "touch",
    "text",
    "resize_horizontal",
    "resize_vertical",
    "resize_diagonal_nwse",
    "resize_diagonal_nesw",
    "open_hand",
    "closed_hand",
];
pub(crate) const VARIANTS: [&str; 2] = ["standard", "alternate"];
pub(crate) const SIZES: [(&str, f64); 4] = [
    ("small", 0.75),
    ("regular", 1.0),
    ("large", 1.5),
    ("extra_large", 2.0),
];
pub(crate) fn query() -> Value {
    json!({"sets":SETS.iter().map(|(id,name)|json!({"id":id,"name":name})).collect::<Vec<_>>(),"shapes":SHAPES,"logical_sizes":SIZES.iter().map(|(id,scale)|json!({"id":id,"scale":scale})).collect::<Vec<_>>(),"variants":VARIANTS})
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::{tests::Fixture, Project};
    #[test]
    fn authored_cursor_paths_catalog_defaults_roundtrip_and_legacy_abi_are_stable() {
        let fixture = Fixture::new();
        let mut p = Project::create(&fixture.0).unwrap();
        assert_eq!(p.data.cursor.set_id.as_deref(), Some("original"));
        assert!(p.data.cursor.shape.is_none());
        assert_eq!(p.data.cursor.logical_size, "regular");
        assert_eq!(p.query(&json!({"q":"cursor_library"})).unwrap(), query());
        let original = p.frame(0).unwrap();
        for (id, _) in SETS {
            p.apply(&json!({"op":"set","path":"cursor.set_id","value":id}))
                .unwrap();
            assert_eq!(
                p.query(&json!({"q":"render_options"})).unwrap()["cursor_set_id"],
                id
            );
            p.save(&fixture.0).unwrap();
            assert_eq!(
                Project::open(&fixture.0)
                    .unwrap()
                    .data
                    .cursor
                    .set_id
                    .as_deref(),
                Some(id)
            );
        }
        for shape in SHAPES {
            p.apply(&json!({"op":"set","path":"cursor.shape","value":shape}))
                .unwrap();
        }
        for (size, _) in SIZES {
            p.apply(&json!({"op":"set","path":"cursor.logical_size","value":size}))
                .unwrap();
        }
        let options = p.query(&json!({"q":"render_options"})).unwrap();
        assert_eq!(options["cursor_set_id"], json!("signal"));
        assert_eq!(options["cursor_shape"], json!("closed_hand"));
        assert_eq!(options["cursor_logical_size"], json!("extra_large"));
        let frozen = p.clone();
        assert_eq!(p.frame(0).unwrap().cursor_scale, original.cursor_scale);
        assert_eq!(p.frame(0).unwrap().cursor_id, original.cursor_id);
        assert_eq!(p.frame_extras(0).unwrap().cursor_style, 0);
        assert_eq!(
            p.query(&json!({"q":"preset"})).unwrap()["cursor"]["set_id"],
            json!("signal")
        );
        p.apply(&json!({"op":"set","path":"cursor.always_default","value":true}))
            .unwrap();
        for t in [0, 2_500_000_000, 5_000_000_000] {
            let options = p.query(&json!({"q":"render_options","tl_ns":t})).unwrap();
            assert_eq!(options["cursor_shape"], json!("arrow"));
            assert_eq!(options["cursor_style"], json!("pointer"));
            assert_eq!(options["cursor_set_id"], json!("signal"));
            assert_eq!(options["cursor_logical_size"], json!("extra_large"));
            assert_eq!(p.frame_extras(t).unwrap().cursor_style, 1);
            assert_eq!(
                p.query(&json!({"q":"effects_at","tl_ns":t})).unwrap()["render_options"]
                    ["cursor_shape"],
                json!("arrow")
            );
        }
        assert_eq!(
            frozen.query(&json!({"q":"render_options"})).unwrap()["cursor_shape"],
            json!("closed_hand")
        );
        p.undo().unwrap();
        assert_eq!(p.data.cursor.shape.as_deref(), Some("closed_hand"));
        let before = p.data.clone();
        let history = p.undo.len();
        for (path, value) in [
            ("cursor.set_id", json!("unknown")),
            ("cursor.shape", json!("pointer")),
            ("cursor.logical_size", json!("extraLarge")),
            ("cursor.set_id", json!(17)),
            ("cursor.shape", json!(true)),
            ("cursor.logical_size", Value::Null),
        ] {
            assert!(p
                .apply(&json!({"op":"set","path":path,"value":value}))
                .is_err());
            assert_eq!(p.data, before);
            assert_eq!(p.undo.len(), history);
        }
        p.save(&fixture.0).unwrap();
        assert_eq!(
            Project::open(&fixture.0).unwrap().data.cursor,
            p.data.cursor
        );
        p.apply(&json!({"op":"batch","commands":[{"op":"set","path":"cursor.set_id","value":null},{"op":"set","path":"cursor.shape","value":null},{"op":"set","path":"cursor.logical_size","value":"regular"}]})).unwrap();
        assert_eq!(
            p.query(&json!({"q":"render_options"})).unwrap()["cursor_shape"],
            Value::Null
        );
        p.undo().unwrap();
        assert_eq!(p.data, before);
        p.redo().unwrap();
        assert!(p.data.cursor.shape.is_none());
        assert_eq!(
            crate::allocation_test::count(|| {
                p.frame(0).unwrap();
                p.frame_extras(0).unwrap();
                p.frame_motion(0).unwrap();
            }),
            0
        );
        assert_eq!(crate::ffi::YC_ABI_VERSION, 3);
    }

    #[test]
    fn cursor_variants_validate_roundtrip_history_snapshots_and_portable_presets() {
        let fixture = Fixture::new();
        let mut p = Project::create(&fixture.0).unwrap();
        let standard = serde_json::to_value(&p.data.cursor.variants).unwrap();
        assert_eq!(standard.as_object().unwrap().len(), 12);
        for shape in standard.as_object().unwrap().keys() {
            assert_eq!(standard[shape], "standard");
            for variant in VARIANTS {
                p.apply(
                    &json!({"op":"set","path":format!("cursor.variants.{shape}"),"value":variant}),
                )
                .unwrap();
                for q in [
                    json!({"q":"render_options"}),
                    json!({"q":"render_options","tl_ns":0}),
                ] {
                    assert_eq!(p.query(&q).unwrap()["cursor_variants"][shape], variant);
                }
                assert_eq!(
                    p.query(&json!({"q":"effects_at","tl_ns":0})).unwrap()["render_options"]
                        ["cursor_variants"][shape],
                    variant
                );
                assert_eq!(
                    p.query(&json!({"q":"render_options_at","tl_ns":0}))
                        .unwrap()["cursor_variants"][shape],
                    variant
                );
            }
        }
        let alternate = p.data.cursor.variants.clone();
        let frozen = p.clone();
        p.apply(&json!({"op":"set","path":"cursor.variants.arrow","value":"standard"}))
            .unwrap();
        assert_eq!(
            p.data.cursor.variants.arrow,
            crate::model::CursorVariant::Standard
        );
        assert_eq!(frozen.data.cursor.variants, alternate);
        p.undo().unwrap();
        assert_eq!(p.data.cursor.variants, alternate);
        p.redo().unwrap();
        assert_eq!(
            p.data.cursor.variants.arrow,
            crate::model::CursorVariant::Standard
        );
        p.save(&fixture.0).unwrap();
        assert_eq!(
            Project::open(&fixture.0).unwrap().data.cursor.variants,
            p.data.cursor.variants
        );

        let other_fixture = Fixture::new();
        let mut other = Project::create(&other_fixture.0).unwrap();
        let preset = p.query(&json!({"q":"preset"})).unwrap();
        other
            .apply(&json!({"op":"apply_preset","preset":preset}))
            .unwrap();
        assert_eq!(other.data.cursor.variants, p.data.cursor.variants);
        // Portable partial patches preserve other type choices; whole set objects reset omissions.
        other
            .apply(
                &json!({"op":"apply_preset","preset":{"cursor":{"variants":{"text":"standard"}}}}),
            )
            .unwrap();
        assert_eq!(
            other.data.cursor.variants.text,
            crate::model::CursorVariant::Standard
        );
        assert_eq!(
            other.data.cursor.variants.crosshair,
            crate::model::CursorVariant::Alternate
        );
        other
            .apply(&json!({"op":"set","path":"cursor.variants","value":{"text":"alternate"}}))
            .unwrap();
        assert_eq!(
            other.data.cursor.variants.text,
            crate::model::CursorVariant::Alternate
        );
        assert_eq!(
            other.data.cursor.variants.crosshair,
            crate::model::CursorVariant::Standard
        );

        let before = p.data.clone();
        let history = p.undo.len();
        for (path, value) in [
            ("cursor.variants.arrow", json!("unknown")),
            ("cursor.variants.arrow", json!("Alternate")),
            ("cursor.variants.arrow", json!(null)),
            ("cursor.variants.arrow", json!(true)),
            ("cursor.variants.arrow", json!(1)),
            ("cursor.variants.pointer", json!("alternate")),
            ("cursor.variants", json!({"invented":"alternate"})),
            ("cursor.variants", json!(null)),
            ("cursor.set_id", json!("Original")),
            ("cursor.set_id", json!("touch-extra")),
        ] {
            assert!(p.apply(&json!({"op":"batch","commands":[{"op":"set","path":"cursor.set_id","value":"touch"},{"op":"set","path":path,"value":value}]})).is_err());
            assert_eq!(p.data, before);
            assert_eq!(p.undo.len(), history);
        }
    }

    #[test]
    fn older_cursor_selections_and_missing_variants_keep_their_appearance() {
        let fixture = Fixture::new();
        let p = Project::create(&fixture.0).unwrap();
        for revision in [0, 1] {
            for selection in [
                Value::Null,
                json!("classic"),
                json!("original"),
                json!("touch"),
                json!("signal"),
            ] {
                let mut raw = serde_json::to_value(&p.data).unwrap();
                raw["defaults_revision"] = json!(revision);
                raw["cursor"]["set_id"] = selection.clone();
                raw["cursor"].as_object_mut().unwrap().remove("variants");
                let decoded =
                    crate::project::decode_project(&serde_json::to_vec(&raw).unwrap()).unwrap();
                assert_eq!(
                    serde_json::to_value(&decoded.cursor.set_id).unwrap(),
                    selection
                );
                assert_eq!(
                    decoded.cursor.variants,
                    crate::model::CursorVariants::default()
                );
                raw["cursor"].as_object_mut().unwrap().remove("set_id");
                let decoded =
                    crate::project::decode_project(&serde_json::to_vec(&raw).unwrap()).unwrap();
                assert!(decoded.cursor.set_id.is_none());
            }
        }
    }
}
