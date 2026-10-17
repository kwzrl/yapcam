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
            .ok_or_else(|| Error::new(1, "Audio path must be package-relative"))?;
        if !self.session.segments.iter().any(|s| {
            s.files
                .get(track)
                .is_some_and(|p| self.matches_audio_path(track, p, path))
        }) {
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
                if s.files
                    .get(track)
                    .is_none_or(|p| !self.matches_audio_path(track, p, path))
                {
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
    fn speech_enhancement_plan(&self) -> Result<Value> {
        let rows = crate::microphone::query(self)?;
        let mut seen = std::collections::HashSet::new();
        let media: Vec<_> = rows
            .as_array()
            .unwrap()
            .iter()
            .filter(|row| seen.insert(row["path"].as_str().unwrap()))
            .collect();
        Ok(
            json!({"enabled":self.data.audio.speech_enhancement,"settings":self.data.audio.speech_enhancement_settings,"media":media,"mic_preset":self.data.audio.mic_preset,"stereo_mic":self.data.audio.stereo_mic}),
        )
    }
    fn matches_audio_path(&self, track: &str, file: &str, path: &str) -> bool {
        let original = format!("recording/{file}");
        original == path
            || (track == "mic" && crate::microphone::effective(&self.data, &original).0 == path)
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
            "preset" => crate::preset::export(&self.data),
            "caption_defaults" => Ok(serde_json::to_value(crate::captions::factory_style(
                self.data.defaults_revision,
            ))?),
            "autosave_policy" => {
                Ok(json!({"enabled":self.data.autosave,"delay_ns":30_000_000_000_i64}))
            }
            "capabilities" => Ok(serde_json::to_value(self.capabilities())?),
            "insertion_styles" => Ok(serde_json::to_value(&self.data.insertion_styles)?),
            "history" => Ok(
                json!({"undo_steps":self.undo.len(),"redo_steps":self.redo.len(),"limit":1000,"coalesce_ms":100}),
            ),
            "timeline_constraints" => Ok(crate::editing::constraints()),
            "zoom_lens_at" => crate::zoom_lens::query(
                self,
                query["tl_ns"]
                    .as_i64()
                    .ok_or_else(|| Error::new(1, "Missing integer tl_ns"))?,
            ),
            "camera_layout_at" => crate::camera_layout::query(
                self,
                Some(
                    query["tl_ns"]
                        .as_i64()
                        .ok_or_else(|| Error::new(1, "Missing integer tl_ns"))?,
                ),
            ),
            "camera_style" => Ok(serde_json::to_value(&self.data.camera.style)?),
            "camera_style_library" => Ok(crate::camera_style::library()),
            "markers" => Ok(crate::markers::query(self)),
            "typing_suggestions" => Ok(crate::auto::typing_suggestions(self)),
            "speech_enhancement" => self.speech_enhancement_plan(),
            "microphone_media" => crate::microphone::query(self),
            "audio_automation" => Ok(serde_json::to_value(&self.data.audio.ranges)?),
            "map_audio_ranges" => self.map_audio_ranges(query),
            "annotations" => Ok(serde_json::to_value(&self.data.canvas.annotations)?),
            "reactions" => Ok(serde_json::to_value(&self.data.canvas.reactions)?),
            "captions" => Ok(serde_json::to_value(&self.data.canvas.captions)?),
            "caption_options" => Ok(crate::captions::options()),
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
            "mask_effects_at" => self.mask_effects_at(
                query["tl_ns"]
                    .as_i64()
                    .ok_or_else(|| Error::new(1, "Missing integer tl_ns"))?,
            ),
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
            "privacy_masks_at" => self.privacy_masks_at(
                query["tl_ns"]
                    .as_i64()
                    .ok_or_else(|| Error::new(1, "Missing integer tl_ns"))?,
            ),
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
            "cursor_library" => Ok(crate::cursor_catalog::query()),
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
                        let clip_gain = if track == "mic" {
                            c.settings.mic_gain
                        } else {
                            c.settings.system_gain
                        };
                        let muted = muted || clip_gain == 0.0;
                        let gain_db = gain_db
                            + if clip_gain > 0.0 {
                                20.0 * clip_gain.log10()
                            } else {
                                0.0
                            };
                        for (i, s) in self.session.segments.iter().enumerate() {
                            let Some(path) = s.files.get(track) else {
                                continue;
                            };
                            let original_path = format!("recording/{path}");
                            let path = if track == "mic" {
                                crate::microphone::effective(&self.data, &original_path).0
                            } else {
                                &original_path
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
                                    // Rounded public times may lie just across an exact
                                    // fractional clip edge. The row owns this clip;
                                    // only automation is evaluated at the endpoint time.
                                    let gain_start =
                                        self.audio_gain_for_clip(track, times[0], Some(clip_index));
                                    let gain_end = self.audio_gain_for_clip(
                                        track,
                                        times[1] - 1,
                                        Some(clip_index),
                                    );
                                    rows.push(json!({"clip_id":c.id,"track":track,"segment":i,"path":path,"src_start_ns":x,"src_end_ns":y,"file_start_ns":x-s.src_start_ns-offset,"file_end_ns":y-s.src_start_ns-offset,"tl_start_ns":times[0],"tl_end_ns":times[1],"speed":c.speed,"gain":gain_start,"gain_start":gain_start,"gain_end":gain_end,"base_gain_db":gain_db,"muted":muted}));
                                }
                            }
                        }
                    }
                }
                Ok(rows.into())
            }
            "key_overlay_shortcuts" => Ok(self
                .key_overlay_index
                .shortcut_catalog(&self.data.cursor.key_overlay.hidden_shortcuts)),
            "key_events" => {
                let mut rows = Vec::new();
                for (segment, event, src, tl) in self.key_overlay_index.events() {
                    let mut row = serde_json::to_value(&self.events[segment][event])?;
                    row["src_ns"] = src.into();
                    row["tl_ns"] = tl.into();
                    row["segment"] = (segment as u32).into();
                    rows.push(row);
                }
                Ok(rows.into())
            }
            "clicks" | "cursor_clicks" | "events" => {
                let all = query["q"] == "events";
                let mut rows = Vec::new();
                for (i, _) in self.data.timeline.clips.iter().enumerate() {
                    for (seg, events) in self.session.segments.iter().zip(&self.events) {
                        for e in events {
                            if !all && e.kind != "down" {
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
    fn fractional_audio_endpoints_use_the_row_clip_for_both_mute_orders_and_automation() {
        let fixture = Fixture::new();
        let mut base = Project::create(&fixture.0).unwrap();
        base.data.autosave = false;
        // Exercise both track gain branches with synthetic, already registered media.
        for segment in &mut base.session.segments {
            segment
                .files
                .insert("mic".into(), segment.files["system_audio"].clone());
        }
        base.apply(&json!({"op":"delete_range","tl_start_ns":4_000_000_000_i64,"tl_end_ns":5_000_000_000_i64})).unwrap();
        base.apply(&json!({"op":"split","at_tl_ns":1_000_000_000}))
            .unwrap();
        for first_speed in [3.0, 1.2, 0.75, 1.6] {
            for second_speed in [1.0, 3.0, 1.2, 0.75, 1.6] {
                for muted_first in [false, true] {
                    let mut p = base.clone();
                    for i in 0..2 {
                        let id = p.data.timeline.clips[i].id.clone();
                        p.apply(&json!({"op":"set_speed","clip_id":id,"speed":if i==0 {first_speed} else {second_speed}})).unwrap();
                        let gain = if (i == 0) == muted_first { 0.0 } else { 1.0 };
                        p.apply(&json!({"op":"set_clip_settings","clip_id":id,"patch":{"mic_gain":gain,"system_gain":gain}})).unwrap();
                    }
                    for track in ["mic", "system_audio"] {
                        p.apply(&json!({"op":"set","path":format!("audio.{}_gain_db",if track=="mic" {"mic"} else {"system"}),"value":0})).unwrap();
                    }
                    for automation in [false, true] {
                        if automation {
                            let duration = time::duration(&p.data.timeline.clips);
                            p.apply(&json!({"op":"set","path":"audio.ranges","value":[
                                {"id":"mic-ramp","track":"mic","tl_start_ns":0,"tl_end_ns":duration,"start_gain_db":-12,"end_gain_db":0},
                                {"id":"system-ramp","track":"system_audio","tl_start_ns":0,"tl_end_ns":duration,"start_gain_db":-12,"end_gain_db":0}]})).unwrap();
                        }
                        let rows = p.query(&json!({"q":"audio_ranges"})).unwrap();
                        for row in rows.as_array().unwrap() {
                            let i = p
                                .data
                                .timeline
                                .clips
                                .iter()
                                .position(|c| row["clip_id"] == c.id)
                                .unwrap();
                            let muted = (i == 0) == muted_first;
                            assert_eq!(row["muted"], muted);
                            for (key, t) in [
                                ("gain_start", row["tl_start_ns"].as_i64().unwrap()),
                                ("gain_end", row["tl_end_ns"].as_i64().unwrap() - 1),
                            ] {
                                let db = if automation {
                                    -12.0
                                        + 12.0 * t as f64
                                            / time::duration(&p.data.timeline.clips) as f64
                                } else {
                                    0.0
                                };
                                let expected = if muted { 0.0 } else { 10_f64.powf(db / 20.0) };
                                assert!(
                                    (row[key].as_f64().unwrap() - expected).abs() < 1e-6,
                                    "speeds {first_speed}/{second_speed}, row {row}"
                                );
                            }
                            assert_eq!(row["gain"], row["gain_start"]);
                        }
                        assert!(!rows.as_array().unwrap().is_empty());
                    }
                }
            }
        }
    }
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
            settings: Default::default(),
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
                settings: Default::default(),
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

#[cfg(test)]
mod speech_enhancement_tests {
    use super::*;
    use crate::{
        model::*,
        project::{fingerprint, tests::Fixture},
    };
    #[test]
    fn microphone_presets_are_explicit_owned_recipes_and_keep_legacy_dsp() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        let q = json!({"q":"speech_enhancement"});
        assert_eq!(p.query(&q).unwrap()["mic_preset"], "voice");
        assert_eq!(p.query(&q).unwrap()["stereo_mic"], false);
        let before = p.data.clone();
        p.apply(&json!({"op":"set","path":"audio.mic_preset","value":"noise_reduction"}))
            .unwrap();
        assert!(p.data.audio.speech_enhancement);
        assert_eq!(
            p.data.audio.speech_enhancement_settings.compressor_ratio,
            1.0
        );
        assert!(!p.data.audio.speech_enhancement_settings.normalize_loudness);
        p.undo().unwrap();
        assert_eq!(p.data, before);
        p.redo().unwrap();
        p.apply(&json!({"op":"batch","commands":[{"op":"set","path":"audio.mic_preset","value":"podcast"},{"op":"set","path":"audio.stereo_mic","value":true}]})).unwrap();
        assert_eq!(p.query(&q).unwrap()["stereo_mic"], true);
        assert_eq!(
            p.data.audio.speech_enhancement_settings.compressor_ratio,
            4.0
        );
        assert_eq!(
            p.data.audio.speech_enhancement_settings.noise_reduction_db,
            12.0
        );
        assert!(p.data.audio.speech_enhancement_settings.normalize_loudness);
        let snapshot = p.clone();
        p.save(&f.0).unwrap();
        assert_eq!(
            p.query(&q).unwrap(),
            Project::open(&f.0).unwrap().query(&q).unwrap()
        );
        p.apply(&json!({"op":"set","path":"audio.mic_preset","value":"voice"}))
            .unwrap();
        assert!(!p.data.audio.speech_enhancement);
        assert!(snapshot.data.audio.speech_enhancement);
        let before = p.data.clone();
        let history = p.undo.len();
        for command in [
            json!({"op":"set","path":"audio.mic_preset","value":"unknown"}),
            json!({"op":"set","path":"audio.stereo_mic","value":1}),
        ] {
            assert!(p.apply(&command).is_err());
            assert_eq!(p.data, before);
            assert_eq!(p.undo.len(), history);
        }
        let mut old = serde_json::to_value(&snapshot.data).unwrap();
        old["audio"].as_object_mut().unwrap().remove("mic_preset");
        old["audio"].as_object_mut().unwrap().remove("stereo_mic");
        old["audio"]["speech_enhancement_settings"]["high_pass_hz"] = 123.0.into();
        std::fs::write(f.0.join("project.json"), serde_json::to_vec(&old).unwrap()).unwrap();
        // Remove the current edit journal, as this fixture models a standalone old save.
        std::fs::remove_file(f.0.join("autosave/project.json")).unwrap();
        let reopened = Project::open(&f.0).unwrap();
        assert_eq!(reopened.data.audio.mic_preset, "voice");
        assert!(!reopened.data.audio.stereo_mic);
        assert!(reopened.data.audio.speech_enhancement);
        assert_eq!(
            reopened.data.audio.speech_enhancement_settings.high_pass_hz,
            123.0
        );
        assert_eq!(
            reopened
                .data
                .audio
                .speech_enhancement_settings
                .compressor_ratio,
            4.0
        );
    }
    #[test]
    fn speech_settings_paths_defaults_validation_history_preset_and_reopen() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        assert!(
            !p.query(&json!({"q":"speech_enhancement"})).unwrap()["enabled"]
                .as_bool()
                .unwrap()
        );
        let settings = [
            ("high_pass_hz", json!(100)),
            ("noise_threshold_db", json!(-40)),
            ("noise_reduction_db", json!(25)),
            ("compressor_threshold_db", json!(-20)),
            ("compressor_ratio", json!(4)),
            ("target_lufs", json!(-18)),
            ("peak_ceiling_dbfs", json!(-2)),
            ("normalize_loudness", json!(false)),
        ];
        p.apply(&json!({"op":"set","path":"audio.speech_enhancement","value":true}))
            .unwrap();
        for (key, value) in settings {
            p.apply(&json!({"op":"set","path":format!("audio.speech_enhancement_settings.{key}"),"value":value})).unwrap();
        }
        let plan = p.query(&json!({"q":"speech_enhancement"})).unwrap();
        assert_eq!(plan["settings"]["high_pass_hz"], json!(100.0));
        let before = p.data.clone();
        let history = p.undo.len();
        for (key, value) in [
            ("high_pass_hz", json!(0)),
            ("noise_threshold_db", json!(0)),
            ("noise_reduction_db", json!(61)),
            ("compressor_threshold_db", json!(-61)),
            ("compressor_ratio", json!(11)),
            ("target_lufs", json!(-40)),
            ("peak_ceiling_dbfs", json!(1)),
            ("normalize_loudness", json!(3)),
        ] {
            assert!(p.apply(&json!({"op":"set","path":format!("audio.speech_enhancement_settings.{key}"),"value":value})).is_err());
            assert_eq!(p.data, before);
            assert_eq!(p.undo.len(), history);
        }
        assert!(p
            .apply(&json!({"op":"set","path":"audio.speech_enhancement","value":1}))
            .is_err());
        p.save(&f.0).unwrap();
        assert_eq!(
            Project::open(&f.0)
                .unwrap()
                .query(&json!({"q":"speech_enhancement"}))
                .unwrap(),
            plan
        );
        p.undo().unwrap();
        assert!(p.data.audio.speech_enhancement_settings.normalize_loudness);
        p.redo().unwrap();
        assert_eq!(p.data, before);
        let preset = p.query(&json!({"q":"preset"})).unwrap();
        assert_eq!(preset["audio"]["speech_enhancement"], json!(true));
        let snapshot = p.clone();
        p.apply(&json!({"op":"set","path":"audio.speech_enhancement","value":false}))
            .unwrap();
        assert!(
            snapshot.query(&json!({"q":"speech_enhancement"})).unwrap()["enabled"]
                .as_bool()
                .unwrap()
        );
        assert_eq!(
            crate::allocation_test::count(|| {
                p.frame(0).unwrap();
                p.frame_extras(0).unwrap();
                p.frame_motion(0).unwrap();
            }),
            0
        );
    }
    #[test]
    fn microphone_plan_respects_cuts_track_starts_repeats_and_empty_tracks() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        let mut mic = fingerprint(&f.0.join("recording/seg-000/system.m4a")).unwrap();
        mic.path = "recording/seg-000/system.m4a".into();
        p.data.media.retain(|m| m.path != mic.path);
        p.data.media.push(mic);
        p.session.tracks.mic = Some(AudioTrack {
            device_name: Some("fixture".into()),
            sample_rate: 48000,
            channels: 1,
        });
        p.session.segments[0]
            .files
            .insert("mic".into(), "seg-000/system.m4a".into());
        p.session.segments[0]
            .track_start_ns
            .insert("mic".into(), 1_000_000_000);
        let query = json!({"q":"speech_enhancement"});
        assert_eq!(
            p.query(&query).unwrap()["media"].as_array().unwrap().len(),
            1
        );
        let mut repeated = p.data.timeline.clips[0].clone();
        repeated.id = "repeat".into();
        p.data.timeline.clips.push(repeated);
        assert_eq!(
            p.query(&query).unwrap()["media"].as_array().unwrap().len(),
            1
        );
        p.data.timeline.clips = vec![Clip {
            id: "kept".into(),
            src_start_ns: 0,
            src_end_ns: 900_000_000,
            speed: 2.0,
            settings: Default::default(),
        }];
        assert_eq!(p.query(&query).unwrap()["media"], json!([]));
        p.data.timeline.clips[0].src_start_ns = 1_000_000_000;
        p.data.timeline.clips[0].src_end_ns = 2_000_000_000;
        assert_eq!(
            p.query(&query).unwrap()["media"].as_array().unwrap().len(),
            1
        );
        let no_frames = p.session.segments[0].duration_ns;
        p.session.segments[0]
            .track_start_ns
            .insert("mic".into(), no_frames);
        assert_eq!(p.query(&query).unwrap()["media"], json!([]));
        let raw:ProjectData=serde_json::from_value(json!({"schema_version":1,"id":"legacy","created_at":"","modified_at":"","recording":"recording/session.json","timeline":{"clips":[]}})).unwrap();
        assert!(!raw.audio.speech_enhancement);
        assert_eq!(raw.audio.speech_enhancement_settings.high_pass_hz, 90.0);
    }
}
