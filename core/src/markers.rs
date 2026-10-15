//! Immutable recording flags mapped through the exact edited media clock.
use crate::{project::Project, time};
use serde_json::{json, Value};

pub(crate) fn query(p: &Project) -> Value {
    // Filter once, rather than rescanning a 1 kHz recording for every clip.
    let mut markers = Vec::new();
    for (segment, events) in p.session.segments.iter().zip(&p.events) {
        for (ordinal, event) in events.iter().enumerate() {
            if event.kind != "marker" {
                continue;
            }
            let id = event
                .details
                .get("marker_id")
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty())
                .map(str::to_owned)
                .unwrap_or_else(|| format!("marker:{}:{ordinal}", segment.index));
            markers.push((
                segment.src_start_ns + event.t,
                segment.index,
                ordinal,
                event.t,
                id,
            ));
        }
    }
    markers.sort_by_key(|m| m.0);
    let index = time::ClipTimeIndex::new(&p.data.timeline.clips);
    let mut rows = Vec::new();
    for (i, clip) in p.data.timeline.clips.iter().enumerate() {
        let start = markers.partition_point(|m| m.0 < clip.src_start_ns);
        let end = markers.partition_point(|m| m.0 < clip.src_end_ns);
        for (src, segment, ordinal, segment_ns, marker_id) in &markers[start..end] {
            if let Some(tl) = index.source_to_timeline(&p.data.timeline.clips, i, *src) {
                rows.push(
                    json!({"id":format!("marker:{segment}:{ordinal}:{}",clip.id),
                    "marker_id":marker_id,"segment":segment,"segment_ns":segment_ns,
                    "src_ns":src,"tl_ns":tl,"clip_id":clip.id}),
                );
            }
        }
    }
    rows.sort_by_key(|row| row["tl_ns"].as_i64());
    rows.into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{model::Event, project::tests::Fixture};

    #[test]
    fn markers_follow_splits_speed_cuts_repeats_history_and_saved_projects() {
        let f = Fixture::new();
        // Replace only the owned copy's event log, retaining immutable fixtures.
        for (segment, content) in [
            (0, concat!("{\"t\":0,\"type\":\"marker\",\"marker_id\":\"start\"}\n",
                "{\"t\":1000000000,\"type\":\"marker\",\"marker_id\":\"boundary\"}\n",
                "{\"t\":1000000000,\"type\":\"marker\",\"marker_id\":\"\"}\n",
                "{\"t\":2000000000,\"type\":\"key\",\"key\":\"k\"}\n")),
            (1, "{\"t\":0,\"type\":\"marker\",\"marker_id\":\"resume\"}\n{\"t\":2000000000,\"type\":\"marker\",\"marker_id\":\"end\"}\n"),
        ] {
            std::fs::write(f.0.join(format!("recording/seg-{segment:03}/events.jsonl")), content).unwrap();
        }
        let mut p = Project::create(&f.0).unwrap();
        p.data.autosave = false;
        let original = query(&p);
        assert_eq!(original.as_array().unwrap().len(), 4);
        assert_eq!(original[2]["marker_id"], "marker:0:2");
        assert_eq!(original[3]["src_ns"], 3_000_000_000_i64);
        p.apply(&json!({"op":"split","at_tl_ns":1_000_000_000}))
            .unwrap();
        let id = p.data.timeline.clips[1].id.clone();
        let split = query(&p);
        assert_eq!(split[1]["clip_id"], id);
        assert_eq!(split.as_array().unwrap().len(), 4);
        p.apply(&json!({"op":"set_speed","clip_id":id,"speed":2}))
            .unwrap();
        assert_eq!(query(&p)[3]["tl_ns"], 2_000_000_000_i64);
        p.apply(&json!({"op":"delete_range","tl_start_ns":900_000_000,"tl_end_ns":1_100_000_000}))
            .unwrap();
        assert_eq!(query(&p).as_array().unwrap().len(), 2);
        p.undo().unwrap();
        let restored = query(&p);
        assert_eq!(restored[1]["tl_ns"], 1_000_000_000_i64);
        let snapshot = p.clone();
        let mut repeated = p.data.timeline.clips[1].clone();
        repeated.id = "repeat".into();
        p.data.timeline.clips.push(repeated);
        let rows = query(&p);
        assert_eq!(rows.as_array().unwrap().len(), 7);
        assert_eq!(rows[4]["marker_id"], rows[1]["marker_id"]);
        assert_ne!(rows[4]["id"], rows[1]["id"]);
        assert_eq!(rows[4]["tl_ns"], 3_000_000_000_i64);
        assert_eq!(query(&snapshot), restored);
        p.save(&f.0).unwrap();
        assert_eq!(query(&Project::open(&f.0).unwrap()), rows);
        assert!(p
            .query(&json!({"q":"preset"}))
            .unwrap()
            .get("markers")
            .is_none());
    }

    #[test]
    fn marker_mapping_uses_exact_large_fractional_clocks_and_no_mouse_input() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        assert_eq!(query(&p), json!([]));
        let start = (1_i64 << 53) + 1;
        p.session.segments[0].src_start_ns = start;
        p.session.segments.truncate(1);
        p.events = vec![vec![serde_json::from_value::<Event>(
            json!({"t":1,"type":"marker","marker_id":"large"}),
        )
        .unwrap()]];
        p.data.timeline.clips[0].src_start_ns = start;
        p.data.timeline.clips[0].src_end_ns = start + 1_000_000_000;
        p.data.timeline.clips[0].speed = 1.6;
        let rows = query(&p);
        assert_eq!(rows[0]["src_ns"].as_i64(), Some(start + 1));
        assert_eq!(rows[0]["tl_ns"], 1);
        assert_eq!(rows[0]["segment_ns"], 1);
    }
}
