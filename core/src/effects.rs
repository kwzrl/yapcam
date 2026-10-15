//! Additive project effects: cold editing and pure per-timeline evaluation.
use crate::{
    commands::ChangeSet,
    model::*,
    project::{unique_id, Error, Project, Result},
    time,
};
use serde_json::{json, Value};

fn bad(message: &str) -> Error {
    Error::new(1, message)
}
fn range(a: i64, b: i64) -> bool {
    a >= 0 && b > a
}
fn rect(r: &[f64; 4]) -> bool {
    r.iter().all(|v| v.is_finite())
        && r[0] >= 0.0
        && r[1] >= 0.0
        && r[2] > 0.0
        && r[3] > 0.0
        && r[0] + r[2] <= 1.0
        && r[1] + r[3] <= 1.0
}
fn color(c: &[f32; 4]) -> bool {
    c.iter().all(|v| (0.0..=1.0).contains(v))
}
fn style(s: &TextStyle) -> bool {
    (1.0..=1024.0).contains(&s.font_size)
        && color(&s.color)
        && color(&s.background)
        && (0.0..=16384.0).contains(&s.radius)
        && (0.0..=1.0).contains(&s.opacity)
}
fn id(id: &str) -> bool {
    !id.is_empty() && id != "canvas-fade" && !id.starts_with("core:")
}
pub fn validate(p: &ProjectData) -> Result<()> {
    for records in [
        &p.canvas.annotations,
        &p.canvas.reactions,
        &p.canvas.captions,
    ] {
        let mut ids = std::collections::HashSet::new();
        for r in records {
            if !id(&r.id)
                || !ids.insert(&r.id)
                || !range(r.tl_start_ns, r.tl_end_ns)
                || r.text.trim().is_empty()
                || !rect(&r.rect)
                || !matches!(r.space.as_str(), "source" | "canvas")
                || !style(&r.style)
            {
                return Err(bad("Invalid text record or duplicate id"));
            }
        }
    }
    let k = &p.cursor.key_overlay;
    if k.duration_ns <= 0 || !rect(&k.rect) || !style(&k.style) {
        return Err(bad("Invalid key overlay"));
    }
    let click = &p.audio.click_sound;
    if !matches!(click.variant.as_str(), "soft" | "crisp")
        || !(-96.0..=24.0).contains(&click.gain_db)
    {
        return Err(bad("Invalid click sound"));
    }
    let mut ids = std::collections::HashSet::new();
    for m in &p.audio.music {
        if !id(&m.id)
            || !ids.insert(&m.id)
            || !range(m.tl_start_ns, m.tl_end_ns)
            || !matches!(m.source.as_str(), "file" | "calm" | "bright")
            || !(-96.0..=24.0).contains(&m.gain_db)
            || m.file_start_ns < 0
            || m.file_start_ns >= music_duration(m)
            || m.fade_in_ns < 0
            || m.fade_out_ns < 0
            || !(-96.0..=0.0).contains(&m.ducking.gain_db)
            || m.ducking.attack_ns < 0
            || m.ducking.release_ns < 0
            || m.ducking
                .ranges
                .iter()
                .any(|r| !range(r.tl_start_ns, r.tl_end_ns))
        {
            return Err(bad("Invalid music track"));
        }
        if m.source == "file"
            && (!p.media.iter().any(|a| a.path == m.path) || m.file_duration_ns <= 0)
        {
            return Err(bad(
                "Music must reference registered media with positive duration",
            ));
        }
        if m.source != "file" && !m.path.is_empty() {
            return Err(bad("Procedural music cannot reference a file"));
        }
    }
    if p.camera.layouts.iter().any(|l| {
        l.camera_shadow_radius
            .is_some_and(|v| !(0.0..=16384.0).contains(&v))
    }) {
        return Err(bad("Invalid layout shadow radius"));
    }
    Ok(())
}
/// All collection mutations stage JSON, then deserialize strictly and validate as
/// part of the enclosing command. A failing batch never publishes any collection.
pub fn collection_command(p: &mut ProjectData, v: &Value, cs: &mut ChangeSet) -> Result<bool> {
    let op = v["op"].as_str().unwrap_or("");
    let Some((verb, kind)) = op.split_once('_') else {
        return Ok(false);
    };
    if !matches!(verb, "add" | "update" | "remove") {
        return Ok(false);
    }
    let path = match kind {
        "annotation" => ["canvas", "annotations"],
        "reaction" => ["canvas", "reactions"],
        "caption" => ["canvas", "captions"],
        "music" => ["audio", "music"],
        _ => return Ok(false),
    };
    let mut data = serde_json::to_value(&*p)?;
    let records = data[path[0]][path[1]].as_array_mut().unwrap();
    match verb {
        "add" => {
            let mut record = v
                .get("record")
                .filter(|v| v.is_object())
                .cloned()
                .ok_or_else(|| bad("Missing record object"))?;
            if kind == "music" && record.get("gain_db").is_none() {
                record["gain_db"] = (if p.audio.music_volume == 0.0 {
                    -96.0
                } else {
                    20.0 * p.audio.music_volume.log10()
                })
                .into();
            }
            if record.get("id").is_none() || record["id"].as_str() == Some("") {
                record["id"] = unique_id(kind).into();
            }
            let new_id = record["id"]
                .as_str()
                .ok_or_else(|| bad("Invalid record id"))?;
            cs.created_ids.push(new_id.into());
            records.push(record);
        }
        "update" | "remove" => {
            let id = v["id"].as_str().ok_or_else(|| bad("Missing id"))?;
            let i = records
                .iter()
                .position(|r| r["id"] == id)
                .ok_or_else(|| bad("Unknown record id"))?;
            if verb == "remove" {
                records.remove(i);
            } else {
                let patch = v["patch"]
                    .as_object()
                    .ok_or_else(|| bad("Missing patch object"))?;
                if patch.contains_key("id") {
                    return Err(bad("Record id cannot be patched"));
                }
                for (k, val) in patch {
                    if records[i].get(k).is_none() {
                        return Err(bad("Unknown record patch field"));
                    }
                    records[i][k] = val.clone();
                }
            }
        }
        _ => unreachable!(),
    }
    *p = serde_json::from_value(data)?;
    cs.changed.push(format!("{}.{}", path[0], path[1]));
    Ok(true)
}
pub fn import_transcript(
    p: &mut ProjectData,
    v: &Value,
    cs: &mut ChangeSet,
    source_end: i64,
) -> Result<()> {
    let transcript = &v["transcript"];
    if transcript["schema_version"].as_u64() != Some(1) {
        return Err(bad("Unsupported transcript schema"));
    }
    let words = transcript["words"]
        .as_array()
        .ok_or_else(|| bad("Missing transcript words"))?;
    let style: TextStyle = match v.get("style") {
        Some(s) => serde_json::from_value(s.clone())?,
        None => TextStyle::default(),
    };
    if !self::style(&style) {
        return Err(bad("Invalid caption style"));
    }
    let replace = match v.get("replace") {
        Some(s) => s.as_bool().ok_or_else(|| bad("replace must be boolean"))?,
        None => true,
    };
    let words = words
        .iter()
        .map(|w| {
            let text = w["text"]
                .as_str()
                .filter(|s| !s.trim().is_empty())
                .ok_or_else(|| bad("Invalid transcript text"))?;
            let a = w["src_start_ns"]
                .as_i64()
                .ok_or_else(|| bad("Missing word source start"))?;
            let b = w["src_end_ns"]
                .as_i64()
                .ok_or_else(|| bad("Missing word source end"))?;
            if !range(a, b)
                || b > source_end
                || w.get("confidence")
                    .is_some_and(|v| v.as_f64().is_none_or(|n| !(0.0..=1.0).contains(&n)))
            {
                return Err(bad("Invalid transcript word range/confidence"));
            }
            Ok((text, a, b))
        })
        .collect::<Result<Vec<_>>>()?;
    let mut records = vec![];
    for (i, c) in p.timeline.clips.iter().enumerate() {
        for &(text, a, b) in &words {
            let x = a.max(c.src_start_ns);
            let y = b.min(c.src_end_ns);
            if y <= x {
                continue;
            }
            let start = time::source_boundary_to_timeline(&p.timeline.clips, i, x).unwrap();
            let end = time::source_boundary_to_timeline(&p.timeline.clips, i, y).unwrap();
            if end <= start {
                continue;
            }
            let id = unique_id("caption");
            cs.created_ids.push(id.clone());
            records.push(TextRecord {
                id,
                tl_start_ns: start,
                tl_end_ns: end,
                text: text.into(),
                style: style.clone(),
                ..TextRecord::default()
            });
        }
    }
    if replace {
        p.canvas.captions.clear();
    }
    p.canvas.captions.extend(records);
    cs.changed.push("canvas.captions".into());
    Ok(())
}
pub fn camera_options(p: &ProjectData, tl: i64) -> (bool, bool, f64) {
    let layout = p
        .camera
        .layouts
        .iter()
        .filter(|l| tl >= l.tl_start_ns && tl < l.tl_end_ns)
        .max_by_key(|l| l.tl_start_ns);
    (
        layout
            .and_then(|l| l.camera_background_removal)
            .unwrap_or(p.camera.background_removal),
        layout
            .and_then(|l| l.camera_face_framing)
            .unwrap_or(p.camera.face_framing),
        layout
            .and_then(|l| l.camera_shadow_radius)
            .unwrap_or(p.camera.shadow_radius),
    )
}
pub fn music_duration(m: &MusicTrack) -> i64 {
    if m.source == "file" {
        m.file_duration_ns
    } else {
        8_000_000_000_i64
    }
}
fn activity<'a>(p: &'a ProjectData, m: &'a MusicTrack) -> Vec<(i64, i64)> {
    if !m.ducking.enabled {
        return vec![];
    }
    if m.ducking.ranges.is_empty() {
        p.canvas
            .captions
            .iter()
            .map(|r| (r.tl_start_ns, r.tl_end_ns))
            .collect()
    } else {
        m.ducking
            .ranges
            .iter()
            .map(|r| (r.tl_start_ns, r.tl_end_ns))
            .collect()
    }
}
fn range_duck_db(m: &MusicTrack, t: i64, (a, b): (i64, i64)) -> f64 {
    if t < a {
        0.0
    } else if t < b {
        if m.ducking.attack_ns == 0 {
            m.ducking.gain_db
        } else {
            m.ducking.gain_db * ((t - a) as f64 / m.ducking.attack_ns as f64).min(1.0)
        }
    } else if m.ducking.release_ns > 0 && t - b < m.ducking.release_ns {
        let peak = if m.ducking.attack_ns == 0 {
            1.0
        } else {
            ((b - a) as f64 / m.ducking.attack_ns as f64).min(1.0)
        };
        m.ducking.gain_db * peak * (1.0 - (t - b) as f64 / m.ducking.release_ns as f64)
    } else {
        0.0
    }
}
fn duck_db(m: &MusicTrack, t: i64, ranges: &[(i64, i64)]) -> f64 {
    ranges
        .iter()
        .map(|&r| range_duck_db(m, t, r))
        .fold(0.0, f64::min)
}
/// Minima of overlapping release/attack lines can cross between the ordinary
/// range boundaries. A lower envelope hull adds those corners, so consumers can
/// interpolate endpoint gains in dB without approximating overlapping speech.
fn envelope_corners(m: &MusicTrack, ranges: &[(i64, i64)], points: &mut Vec<i64>) {
    let base = points.clone();
    for pair in base.windows(2) {
        let (a, b) = (pair[0], pair[1]);
        if b - a <= 1 {
            continue;
        }
        let mut lines = vec![(0.0, 0.0)];
        for &r in ranges {
            if a >= r.1.saturating_add(m.ducking.release_ns) || b <= r.0 {
                continue;
            }
            let y0 = range_duck_db(m, a, r);
            let y1 = range_duck_db(m, b - 1, r);
            lines.push((y1 - y0, y0));
        }
        lines.sort_by(|x, y| y.0.total_cmp(&x.0).then(x.1.total_cmp(&y.1)));
        let mut hull: Vec<(f64, f64, f64)> = vec![];
        for (slope, offset) in lines {
            if hull.last().is_some_and(|l| l.0 == slope) {
                continue;
            }
            let mut start = f64::NEG_INFINITY;
            while let Some(&(last_slope, last_offset, last_start)) = hull.last() {
                start = (offset - last_offset) / (last_slope - slope);
                if start > last_start {
                    break;
                }
                hull.pop();
            }
            if hull.is_empty() {
                start = f64::NEG_INFINITY;
            }
            hull.push((slope, offset, start));
        }
        for (_, _, fraction) in hull {
            if fraction > 0.0 && fraction < 1.0 {
                let at = a.saturating_add(((b - a - 1) as f64 * fraction).round() as i64);
                if at > a && at < b {
                    points.push(at);
                }
            }
        }
    }
    points.sort_unstable();
    points.dedup();
}
fn amp(db: f64) -> f64 {
    10_f64.powf(db / 20.0)
}
impl Project {
    pub fn audio_overlays(&self) -> Result<Value> {
        let duration = time::duration(&self.data.timeline.clips);
        let mut rows = vec![];
        for m in &self.data.audio.music {
            let end = m.tl_end_ns.min(duration).min(if m.r#loop {
                i64::MAX
            } else {
                m.tl_start_ns
                    .saturating_add(music_duration(m) - m.file_start_ns)
            });
            if end <= m.tl_start_ns {
                continue;
            }
            let ranges = activity(&self.data, m);
            let mut points = vec![m.tl_start_ns, end];
            for &(a, b) in &ranges {
                for t in [
                    a,
                    a.saturating_add(m.ducking.attack_ns).min(b),
                    b,
                    b.saturating_add(m.ducking.release_ns),
                ] {
                    if t > m.tl_start_ns && t < end {
                        points.push(t);
                    }
                }
            }
            points.sort_unstable();
            points.dedup();
            envelope_corners(m, &ranges, &mut points);
            for pair in points.windows(2) {
                let (a, b) = (pair[0], pair[1]);
                let elapsed = a - m.tl_start_ns;
                let file_start = if m.r#loop {
                    ((m.file_start_ns as i128 + elapsed as i128) % music_duration(m) as i128) as i64
                } else {
                    m.file_start_ns + elapsed
                };
                rows.push(json!({"id":m.id,"source":m.source,"path":m.path,"tl_start_ns":a,"tl_end_ns":b,"file_start_ns":file_start,"file_duration_ns":music_duration(m),"loop":m.r#loop,"gain":amp(m.gain_db+duck_db(m,a,&ranges)),"gain_start":amp(m.gain_db+duck_db(m,a,&ranges)),"gain_end":amp(m.gain_db+duck_db(m,b.saturating_sub(1),&ranges)),"fade_in_ns":m.fade_in_ns,"fade_out_ns":m.fade_out_ns,"envelope_start_ns":m.tl_start_ns,"envelope_end_ns":end}));
            }
        }
        let click = &self.data.audio.click_sound;
        if click.enabled {
            let len = if click.variant == "crisp" {
                50_000_000
            } else {
                80_000_000
            };
            for (i, event) in self
                .query(&json!({"q":"clicks"}))?
                .as_array()
                .unwrap()
                .iter()
                .enumerate()
            {
                let a = event["tl_ns"].as_i64().unwrap();
                let b = a.saturating_add(len).min(duration);
                if b <= a {
                    continue;
                }
                rows.push(json!({"id":format!("core:click:{i}"),"source":click.variant,"path":"","tl_start_ns":a,"tl_end_ns":b,"file_start_ns":0,"file_duration_ns":len,"loop":false,"gain":amp(click.gain_db),"gain_start":amp(click.gain_db),"gain_end":amp(click.gain_db),"fade_in_ns":0,"fade_out_ns":0,"envelope_start_ns":a,"envelope_end_ns":b}));
            }
        }
        rows.sort_by_key(|r| r["tl_start_ns"].as_i64());
        Ok(rows.into())
    }
    pub fn effects_at(&self, tl: i64) -> Result<Value> {
        self.frame(tl)?;
        let overlays = self.audio_overlays()?;
        let mut active = vec![];
        for row in overlays.as_array().unwrap() {
            let (a, b) = (
                row["tl_start_ns"].as_i64().unwrap(),
                row["tl_end_ns"].as_i64().unwrap(),
            );
            if tl < a || tl >= b {
                continue;
            }
            let mut row = row.clone();
            let k = (tl - a) as f64 / (b - a) as f64;
            let gain0 = row["gain_start"].as_f64().unwrap();
            let gain1 = row["gain_end"].as_f64().unwrap();
            let mut gain = gain0 * (gain1 / gain0).powf(k);
            let envelope_start = row["envelope_start_ns"].as_i64().unwrap();
            let envelope_end = row["envelope_end_ns"].as_i64().unwrap();
            let fade_in = row["fade_in_ns"].as_i64().unwrap();
            let fade_out = row["fade_out_ns"].as_i64().unwrap();
            if fade_in > 0 {
                gain *= ((tl - envelope_start) as f64 / fade_in as f64).clamp(0.0, 1.0);
            }
            if fade_out > 0 {
                gain *= ((envelope_end - tl) as f64 / fade_out as f64).clamp(0.0, 1.0);
            }
            row["gain_at"] = gain.into();
            active.push(row);
        }
        Ok(
            json!({"layers":self.layers_at(tl)?,"render_options":self.render_options(Some(tl))?,"audio":active}),
        )
    }
    pub fn render_options(&self, tl: Option<i64>) -> Result<Value> {
        let p = &self.data;
        let (remove, face, shadow) = tl.map_or(
            (
                p.camera.background_removal,
                p.camera.face_framing,
                p.camera.shadow_radius,
            ),
            |t| camera_options(p, t),
        );
        let motion = match tl {
            Some(t) => self.frame_motion(t)?,
            None => crate::motion::FrameMotion {
                cursor_motion_blur: p.cursor.motion_blur as f32,
                zoom_motion_blur: p
                    .canvas
                    .motion_blur_settings
                    .zoom
                    .unwrap_or(p.canvas.motion_blur) as f32,
                pan_motion_blur: p
                    .canvas
                    .motion_blur_settings
                    .pan
                    .unwrap_or(p.canvas.motion_blur) as f32,
                ..crate::motion::FrameMotion::default()
            },
        };
        Ok(
            json!({"screen_shadow":{"style":p.canvas.shadow.style,"offset_x":p.canvas.shadow.evaluated().0,"offset_y":p.canvas.shadow.evaluated().1,"radius":p.canvas.shadow.evaluated().2,"opacity":p.canvas.shadow.opacity},"padding_ratio":p.canvas.padding_ratio,"cursor_size_points":p.cursor.size_points,"cursor_set_id":p.cursor.set_id,"cursor_shape":if p.cursor.always_default {Some("arrow")} else {p.cursor.shape.as_deref()},"cursor_logical_size":p.cursor.logical_size,"cursor_style":if p.cursor.always_default {"pointer"} else {p.cursor.style.as_str()},"cursor_motion_blur":if tl.is_none() {p.cursor.motion_blur} else {motion.cursor_motion_blur as f64},"cursor_rotation_rad":motion.cursor_rotation_rad,"zoom_motion_blur":motion.zoom_motion_blur,"pan_motion_blur":motion.pan_motion_blur,"cursor_spotlight_radius":p.cursor.spotlight_radius,"background_noise":p.canvas.background.noise,"window_chrome":p.canvas.window_chrome,"camera_background_removal":remove,"camera_face_framing":face,"camera_shadow_radius":shadow}),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::tests::Fixture;
    fn make() -> (Fixture, Project) {
        let f = Fixture::new();
        let p = Project::create(&f.0).unwrap();
        (f, p)
    }
    #[test]
    fn collections_crud_defaults_atomic_undo_and_reopen() {
        let (f, mut p) = make();
        for kind in ["annotation", "reaction", "caption", "music"] {
            let record = if kind == "music" {
                json!({"tl_start_ns":0,"tl_end_ns":4_000_000_000_i64,"source":"calm"})
            } else {
                json!({"tl_start_ns":0,"tl_end_ns":4_000_000_000_i64,"text":"👋 café"})
            };
            let changes = p
                .apply(&json!({"op":format!("add_{kind}"),"record":record}))
                .unwrap();
            let id = &changes.created_ids[0];
            let collection = match kind {
                "annotation" => "annotations",
                "reaction" => "reactions",
                "caption" => "captions",
                _ => "music",
            };
            let query = json!({"q":collection});
            let original = p.query(&query).unwrap();
            assert_eq!(original[0]["id"], json!(id));
            let patch = if kind == "music" {
                json!({"gain_db":-6.0})
            } else {
                json!({"text":"edited"})
            };
            p.apply(&json!({"op":format!("update_{kind}"),"id":id,"patch":patch}))
                .unwrap();
            let edited = p.query(&query).unwrap();
            assert_ne!(edited, original);
            let history = p.undo.len();
            let before = p.data.clone();
            for patch in [
                json!({"id":"renamed"}),
                json!({"unknown":12}),
                json!({"tl_end_ns":0}),
            ] {
                assert!(p
                    .apply(&json!({"op":format!("update_{kind}"),"id":id,"patch":patch}))
                    .is_err());
                assert_eq!(p.data, before);
                assert_eq!(p.undo.len(), history);
            }
            p.undo().unwrap();
            assert_eq!(p.query(&query).unwrap(), original);
            p.redo().unwrap();
            assert_eq!(p.query(&query).unwrap(), edited);
            p.save(&f.0).unwrap();
            assert_eq!(Project::open(&f.0).unwrap().query(&query).unwrap(), edited);
            p.apply(&json!({"op":format!("remove_{kind}"),"id":id}))
                .unwrap();
            assert_eq!(p.query(&query).unwrap(), json!([]));
            p.undo().unwrap();
        }
        let before = p.data.clone();
        assert!(p.apply(&json!({"op":"batch","commands":[{"op":"add_annotation","record":{"text":"valid"}},{"op":"add_reaction","record":{"text":""}}]})).is_err());
        assert_eq!(p.data, before);
        assert!(p.apply(&json!({"op":"set","path":"canvas.annotations","value":[{"id":"a","text":"x","space":"bad"}]})).is_err());
        let legacy:ProjectData=serde_json::from_value(json!({"schema_version":1,"id":"legacy","created_at":"","modified_at":"","recording":"recording/session.json","timeline":{"clips":[]}})).unwrap();
        assert_eq!(legacy.canvas.annotations, vec![]);
        assert!(!legacy.cursor.key_overlay.enabled);
        assert!(!legacy.audio.click_sound.enabled);
        assert!(legacy.audio.music.is_empty());
    }
    #[test]
    fn captions_from_capture_transcript_map_cuts_speeds_and_repeats() {
        let (_f, mut p) = make();
        p.apply(
            &json!({"op":"delete_range","tl_start_ns":1_000_000_000,"tl_end_ns":2_000_000_000}),
        )
        .unwrap();
        let id = p.data.timeline.clips[0].id.clone();
        p.apply(&json!({"op":"set_speed","clip_id":id,"speed":2}))
            .unwrap();
        let mut repeat = p.data.timeline.clips[0].clone();
        repeat.id = "repeat".into();
        p.data.timeline.clips.push(repeat);
        let transcript = json!({"schema_version":1,"engine":"apple_speech_on_device","locale":"en-US","words":[
            {"text":"hello","src_start_ns":500_000_000,"src_end_ns":1_500_000_000,"confidence":0.9,"segment_index":0,"track":"mic"},
            {"text":"removed","src_start_ns":1_100_000_000,"src_end_ns":1_900_000_000},
            {"text":"world","src_start_ns":2_000_000_000,"src_end_ns":3_000_000_000_i64},
            {"text":"again","src_start_ns":3_500_000_000_i64,"src_end_ns":4_500_000_000_i64}]});
        let changes = p
            .apply(&json!({"op":"import_transcript","transcript":transcript}))
            .unwrap();
        assert_eq!(changes.created_ids.len(), 4);
        let rows = &p.data.canvas.captions;
        assert_eq!(
            rows.iter()
                .map(|r| (r.tl_start_ns, r.tl_end_ns))
                .collect::<Vec<_>>(),
            vec![
                (250_000_000, 500_000_000),
                (500_000_000, 1_500_000_000),
                (2_000_000_000, 3_000_000_000_i64),
                (3_750_000_000_i64, 4_000_000_000_i64)
            ]
        );
        let before = p.data.clone();
        let mut invalid = transcript.clone();
        invalid["words"][0]["src_end_ns"] = 0.into();
        assert!(p
            .apply(&json!({"op":"import_transcript","transcript":invalid}))
            .is_err());
        assert_eq!(p.data, before);
        p.apply(&json!({"op":"import_transcript","transcript":transcript,"replace":false}))
            .unwrap();
        assert_eq!(p.data.canvas.captions.len(), 8);
        p.undo().unwrap();
        assert_eq!(p.data, before);
        let snapshot = p.clone();
        assert_eq!(
            p.effects_at(300_000_000).unwrap(),
            snapshot.effects_at(300_000_000).unwrap()
        );
    }
    #[test]
    fn layers_text_reactions_keys_background_order_and_half_open_ranges() {
        let (_f, mut p) = make();
        p.data.canvas.aspect = "16:9".into();
        for (kind, text) in [
            ("annotation", "label"),
            ("reaction", "🎉"),
            ("caption", "spoken"),
        ] {
            p.apply(&json!({"op":format!("add_{kind}"),"record":{"tl_start_ns":1_000_000_000,"tl_end_ns":2_000_000_000,"text":text}})).unwrap();
        }
        let start = p.layers_at(1_000_000_000).unwrap();
        let rows = start.as_array().unwrap();
        assert_eq!(rows.len(), 6);
        for (i, text) in ["label", "🎉", "spoken"].iter().enumerate() {
            assert_eq!(rows[i * 2]["kind"], json!("highlight"));
            assert_eq!(rows[i * 2 + 1]["text"], json!(text));
            assert_eq!(
                rows[i * 2 + 1]["rect"],
                json!([192.0, 810.0, 1536.0, 162.0])
            );
        }
        assert_eq!(p.layers_at(2_000_000_000).unwrap(), json!([]));
        p.events[0].push(Event {
            t: 1_200_000_000,
            kind: "key".into(),
            x: None,
            y: None,
            id: None,
            details: std::collections::BTreeMap::from([
                ("key".into(), json!("k")),
                ("modifiers".into(), json!(["cmd", "shift"])),
            ]),
        });
        p.events[0].sort_by_key(|e| e.t);
        p.rebuild_key_overlay_index();
        p.apply(&json!({"op":"set","path":"cursor.key_overlay.enabled","value":true}))
            .unwrap();
        let at = p.layers_at(1_300_000_000).unwrap();
        assert_eq!(at.as_array().unwrap().last().unwrap()["text"], json!("⇧⌘k"));
        assert_eq!(p.layers_at(2_200_000_000).unwrap(), json!([]));
        p.apply(
            &json!({"op":"delete_range","tl_start_ns":1_000_000_000,"tl_end_ns":2_000_000_000}),
        )
        .unwrap();
        assert_eq!(p.layers_at(1_300_000_000).unwrap(), json!([]));
        assert_eq!(
            crate::allocation_test::count(|| {
                p.frame(0).unwrap();
                p.frame_extras(0).unwrap();
            }),
            0
        );
    }
    #[test]
    fn effect_ranges_retime_and_presets_remain_portable() {
        let (_f, mut p) = make();
        p.apply(&json!({"op":"batch","commands":[
            {"op":"add_annotation","record":{"text":"label","tl_start_ns":1_000_000_000,"tl_end_ns":3_000_000_000_i64}},
            {"op":"add_reaction","record":{"text":"🎉","tl_start_ns":1_000_000_000,"tl_end_ns":3_000_000_000_i64}},
            {"op":"add_caption","record":{"text":"speech","tl_start_ns":1_000_000_000,"tl_end_ns":3_000_000_000_i64}},
            {"op":"add_music","record":{"source":"bright","tl_start_ns":0,"tl_end_ns":5_000_000_000_i64,"ducking":{"enabled":true,"ranges":[{"tl_start_ns":1_000_000_000,"tl_end_ns":3_000_000_000_i64}]}}}]})).unwrap();
        let id = p.data.timeline.clips[0].id.clone();
        p.apply(&json!({"op":"set_speed","clip_id":id,"speed":2}))
            .unwrap();
        for records in [
            &p.data.canvas.annotations,
            &p.data.canvas.reactions,
            &p.data.canvas.captions,
        ] {
            assert_eq!(
                (records[0].tl_start_ns, records[0].tl_end_ns),
                (500_000_000, 1_500_000_000)
            );
        }
        assert_eq!(p.data.audio.music[0].tl_end_ns, 2_500_000_000);
        assert_eq!(
            p.data.audio.music[0].ducking.ranges[0].tl_start_ns,
            500_000_000
        );
        let preset = p.query(&json!({"q":"preset"})).unwrap();
        for key in ["annotations", "reactions", "captions"] {
            assert!(preset["canvas"].get(key).is_none());
        }
        assert!(preset["audio"].get("music").is_none());
        p.apply(&json!({"op":"delete_range","tl_start_ns":500_000_000,"tl_end_ns":1_500_000_000}))
            .unwrap();
        assert!(p.data.canvas.captions.is_empty());
        assert!(p.data.audio.music[0].ducking.ranges.is_empty());
    }
    #[test]
    fn music_file_reference_loop_stop_duck_fades_and_click_mapping() {
        let (f, mut p) = make();
        std::fs::create_dir(f.0.join("assets")).unwrap();
        std::fs::write(f.0.join("assets/music.wav"), b"procedural-test-data").unwrap();
        p.apply(&json!({"op":"add_media","path":"assets/music.wav","role":"asset"}))
            .unwrap();
        p.apply(&json!({"op":"add_music","record":{"id":"music","path":"assets/music.wav","tl_start_ns":0,"tl_end_ns":5_000_000_000_i64,"file_duration_ns":2_000_000_000,"gain_db":0,"fade_in_ns":1_000_000_000,"fade_out_ns":1_000_000_000,"ducking":{"enabled":true,"gain_db":-20,"attack_ns":100_000_000,"release_ns":100_000_000,"ranges":[{"tl_start_ns":1_000_000_000,"tl_end_ns":2_000_000_000}]}}})).unwrap();
        let gain = |p: &Project, t| {
            p.effects_at(t).unwrap()["audio"][0]["gain_at"]
                .as_f64()
                .unwrap()
        };
        assert_eq!(gain(&p, 0), 0.0);
        assert!((gain(&p, 500_000_000) - 0.5).abs() < 1e-7);
        assert!((gain(&p, 1_500_000_000) - 0.1).abs() < 1e-7);
        assert!((gain(&p, 2_050_000_000) - 10f64.powf(-0.5)).abs() < 1e-7);
        assert!((gain(&p, 4_500_000_000_i64) - 0.5).abs() < 1e-7);
        let rows = p.audio_overlays().unwrap();
        assert!(rows
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["tl_start_ns"] == 2_100_000_000 && r["file_start_ns"] == 100_000_000));
        p.apply(&json!({"op":"update_music","id":"music","patch":{"loop":false}}))
            .unwrap();
        assert_eq!(
            p.audio_overlays()
                .unwrap()
                .as_array()
                .unwrap()
                .last()
                .unwrap()["tl_end_ns"],
            json!(2_000_000_000)
        );
        assert!(p
            .apply(&json!({"op":"update_music","id":"music","patch":{"path":"../outside.wav"}}))
            .is_err());
        p.apply(&json!({"op":"set","path":"audio.click_sound.enabled","value":true}))
            .unwrap();
        let clicks = p.query(&json!({"q":"clicks"})).unwrap();
        let audio = p.audio_overlays().unwrap();
        let click_rows: Vec<_> = audio
            .as_array()
            .unwrap()
            .iter()
            .filter(|r| r["source"] == "soft")
            .collect();
        assert_eq!(click_rows.len(), clicks.as_array().unwrap().len());
        for (row, event) in click_rows.iter().zip(clicks.as_array().unwrap()) {
            assert_eq!(row["tl_start_ns"], event["tl_ns"]);
            assert_eq!(
                row["tl_end_ns"].as_i64().unwrap() - row["tl_start_ns"].as_i64().unwrap(),
                80_000_000
            );
        }
        p.save(&f.0).unwrap();
        assert_eq!(
            p.audio_overlays().unwrap(),
            Project::open(&f.0).unwrap().audio_overlays().unwrap()
        );
    }
    #[test]
    fn camera_layout_options_and_intro_outro_geometry_share_evaluation() {
        let (_f, mut p) = make();
        p.apply(&json!({"op":"set","path":"camera.layouts","value":[{"id":"vision","tl_start_ns":1_000_000_000,"tl_end_ns":2_000_000_000,"mode":"overlay","camera_background_removal":true,"camera_face_framing":true,"camera_shadow_radius":30}]})).unwrap();
        for t in [0, 1_000_000_000, 2_000_000_000] {
            let extras = p.frame_extras(t).unwrap();
            let options = p
                .query(&json!({"q":"render_options_at","tl_ns":t}))
                .unwrap();
            assert_eq!(extras.camera_background_removal != 0, t == 1_000_000_000);
            assert_eq!(
                options["camera_face_framing"],
                json!(extras.camera_face_framing != 0)
            );
            assert_eq!(
                options["camera_shadow_radius"].as_f64().unwrap(),
                extras.camera_shadow_radius as f64
            );
        }
        let normal = p.frame(0).unwrap();
        for mode in [
            "zoom",
            "slide_left",
            "slide_right",
            "slide_up",
            "slide_down",
        ] {
            p.apply(&json!({"op":"set","path":"canvas.animation.entrance","value":mode}))
                .unwrap();
            let start = p.frame(0).unwrap();
            let finished = p.frame(400_000_000).unwrap();
            assert_eq!(finished.screen_dest, normal.screen_dest);
            assert_ne!(start.screen_dest, normal.screen_dest);
            assert!(start.screen_dest.w.is_finite());
            assert_eq!(p.frame_extras(0).unwrap().fade_opacity, 0.0);
            assert_eq!(
                crate::allocation_test::count(|| {
                    p.frame(0).unwrap();
                    p.frame_extras(0).unwrap();
                }),
                0
            );
        }
        p.apply(&json!({"op":"set","path":"canvas.animation.entrance","value":"none"}))
            .unwrap();
        p.apply(&json!({"op":"set","path":"canvas.animation.exit","value":"zoom"}))
            .unwrap();
        assert_eq!(p.frame(0).unwrap().screen_dest, normal.screen_dest);
        assert!(
            (p.frame(5_000_000_000_i64).unwrap().screen_dest.w - normal.screen_dest.w * 0.85).abs()
                < 1e-6
        );
        assert!(p
            .query(&json!({"q":"effects_at","tl_ns":5_000_000_001_i64}))
            .is_err());
        assert!(p
            .query(&json!({"q":"render_options_at","tl_ns":0.5}))
            .is_err());
    }
}

#[cfg(test)]
mod envelope_regressions {
    use super::*;
    use crate::project::tests::Fixture;
    #[test]
    fn overlapping_short_speech_envelopes_preserve_corners_and_continuity() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.apply(&json!({"op":"add_music","record":{"source":"calm","tl_start_ns":0,"tl_end_ns":5_000_000_000_i64,"gain_db":0,"fade_in_ns":0,"fade_out_ns":0,"ducking":{"enabled":true,"gain_db":-20,"attack_ns":200_000_000,"release_ns":400_000_000,"ranges":[{"tl_start_ns":1_000_000_000,"tl_end_ns":1_100_000_000},{"tl_start_ns":1_200_000_000,"tl_end_ns":1_500_000_000}]}}})).unwrap();
        let m = &p.data.audio.music[0];
        let ranges = activity(&p.data, m);
        assert!(
            (duck_db(m, 1_100_000_000, &ranges) - duck_db(m, 1_099_999_999, &ranges)).abs() < 1e-6
        );
        let rows = p.audio_overlays().unwrap();
        assert!(rows.as_array().unwrap().iter().any(|r| {
            let a = r["tl_start_ns"].as_i64().unwrap();
            a > 1_200_000_000 && a < 1_400_000_000
        }));
        for t in (1_000_000_000..1_950_000_000).step_by(1_000_000) {
            let actual = p.effects_at(t).unwrap()["audio"][0]["gain_at"]
                .as_f64()
                .unwrap();
            let expected = amp(duck_db(m, t, &ranges));
            assert!(
                (actual - expected).abs() < 1e-7,
                "at {t}: {actual} != {expected}"
            );
        }
        // Caption-inferred speech is the same as explicit ranges; no transcript
        // means no guessed voice activity, and short ranges release smoothly.
        p.data.audio.music[0].ducking.ranges.clear();
        assert_eq!(
            p.effects_at(1_250_000_000).unwrap()["audio"][0]["gain_at"],
            json!(1.0)
        );
        p.apply(&json!({"op":"add_caption","record":{"text":"hello","tl_start_ns":1_000_000_000,"tl_end_ns":1_100_000_000}})).unwrap();
        assert!(
            p.effects_at(1_150_000_000).unwrap()["audio"][0]["gain_at"]
                .as_f64()
                .unwrap()
                < 1.0
        );
    }
    #[test]
    fn invalid_transcript_rejected_even_when_timeline_is_empty() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.data.timeline.clips.clear();
        for bad_word in [
            json!({"text":"hello","src_start_ns":0,"src_end_ns":1,"confidence":2}),
            json!({"text":" ","src_start_ns":0,"src_end_ns":1}),
            json!({"text":"hello","src_start_ns":0.5,"src_end_ns":1}),
        ] {
            let before = p.data.clone();
            assert!(p.apply(&json!({"op":"import_transcript","transcript":{"schema_version":1,"words":[bad_word]}})).is_err());
            assert_eq!(p.data, before);
        }
    }
    #[test]
    fn source_text_geometry_matches_crop_zoom_and_scene_animation() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.data.canvas.aspect = "16:9".into();
        p.apply(&json!({"op":"batch","commands":[{"op":"set","path":"canvas.crop","value":[0.1,0.1,0.7,0.7]},{"op":"set","path":"canvas.animation.entrance","value":"slide_left"},{"op":"add_annotation","record":{"text":"source","space":"source","rect":[0.1,0.1,0.7,0.7]}},{"op":"add_reaction","record":{"text":"fixed","rect":[0.1,0.1,0.7,0.7]}}]})).unwrap();
        let f = p.frame(0).unwrap();
        let rows = p.layers_at(0).unwrap();
        let source = &rows[1]["rect"];
        let canvas = &rows[3]["rect"];
        assert_eq!(
            *source,
            json!([
                f.screen_dest.x,
                f.screen_dest.y,
                f.screen_dest.w,
                f.screen_dest.h
            ])
        );
        assert_eq!(*canvas, json!([192.0, 108.0, 1344.0, 756.0]));
        assert!(source[0].as_f64().unwrap() < 0.0);
        assert_eq!(p.frame_extras(0).unwrap().fade_opacity, 0.0);
    }
}
