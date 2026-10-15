//! Immutable recording flags mapped through the exact edited media clock.
use crate::{
    model::{Event, Session},
    project::{relative_path, Error, Project, Result},
    time,
};
use serde_json::{json, Value};

/// Toolbar versions that predate Capture's durable marker event API wrote this
/// optional global-clock sidecar. Normalize once; queries never touch the disk.
pub(crate) fn load_sidecar(
    package: &std::path::Path,
    session: &Session,
    events: &mut [Vec<Event>],
) -> Result<()> {
    let path = relative_path(package, "recording/markers.json")?;
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    #[derive(serde::Deserialize)]
    struct Sidecar {
        markers_ns: Vec<i64>,
    }
    let raw: Value = serde_json::from_slice(&bytes)?;
    if !raw.is_object() {
        return Err(Error::new(2, "Marker sidecar must be an object"));
    }
    let sidecar: Sidecar = serde_json::from_value(raw)?;
    let mut seen: std::collections::HashSet<i64> = session
        .segments
        .iter()
        .zip(events.iter())
        .flat_map(|(segment, list)| {
            list.iter()
                .filter(|e| e.kind == "marker")
                .map(move |e| segment.src_start_ns + e.t)
        })
        .collect();
    for (ordinal, src) in sidecar.markers_ns.into_iter().enumerate() {
        let Some(index) = session
            .segments
            .partition_point(|s| s.src_start_ns <= src)
            .checked_sub(1)
        else {
            continue;
        };
        let segment = &session.segments[index];
        if src >= segment.src_start_ns + segment.duration_ns || !seen.insert(src) {
            continue;
        }
        events[index].push(serde_json::from_value(json!({"t":src-segment.src_start_ns,"type":"marker","marker_id":format!("ui-marker:{ordinal}")}))?);
    }
    for list in events {
        list.sort_by_key(|event| event.t);
    }
    Ok(())
}

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
    fn toolbar_sidecar_merges_capture_flags_and_maps_edited_paused_segments() {
        let f = Fixture::new();
        let event_path = f.0.join("recording/seg-000/events.jsonl");
        std::fs::write(
            &event_path,
            "{\"t\":1000000000,\"type\":\"marker\",\"marker_id\":\"durable\"}\n",
        )
        .unwrap();
        let sidecar = f.0.join("recording/markers.json");
        let bytes = serde_json::to_vec(&json!({"markers_ns":[3_000_000_000_i64,0,1_000_000_000,3_000_000_000_i64,5_000_000_000_i64,-1,i64::MAX,1_500_000_000],"description":"optional metadata"})).unwrap();
        std::fs::write(&sidecar, &bytes).unwrap();
        let events_before = std::fs::read(&event_path).unwrap();
        let mut p = Project::create(&f.0).unwrap();
        let rows = query(&p);
        assert_eq!(rows.as_array().unwrap().len(), 4);
        assert_eq!(rows[0]["marker_id"], "ui-marker:1");
        assert_eq!(rows[1]["marker_id"], "durable");
        assert_eq!(rows[2]["marker_id"], "ui-marker:7");
        assert_eq!(rows[3]["marker_id"], "ui-marker:0");
        assert_eq!(rows[3]["segment"], 1);
        assert_eq!(rows[3]["segment_ns"], 0);
        p.apply(&json!({"op":"split","at_tl_ns":1_000_000_000}))
            .unwrap();
        let id = p.data.timeline.clips[1].id.clone();
        p.apply(&json!({"op":"set_speed","clip_id":id,"speed":2}))
            .unwrap();
        assert_eq!(query(&p)[3]["tl_ns"], 2_000_000_000_i64);
        p.apply(
            &json!({"op":"delete_range","tl_start_ns":1_000_000_000,"tl_end_ns":1_300_000_000}),
        )
        .unwrap();
        assert_eq!(query(&p).as_array().unwrap().len(), 2);
        p.undo().unwrap();
        let snapshot = p.clone();
        p.save(&f.0).unwrap();
        assert_eq!(query(&Project::open(&f.0).unwrap()), query(&p));
        assert_eq!(std::fs::read(&sidecar).unwrap(), bytes);
        assert_eq!(std::fs::read(&event_path).unwrap(), events_before);
        std::fs::write(&sidecar, "{\"markers_ns\":[]}").unwrap();
        assert_eq!(query(&snapshot).as_array().unwrap().len(), 4);
        assert_eq!(
            query(&Project::open(&f.0).unwrap())
                .as_array()
                .unwrap()
                .len(),
            1
        );
    }

    #[test]
    fn malformed_toolbar_marker_sidecars_fail_explicitly_without_rewriting_recordings() {
        let f = Fixture::new();
        let sidecar = f.0.join("recording/markers.json");
        for bad in [
            "{",
            "{}",
            "[[0]]",
            "{\"markers_ns\":null}",
            "{\"markers_ns\":[0.5]}",
            "{\"markers_ns\":[9223372036854775808]}",
        ] {
            std::fs::write(&sidecar, bad).unwrap();
            assert_eq!(Project::create(&f.0).err().unwrap().status, 2);
            assert_eq!(std::fs::read_to_string(&sidecar).unwrap(), bad);
        }
        std::fs::remove_file(&sidecar).unwrap();
        assert_eq!(query(&Project::create(&f.0).unwrap()), json!([]));
    }

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
