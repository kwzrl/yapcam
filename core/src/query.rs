//! Structured UI queries. This is a cold path and may allocate.
use crate::{
    project::{Error, Project, Result},
    time,
};
use serde_json::{json, Value};
impl Project {
    /// Map decoded file-local silence/selection intervals to every retained
    /// occurrence on the edited timeline. No decoder or path IO runs here.
    fn map_audio_ranges(&self, query: &Value) -> Result<Value> {
        let track = query
            .get("track")
            .and_then(Value::as_str)
            .filter(|s| matches!(*s, "mic" | "system_audio"))
            .ok_or_else(|| Error::new(1, "Audio track must be mic or system_audio"))?;
        let path = query
            .get("path")
            .and_then(Value::as_str)
            .and_then(|s| s.strip_prefix("recording/"))
            .ok_or_else(|| Error::new(1, "Audio path must be recording-relative"))?;
        if !self
            .session
            .segments
            .iter()
            .any(|s| s.files.get(track).is_some_and(|p| p == path))
        {
            return Err(Error::new(1, "Audio path is not referenced by this track"));
        }
        let ranges = query
            .get("ranges")
            .and_then(Value::as_array)
            .ok_or_else(|| Error::new(1, "Missing file-local ranges"))?;
        let ranges = ranges
            .iter()
            .map(|r| {
                let a = r.get("file_start_ns").and_then(Value::as_i64);
                let b = r.get("file_end_ns").and_then(Value::as_i64);
                match (a, b) {
                    (Some(a), Some(b)) if a >= 0 && b > a => Ok((a, b)),
                    _ => Err(Error::new(1, "Invalid file-local audio range")),
                }
            })
            .collect::<Result<Vec<_>>>()?;
        let mut rows = Vec::new();
        for (i, c) in self.data.timeline.clips.iter().enumerate() {
            for s in &self.session.segments {
                if s.files.get(track).is_none_or(|p| p != path) {
                    continue;
                }
                let offset = s.track_start_ns.get(track).copied().unwrap_or(0);
                let available = s.duration_ns - offset;
                for &(a, b) in &ranges {
                    // Clamp before adding global clocks, so an oversized decoder
                    // selection cannot overflow Int64 or exceed the segment.
                    let a = (s.src_start_ns + offset + a.min(available)).max(c.src_start_ns);
                    let b = (s.src_start_ns + offset + b.min(available)).min(c.src_end_ns);
                    if b <= a {
                        continue;
                    }
                    let start =
                        time::source_boundary_to_timeline(&self.data.timeline.clips, i, a).unwrap();
                    let end =
                        time::source_boundary_to_timeline(&self.data.timeline.clips, i, b).unwrap();
                    if end > start {
                        rows.push((start, end));
                    }
                }
            }
        }
        rows.sort_unstable();
        let mut merged: Vec<(i64, i64)> = Vec::new();
        for (a, b) in rows {
            if let Some(last) = merged.last_mut() {
                if a <= last.1 {
                    last.1 = last.1.max(b);
                    continue;
                }
            }
            merged.push((a, b));
        }
        Ok(merged
            .into_iter()
            .map(|(a, b)| json!({"tl_start_ns":a,"tl_end_ns":b}))
            .collect::<Vec<_>>()
            .into())
    }
    pub fn query(&self, query: &Value) -> Result<Value> {
        match query
            .get("q")
            .and_then(Value::as_str)
            .ok_or_else(|| Error::new(1, "Missing query q"))?
        {
            "duration" => Ok(json!({"duration_ns":time::duration(&self.data.timeline.clips)})),
            "clips" => {
                let mut rows = Vec::new();
                for (i, c) in self.data.timeline.clips.iter().enumerate() {
                    let (start, end) = time::clip_bounds(&self.data.timeline.clips, i).unwrap();
                    let mut row = serde_json::to_value(c)?;
                    row["tl_start_ns"] = start.into();
                    row["tl_end_ns"] = end.into();
                    rows.push(row);
                }
                Ok(rows.into())
            }
            "preset" => {
                let mut cursor = self.data.cursor.clone();
                cursor.ranges.clear();
                let mut camera = self.data.camera.clone();
                camera.layouts.clear();
                let mut canvas = self.data.canvas.clone();
                canvas.highlights.clear();
                canvas.annotations.clear();
                canvas.reactions.clear();
                canvas.captions.clear();
                let mut audio = self.data.audio.clone();
                audio.ranges.clear();
                audio.music.clear();
                Ok(
                    json!({"canvas":canvas,"cursor":cursor,"camera":camera,"audio":audio,"zoom_settings":self.data.zoom_settings,"export":self.data.export_settings}),
                )
            }
            "audio_automation" => Ok(serde_json::to_value(&self.data.audio.ranges)?),
            "map_audio_ranges" => self.map_audio_ranges(query),
            "annotations" => Ok(serde_json::to_value(&self.data.canvas.annotations)?),
            "reactions" => Ok(serde_json::to_value(&self.data.canvas.reactions)?),
            "captions" => Ok(serde_json::to_value(&self.data.canvas.captions)?),
            "music_library" => Ok(
                json!([{"id":"calm","name":"Calm","duration_ns":8_000_000_000_i64},{"id":"bright","name":"Bright","duration_ns":8_000_000_000_i64}]),
            ),
            "motion_at" => {
                let tl = query["tl_ns"]
                    .as_i64()
                    .ok_or_else(|| Error::new(1, "Missing integer tl_ns"))?;
                Ok(serde_json::to_value(self.frame_motion(tl)?)?)
            }
            "music" => Ok(serde_json::to_value(&self.data.audio.music)?),
            "audio_overlays" => self.audio_overlays(),
            "render_options" => self.render_options(None),
            "effects_at" | "render_options_at" => {
                let tl = query["tl_ns"]
                    .as_i64()
                    .ok_or_else(|| Error::new(1, "Missing integer tl_ns"))?;
                if query["q"] == "effects_at" {
                    self.effects_at(tl)
                } else {
                    self.frame(tl)?;
                    self.render_options(Some(tl))
                }
            }
            "layers_at" => {
                let tl = query
                    .get("tl_ns")
                    .and_then(Value::as_i64)
                    .ok_or_else(|| Error::new(1, "Missing integer tl_ns"))?;
                self.layers_at(tl)
            }
            "zooms" => Ok(serde_json::to_value(&self.data.zooms)?),
            "layouts" => Ok(serde_json::to_value(&self.data.camera.layouts)?),
            "session" => Ok(serde_json::to_value(&self.session)?),
            "project" => Ok(serde_json::to_value(&self.data)?),
            "media" | "assets" => Ok(serde_json::to_value(&self.data.media)?),
            "audio_ranges" => {
                let mut rows = Vec::new();
                for (clip_index, c) in self.data.timeline.clips.iter().enumerate() {
                    for (track, gain_db, muted) in [
                        (
                            "mic",
                            self.data.audio.mic_gain_db,
                            self.data.audio.mic_muted,
                        ),
                        (
                            "system_audio",
                            self.data.audio.system_gain_db,
                            self.data.audio.system_muted,
                        ),
                    ] {
                        for (i, s) in self.session.segments.iter().enumerate() {
                            let Some(path) = s.files.get(track) else {
                                continue;
                            };
                            let offset = s.track_start_ns.get(track).copied().unwrap_or(0);
                            let a = c.src_start_ns.max(s.src_start_ns + offset);
                            let b = c.src_end_ns.min(s.src_start_ns + s.duration_ns);
                            if b > a {
                                let tl_a = time::source_boundary_to_timeline(
                                    &self.data.timeline.clips,
                                    clip_index,
                                    a,
                                )
                                .unwrap();
                                let tl_b = time::source_boundary_to_timeline(
                                    &self.data.timeline.clips,
                                    clip_index,
                                    b,
                                )
                                .unwrap();
                                let mut boundaries = vec![tl_a, tl_b];
                                for r in self.data.audio.ranges.iter().filter(|r| r.track == track)
                                {
                                    for t in [r.tl_start_ns, r.tl_end_ns] {
                                        if t > tl_a && t < tl_b {
                                            boundaries.push(t);
                                        }
                                    }
                                }
                                boundaries.sort();
                                boundaries.dedup();
                                for times in boundaries.windows(2) {
                                    let x = if times[0] == tl_a {
                                        a
                                    } else {
                                        time::timeline_boundary_to_source(
                                            &self.data.timeline.clips,
                                            clip_index,
                                            times[0],
                                        )
                                        .unwrap()
                                        .clamp(a, b)
                                    };
                                    let y = if times[1] == tl_b {
                                        b
                                    } else {
                                        time::timeline_boundary_to_source(
                                            &self.data.timeline.clips,
                                            clip_index,
                                            times[1],
                                        )
                                        .unwrap()
                                        .clamp(a, b)
                                    };
                                    let gain_start = self.audio_gain(track, times[0]);
                                    let gain_end = self.audio_gain(track, times[1] - 1);
                                    rows.push(json!({"clip_id":c.id,"track":track,"segment":i,"path":format!("recording/{path}"),"src_start_ns":x,"src_end_ns":y,"file_start_ns":x-s.src_start_ns-offset,"file_end_ns":y-s.src_start_ns-offset,"tl_start_ns":times[0],"tl_end_ns":times[1],"speed":c.speed,"gain":gain_start,"gain_start":gain_start,"gain_end":gain_end,"base_gain_db":gain_db,"muted":muted}));
                                }
                            }
                        }
                    }
                }
                Ok(rows.into())
            }
            "clicks" | "cursor_clicks" | "events" | "key_events" => {
                let all = query["q"] == "events";
                let mut rows = Vec::new();
                for (i, _) in self.data.timeline.clips.iter().enumerate() {
                    for (seg, events) in self.session.segments.iter().zip(&self.events) {
                        for e in events {
                            if !all
                                && e.kind
                                    != if query["q"] == "key_events" {
                                        "key"
                                    } else {
                                        "down"
                                    }
                            {
                                continue;
                            }
                            let src = seg.src_start_ns + e.t;
                            if let Some(tl) =
                                time::source_to_timeline(&self.data.timeline.clips, i, src)
                            {
                                let mut row = serde_json::to_value(e)?;
                                row["src_ns"] = src.into();
                                row["tl_ns"] = tl.into();
                                row["segment"] = seg.index.into();
                                rows.push(row);
                            }
                        }
                    }
                }
                rows.sort_by_key(|r| r["tl_ns"].as_i64());
                Ok(rows.into())
            }
            name => Err(Error::new(1, format!("Unsupported query: {name}"))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{model::Clip, project::tests::Fixture};
    #[test]
    fn file_audio_ranges_map_through_speed_cut_offsets_and_repeated_clips() {
        let fixture = Fixture::new();
        let mut p = Project::create(&fixture.0).unwrap();
        p.data.autosave = false;
        p.apply(&json!({"op":"split","at_tl_ns":2_000_000_000}))
            .unwrap();
        p.apply(&json!({"op":"set_speed","clip_id":p.data.timeline.clips[0].id,"speed":2}))
            .unwrap();
        let request = json!({"q":"map_audio_ranges","track":"system_audio","path":"recording/seg-000/system.m4a",
            "ranges":[{"file_start_ns":500_000_000,"file_end_ns":1_200_000_000},
                {"file_start_ns":1_000_000_000,"file_end_ns":2_500_000_000_i64}]});
        assert_eq!(
            p.query(&request).unwrap(),
            json!([{"tl_start_ns":250_000_000,"tl_end_ns":1_500_000_000}])
        );
        let before = p.data.clone();
        let history = p.undo.len();
        assert_eq!(p.query(&request).unwrap(), p.query(&request).unwrap());
        assert_eq!(p.data, before);
        assert_eq!(p.undo.len(), history);
        let mut second = request.clone();
        second["path"] = json!("recording/seg-001/system.m4a");
        second["ranges"] = json!([{"file_start_ns":100_000_000,"file_end_ns":900_000_000}]);
        assert_eq!(
            p.query(&second).unwrap(),
            json!([{"tl_start_ns":2_100_000_000,"tl_end_ns":2_900_000_000_i64}])
        );
        p.apply(&json!({"op":"delete_range","tl_start_ns":600_000_000,"tl_end_ns":1_200_000_000}))
            .unwrap();
        assert_eq!(
            p.query(&request).unwrap(),
            json!([{"tl_start_ns":250_000_000,"tl_end_ns":900_000_000}])
        );
        assert_eq!(
            p.query(&second).unwrap(),
            json!([{"tl_start_ns":1_500_000_000,"tl_end_ns":2_300_000_000_i64}])
        );
        p.session.segments[0]
            .track_start_ns
            .insert("system_audio".into(), 100_000_000);
        let offset = json!({"q":"map_audio_ranges","track":"system_audio","path":"recording/seg-000/system.m4a",
            "ranges":[{"file_start_ns":50_000_000,"file_end_ns":250_000_000}]});
        assert_eq!(
            p.query(&offset).unwrap(),
            json!([{"tl_start_ns":75_000_000,"tl_end_ns":175_000_000}])
        );
        let mut repeated = p.data.timeline.clips[0].clone();
        repeated.id = "repeated".into();
        let start = time::duration(&p.data.timeline.clips);
        p.data.timeline.clips.push(repeated);
        assert_eq!(
            p.query(&offset).unwrap(),
            json!([
            {"tl_start_ns":75_000_000,"tl_end_ns":175_000_000},
            {"tl_start_ns":start+75_000_000,"tl_end_ns":start+175_000_000}])
        );
        let mut invalid = offset.clone();
        invalid["track"] = json!("screen");
        assert!(p.query(&invalid).is_err());
        invalid = offset.clone();
        invalid["path"] = json!("recording/missing.m4a");
        assert!(p.query(&invalid).is_err());
        invalid = offset.clone();
        invalid["ranges"][0]["file_start_ns"] = json!(-1);
        assert!(p.query(&invalid).is_err());
        invalid = offset.clone();
        invalid["ranges"] = json!([]);
        assert_eq!(p.query(&invalid).unwrap(), json!([]));
        invalid = offset.clone();
        invalid["ranges"] = json!([{"file_start_ns":i64::MAX-1,"file_end_ns":i64::MAX}]);
        assert_eq!(p.query(&invalid).unwrap(), json!([]));
    }
    #[test]
    fn file_audio_mapping_keeps_large_int64_offsets_and_rounds_fractional_rates_once() {
        let fixture = Fixture::new();
        let mut p = Project::create(&fixture.0).unwrap();
        let length = (1_i64 << 53) + 37;
        p.session.segments.truncate(1);
        p.session.segments[0].duration_ns = length + 1_000;
        p.data.timeline.clips = vec![Clip {
            id: "long".into(),
            src_start_ns: 0,
            src_end_ns: length + 1_000,
            speed: 1.3,
        }];
        let result=p.query(&json!({"q":"map_audio_ranges","track":"system_audio","path":"recording/seg-000/system.m4a",
            "ranges":[{"file_start_ns":length+9,"file_end_ns":length+61}]})).unwrap();
        let rounded = |n: i64| ((n as i128 * 10 + 6) / 13) as i64;
        assert_eq!(
            result,
            json!([{"tl_start_ns":rounded(length+9),"tl_end_ns":rounded(length+61)}])
        );
    }
    #[test]
    fn clicks_map_across_segments_speed_cuts_and_undo() {
        let fixture = Fixture::new();
        let mut p = Project::create(&fixture.0).unwrap();
        let times = |p: &Project| {
            p.query(&json!({"q":"clicks"}))
                .unwrap()
                .as_array()
                .unwrap()
                .iter()
                .map(|r| r["tl_ns"].as_i64().unwrap())
                .collect::<Vec<_>>()
        };
        assert_eq!(times(&p), vec![1_700_000_000, 3_500_000_000]);
        p.apply(&json!({"op":"split","at_tl_ns":2_000_000_000}))
            .unwrap();
        p.apply(&json!({"op":"set_speed","clip_id":p.data.timeline.clips[0].id,"speed":2}))
            .unwrap();
        assert_eq!(times(&p), vec![850_000_000, 2_500_000_000]);
        p.apply(&json!({"op":"delete_range","tl_start_ns":800_000_000,"tl_end_ns":1_000_000_000}))
            .unwrap();
        assert_eq!(times(&p), vec![2_300_000_000]);
        let click = p.query(&json!({"q":"clicks"})).unwrap()[0].clone();
        assert_eq!(click["src_ns"], json!(3_500_000_000_i64));
        assert_eq!(click["segment"], json!(1));
        assert_eq!(p.frame(2_300_000_000).unwrap().screen.src_ns, 3_500_000_000);
        p.undo().unwrap();
        p.undo().unwrap();
        p.undo().unwrap();
        assert_eq!(times(&p), vec![1_700_000_000, 3_500_000_000]);
        // A click on a split boundary belongs to one half-open clip, not both.
        p.apply(&json!({"op":"split","at_tl_ns":1_700_000_000}))
            .unwrap();
        assert_eq!(times(&p), vec![1_700_000_000, 3_500_000_000]);
    }
    #[test]
    fn clip_and_audio_queries_keep_exact_fractional_boundaries() {
        let fixture = Fixture::new();
        let mut p = Project::create(&fixture.0).unwrap();
        // Long synthetic edit clocks expose Double's loss of integer precision.
        // The independent oracle uses the decimal rate 1.3 = 13/10.
        let length = 1_000_000_000_000_001_i64;
        p.data.timeline.clips = (0..40)
            .map(|i| Clip {
                id: format!("clip-{i}"),
                src_start_ns: i * length,
                src_end_ns: (i + 1) * length,
                speed: 1.3,
            })
            .collect();
        p.session.segments.truncate(1);
        p.session.segments[0].duration_ns = length * 40;
        p.session.segments[0]
            .track_start_ns
            .insert("system_audio".into(), 0);
        let oracle = |i: i64| ((i as i128 * length as i128 * 10 + 6) / 13) as i64;
        let clips = p.query(&json!({"q":"clips"})).unwrap();
        let audio = p.query(&json!({"q":"audio_ranges"})).unwrap();
        let audio: Vec<_> = audio
            .as_array()
            .unwrap()
            .iter()
            .filter(|r| r["track"] == "system_audio")
            .collect();
        assert_eq!(audio.len(), 40);
        for i in 0..40 {
            assert_eq!(clips[i]["tl_start_ns"], json!(oracle(i as i64)));
            assert_eq!(clips[i]["tl_end_ns"], json!(oracle(i as i64 + 1)));
            assert_eq!(audio[i]["tl_start_ns"], clips[i]["tl_start_ns"]);
            assert_eq!(audio[i]["tl_end_ns"], clips[i]["tl_end_ns"]);
            assert_eq!(audio[i]["src_start_ns"], json!(i as i64 * length));
            assert_eq!(audio[i]["src_end_ns"], json!((i as i64 + 1) * length));
        }
    }
}
