//! IDs for Render's original artwork catalog; no pixels or renderer dependency.
use serde_json::{json, Value};
pub(crate) const SETS: [(&str, &str); 12] = [
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
pub(crate) const SIZES: [(&str, f64); 4] = [
    ("small", 0.75),
    ("regular", 1.0),
    ("large", 1.5),
    ("extra_large", 2.0),
];
pub(crate) fn query() -> Value {
    json!({"sets":SETS.iter().map(|(id,name)|json!({"id":id,"name":name})).collect::<Vec<_>>(),"shapes":SHAPES,"logical_sizes":SIZES.iter().map(|(id,scale)|json!({"id":id,"scale":scale})).collect::<Vec<_>>()})
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::{tests::Fixture, Project};
    #[test]
    fn authored_cursor_paths_catalog_defaults_roundtrip_and_legacy_abi_are_stable() {
        let fixture = Fixture::new();
        let mut p = Project::create(&fixture.0).unwrap();
        assert_eq!(p.data.cursor.set_id.as_deref(), Some("classic"));
        assert!(p.data.cursor.shape.is_none());
        assert_eq!(p.data.cursor.logical_size, "regular");
        assert_eq!(p.query(&json!({"q":"cursor_library"})).unwrap(), query());
        let original = p.frame(0).unwrap();
        for (id, _) in SETS {
            p.apply(&json!({"op":"set","path":"cursor.set_id","value":id}))
                .unwrap();
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
}
