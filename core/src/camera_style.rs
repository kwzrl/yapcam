//! Original camera recipes and validated local grading metadata.
use crate::{
    model::ProjectData,
    project::{Error, Result},
};
use serde_json::{json, Value};
// Original scalar recipes; no LUT artwork or reference assets are distributed.
const RECIPES: [(&str, &str, [f64; 4]); 12] = [
    ("calm", "Calm", [0.0, 0.1, 0.05, 0.0]),
    ("warm_window", "Warm Window", [0.3, 0.2, 0.1, 0.1]),
    ("cool_air", "Cool Air", [-0.25, 0.1, 0.08, -0.05]),
    ("soft_portrait", "Soft Portrait", [0.12, 0.3, -0.15, -0.1]),
    ("clear_light", "Clear Light", [0.0, 0.0, 0.2, 0.15]),
    ("rich_earth", "Rich Earth", [0.2, 0.2, 0.3, 0.25]),
    ("evening", "Evening", [0.4, 0.1, 0.15, -0.1]),
    ("muted", "Muted", [0.0, 0.1, -0.1, -0.4]),
    ("bright_room", "Bright Room", [0.08, 0.25, 0.1, 0.1]),
    ("deep_contrast", "Deep Contrast", [-0.05, 0.0, 0.5, 0.05]),
    ("silver", "Silver", [0.0, 0.0, 0.2, -1.0]),
    ("soft_grain", "Soft Grain", [0.1, 0.0, -0.2, -0.2]),
];
pub(crate) fn library() -> Value {
    RECIPES
        .iter()
        .map(|(id, name, p)| {
            json!({"id":id,"name":name,
        "warmth":p[0],"background_pop":p[1],"contrast":p[2],"color_intensity":p[3]})
        })
        .collect::<Vec<_>>()
        .into()
}
pub(crate) fn did_set(p: &mut ProjectData, path: &str) {
    let s = &mut p.camera.style;
    if path == "camera.style.preset" {
        if let Some((_, _, recipe)) = RECIPES.iter().find(|r| r.0 == s.preset) {
            [s.warmth, s.background_pop, s.contrast, s.color_intensity] = *recipe;
        }
    } else if matches!(
        path,
        "camera.style.warmth"
            | "camera.style.background_pop"
            | "camera.style.contrast"
            | "camera.style.color_intensity"
    ) {
        s.preset = "custom".into();
    }
}
pub(crate) fn validate(p: &ProjectData) -> Result<()> {
    let s = &p.camera.style;
    let r = s.crop;
    if !matches!(s.preset.as_str(), "original" | "custom" | "lut")
        && !RECIPES.iter().any(|r| r.0 == s.preset)
        || !(-1.0..=1.0).contains(&s.warmth)
        || !(-1.0..=1.0).contains(&s.contrast)
        || !(-1.0..=1.0).contains(&s.color_intensity)
        || [
            s.intensity,
            s.background_pop,
            s.sharpen,
            s.grain,
            s.background_blur,
        ]
        .iter()
        .any(|v| !(0.0..=1.0).contains(v))
        || r.iter().any(|v| !v.is_finite())
        || r[0] < 0.0
        || r[1] < 0.0
        || r[2] <= 0.0
        || r[3] <= 0.0
        || r[0] + r[2] > 1.0
        || r[1] + r[3] > 1.0
        || s.lut_path
            .as_ref()
            .is_some_and(|path| !p.media.iter().any(|m| &m.path == path))
        || s.preset == "lut" && s.lut_path.is_none()
    {
        return Err(Error::new(1, "Invalid camera style or unregistered LUT"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::{tests::Fixture, Project};
    #[test]
    fn camera_style_recipes_paths_validation_migration_and_portability() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.data.autosave = false;
        let original = p.data.clone();
        assert_eq!(library().as_array().unwrap().len(), 12);
        for (id, _, expected) in RECIPES {
            p.apply(&json!({"op":"set","path":"camera.style.preset","value":id}))
                .unwrap();
            let style = &p.data.camera.style;
            assert_eq!(
                [
                    style.warmth,
                    style.background_pop,
                    style.contrast,
                    style.color_intensity
                ],
                expected
            );
            assert_eq!(
                p.query(&json!({"q":"render_options"})).unwrap()["camera_style"]["preset"],
                id
            );
        }
        p.apply(&json!({"op":"set","path":"camera.style.warmth","value":-0.4}))
            .unwrap();
        assert_eq!(p.data.camera.style.preset, "custom");
        for (path, value) in [
            ("preset", json!("unknown")),
            ("intensity", json!(1.1)),
            ("sharpen", json!(-0.1)),
            ("crop", json!([0.5, 0.0, 0.7, 1.0])),
            ("lut_path", json!("../outside.cube")),
            ("preset", json!("lut")),
        ] {
            let before = p.data.clone();
            assert!(p
                .apply(&json!({"op":"set","path":format!("camera.style.{path}"),"value":value}))
                .is_err());
            assert_eq!(p.data, before);
        }
        p.apply(&json!({"op":"set","path":"camera.style.crop","value":[0.1,0.1,0.7,0.7]}))
            .unwrap();
        let preset = p.query(&json!({"q":"preset"})).unwrap();
        assert!(preset["camera"]["style"].get("crop").is_none());
        assert!(preset["camera"]["style"].get("lut_path").is_none());
        p.save(&f.0).unwrap();
        assert_eq!(Project::open(&f.0).unwrap().data, p.data);
        let mut legacy = serde_json::to_value(&original).unwrap();
        legacy["camera"].as_object_mut().unwrap().remove("style");
        assert_eq!(
            crate::project::decode_project(&serde_json::to_vec(&legacy).unwrap())
                .unwrap()
                .camera
                .style,
            original.camera.style
        );
        let before = p.data.clone();
        p.apply(&json!({"op":"apply_preset","preset":{"camera":{"style":{"preset":"lut","lut_path":"foreign.cube","crop":[0.0,0.0,0.1,0.1]}}}})).unwrap();
        assert_eq!(p.data, before);
    }
}
