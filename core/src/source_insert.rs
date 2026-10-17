//! Restore original source without rewinding unrelated project edits.
use crate::{
    commands::ChangeSet,
    model::*,
    project::{unique_id, Error, Result},
    time,
};
use serde_json::Value;
pub(crate) fn apply(p: &mut ProjectData, v: &Value, cs: &mut ChangeSet) -> Result<()> {
    let int = |key: &str| {
        v[key]
            .as_i64()
            .ok_or_else(|| Error::new(1, format!("Missing integer {key}")))
    };
    let start = int("src_start_ns")?;
    let end = int("src_end_ns")?;
    let at = int("at_tl_ns")?;
    let speed = match v.get("speed") {
        Some(v) => v
            .as_f64()
            .ok_or_else(|| Error::new(1, "Invalid source insertion speed"))?,
        None => 1.0,
    };
    if start < 0 || end <= start || !(0.05..=32.0).contains(&speed) {
        return Err(Error::new(1, "Invalid source insertion bounds/speed"));
    }
    let index = time::ClipTimeIndex::new(&p.timeline.clips)
        .boundary_index(at)
        .ok_or_else(|| Error::new(1, "Source insertion requires an existing clip boundary"))?;
    let clip = Clip {
        id: unique_id("clip"),
        src_start_ns: start,
        src_end_ns: end,
        speed,
        settings: match v.get("settings") {
            Some(v) => serde_json::from_value(v.clone())?,
            None => Default::default(),
        },
    };
    let map = time::InsertTimeMap::new(&p.timeline.clips, &clip, at);
    crate::commands::seed_mask_keyframes(p, &[at.saturating_sub(1), at]);
    let held: Vec<_> = p
        .canvas
        .highlights
        .iter()
        .filter(|h| !h.keyframes.is_empty() && h.tl_start_ns < at && h.tl_end_ns > at)
        .map(|h| (h.id.clone(), crate::layers::mask_rect_at(h, at)))
        .collect();
    crate::commands::remap_effect_edges(p, |t| map.start(t), |t| map.end(t));
    for (id, rect) in held {
        let h = p.canvas.highlights.iter_mut().find(|h| h.id == id).unwrap();
        h.keyframes.push(MaskKeyframe {
            tl_ns: map.end(at),
            rect,
        });
        h.keyframes.sort_by_key(|k| k.tl_ns);
        h.keyframes.dedup_by_key(|k| k.tl_ns);
    }
    cs.created_ids.push(clip.id.clone());
    p.timeline.clips.insert(index, clip);
    cs.changed.extend(
        [
            "timeline",
            "zooms",
            "camera.layouts",
            "camera.silence_ranges",
            "cursor.ranges",
            "audio.ranges",
            "canvas.highlights",
            "canvas.annotations",
            "canvas.reactions",
            "canvas.captions",
            "audio.music",
        ]
        .map(str::to_owned),
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::{tests::Fixture, Project};
    use serde_json::json;
    #[test]
    fn targeted_restoration_keeps_later_edits_and_maps_effect_edges_and_all_tracks() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.data.autosave = false;
        p.apply(
            &json!({"op":"delete_range","tl_start_ns":1_000_000_000,"tl_end_ns":2_000_000_000_i64}),
        )
        .unwrap();
        p.apply(&json!({"op":"batch","commands":[
            {"op":"set","path":"canvas.radius","value":37},
            {"op":"set","path":"canvas.highlights","value":[
                {"id":"left","tl_start_ns":0,"tl_end_ns":1_000_000_000},
                {"id":"right","tl_start_ns":1_000_000_000,"tl_end_ns":2_000_000_000_i64},
                {"id":"span","tl_start_ns":500_000_000,"tl_end_ns":1_500_000_000}]},
            {"op":"set","path":"camera.silence_ranges","value":[{"tl_start_ns":0,"tl_end_ns":1_000_000_000},{"tl_start_ns":1_000_000_000,"tl_end_ns":2_000_000_000_i64}]}
        ]})).unwrap();
        let before = p.data.clone();
        let snapshot = p.clone();
        let result=p.apply(&json!({"op":"insert_source","src_start_ns":1_000_000_000,"src_end_ns":2_000_000_000_i64,"at_tl_ns":1_000_000_000})).unwrap();
        assert_eq!(p.data.canvas.radius, 37.0);
        assert_eq!(p.frame(1_500_000_000).unwrap().screen.src_ns, 1_500_000_000);
        assert_eq!(
            snapshot.frame(1_500_000_000).unwrap().screen.src_ns,
            2_500_000_000_i64
        );
        assert_eq!(p.data.canvas.highlights[0].tl_end_ns, 1_000_000_000);
        assert_eq!(p.data.canvas.highlights[1].tl_start_ns, 2_000_000_000_i64);
        assert_eq!(p.data.canvas.highlights[2].tl_end_ns, 2_500_000_000_i64);
        assert_eq!(p.data.camera.silence_ranges[0].tl_end_ns, 1_000_000_000);
        assert_eq!(
            p.data.camera.silence_ranges[1].tl_start_ns,
            2_000_000_000_i64
        );
        let audio = p.query(&json!({"q":"audio_ranges"})).unwrap();
        let restored = audio
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["clip_id"] == result.created_ids[0])
            .unwrap();
        assert_eq!(restored["src_start_ns"], 1_000_000_000);
        assert_eq!(restored["tl_start_ns"], 1_000_000_000);
        let after = p.data.clone();
        p.undo().unwrap();
        assert_eq!(p.data, before);
        p.redo().unwrap();
        assert_eq!(p.data, after);
        p.save(&f.0).unwrap();
        assert_eq!(Project::open(&f.0).unwrap().data, after);
        let prior = p.data.clone();
        for command in [
            json!({"op":"insert_source","src_start_ns":0,"src_end_ns":10,"at_tl_ns":123}),
            json!({"op":"insert_source","src_start_ns":0,"src_end_ns":6_000_000_000_i64,"at_tl_ns":0}),
            json!({"op":"insert_source","src_start_ns":-1,"src_end_ns":10,"at_tl_ns":0}),
            json!({"op":"timeline_edit","command":{"op":"insert_source","src_start_ns":0,"src_end_ns":50_000_000,"at_tl_ns":0}}),
        ] {
            assert!(p.apply(&command).is_err());
            assert_eq!(p.data, prior);
        }
        p.apply(&json!({"op":"delete_range","tl_start_ns":0,"tl_end_ns":5_000_000_000_i64}))
            .unwrap();
        assert!(p.data.timeline.clips.is_empty());
        p.apply(
            &json!({"op":"insert_source","src_start_ns":0,"src_end_ns":50_000_000,"at_tl_ns":0}),
        )
        .unwrap();
        assert_eq!(time::duration(&p.data.timeline.clips), 50_000_000);
    }
    #[test]
    fn fractional_insert_mapping_preserves_long_clock_boundaries() {
        let clip = |id: &str, start, end, speed| Clip {
            id: id.into(),
            src_start_ns: start,
            src_end_ns: end,
            speed,
            settings: Default::default(),
        };
        let old = vec![
            clip("long", 0, (1_i64 << 53) + 3, 1.6),
            clip("short", 0, 123, 1.6),
        ];
        let at = time::clip_bounds(&old, 1).unwrap().0;
        let inserted = clip("new", 0, 7, 1.6);
        let map = time::InsertTimeMap::new(&old, &inserted, at);
        let mut new = old.clone();
        new.insert(1, inserted);
        assert_eq!(map.start(at), time::clip_bounds(&new, 2).unwrap().0);
        assert_eq!(map.end(at), at);
        assert_eq!(map.end(time::duration(&old)), time::duration(&new));
    }
}
