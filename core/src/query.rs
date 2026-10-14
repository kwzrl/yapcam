//! Structured UI queries. This is a cold path and may allocate.
use crate::{
    project::{Error, Project, Result},
    time,
};
use serde_json::{json, Value};
impl Project {
    pub fn query(&self, query: &Value) -> Result<Value> {
        match query
            .get("q")
            .and_then(Value::as_str)
            .ok_or_else(|| Error::new(1, "Missing query q"))?
        {
            "duration" => Ok(json!({"duration_ns":time::duration(&self.data.timeline.clips)})),
            "clips" => {
                let mut start = 0.0;
                let mut rows = Vec::new();
                for c in &self.data.timeline.clips {
                    let end = start + time::clip_duration(c);
                    let mut row = serde_json::to_value(c)?;
                    row["tl_start_ns"] = (start.round() as i64).into();
                    row["tl_end_ns"] = (end.round() as i64).into();
                    rows.push(row);
                    start = end;
                }
                Ok(rows.into())
            }
            "preset" => {
                let mut cursor = self.data.cursor.clone();
                cursor.ranges.clear();
                let mut camera = self.data.camera.clone();
                camera.layouts.clear();
                let mut audio = self.data.audio.clone();
                audio.ranges.clear();
                Ok(
                    json!({"canvas":self.data.canvas,"cursor":cursor,"camera":camera,"audio":audio,"zoom_settings":self.data.zoom_settings,"export":self.data.export_settings}),
                )
            }
            "audio_automation" => Ok(serde_json::to_value(&self.data.audio.ranges)?),
            "zooms" => Ok(serde_json::to_value(&self.data.zooms)?),
            "layouts" => Ok(serde_json::to_value(&self.data.camera.layouts)?),
            "session" => Ok(serde_json::to_value(&self.session)?),
            "project" => Ok(serde_json::to_value(&self.data)?),
            "media" | "assets" => Ok(serde_json::to_value(&self.data.media)?),
            "audio_ranges" => {
                let mut rows = Vec::new();
                let mut start = 0.0;
                for c in &self.data.timeline.clips {
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
                                let tl_a =
                                    (start + (a - c.src_start_ns) as f64 / c.speed).round() as i64;
                                let tl_b =
                                    (start + (b - c.src_start_ns) as f64 / c.speed).round() as i64;
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
                                    let x = (c.src_start_ns
                                        + ((times[0] as f64 - start) * c.speed).round() as i64)
                                        .clamp(a, b);
                                    let y = (c.src_start_ns
                                        + ((times[1] as f64 - start) * c.speed).round() as i64)
                                        .clamp(a, b);
                                    let gain_start = self.audio_gain(track, times[0]);
                                    let gain_end = self.audio_gain(track, times[1] - 1);
                                    rows.push(json!({"clip_id":c.id,"track":track,"segment":i,"path":format!("recording/{path}"),"src_start_ns":x,"src_end_ns":y,"file_start_ns":x-s.src_start_ns-offset,"file_end_ns":y-s.src_start_ns-offset,"tl_start_ns":times[0],"tl_end_ns":times[1],"speed":c.speed,"gain":gain_start,"gain_start":gain_start,"gain_end":gain_end,"base_gain_db":gain_db,"muted":muted}));
                                }
                            }
                        }
                    }
                    start += time::clip_duration(c);
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
