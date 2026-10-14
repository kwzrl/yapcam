//! Cold-path commands are transactional. A failed batch changes neither data nor history.
use crate::{
    model::*,
    project::{unique_id, validate_data, Error, Project, Result},
    time,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
#[derive(Debug, Default, Serialize, Deserialize)]
pub struct ChangeSet {
    pub changed: Vec<String>,
    #[serde(rename = "createdIDs", alias = "created_ids")]
    pub created_ids: Vec<String>,
}
pub(crate) struct PreparedApply {
    pub next: Option<ProjectData>,
    pub changes: ChangeSet,
}
fn int(v: &Value, key: &str) -> Result<i64> {
    v.get(key)
        .and_then(Value::as_i64)
        .ok_or_else(|| Error::new(1, format!("Missing integer {key}")))
}
fn string<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| Error::new(1, format!("Missing string {key}")))
}
fn number(v: &Value, key: &str) -> Result<f64> {
    v.get(key)
        .and_then(Value::as_f64)
        .ok_or_else(|| Error::new(1, format!("Missing number {key}")))
}
impl Project {
    pub fn apply(&mut self, command: &Value) -> Result<ChangeSet> {
        let prepared = self.prepare_apply(command)?;
        if let Some(next) = prepared.next {
            self.write_journal(&next)?;
            drop(self.commit_apply(next));
        }
        Ok(prepared.changes)
    }
    /// FFI stages under a read lock, journals outside that lock, then publishes.
    /// Its separate writer gate keeps this staged state current until commit.
    pub(crate) fn prepare_apply(&self, command: &Value) -> Result<PreparedApply> {
        let mut next = self.data.clone();
        let mut changes = ChangeSet::default();
        apply_inner(&mut next, command, &mut changes, 0, self)?;
        validate_data(&next)?;
        let end = self
            .session
            .segments
            .last()
            .map_or(0, |s| s.src_start_ns + s.duration_ns);
        if next.timeline.clips.iter().any(|c| c.src_end_ns > end) {
            return Err(Error::new(1, "Clip outside recording"));
        }
        let next = if next != self.data {
            next.modified_at = crate::project::timestamp();
            Some(next)
        } else {
            changes.changed.clear();
            changes.created_ids.clear();
            None
        };
        changes.changed.sort();
        changes.changed.dedup();
        Ok(PreparedApply { next, changes })
    }
    pub(crate) fn commit_apply(&mut self, next: ProjectData) -> Vec<ProjectData> {
        self.undo.push(std::mem::replace(&mut self.data, next));
        // Drop obsolete history after the FFI releases its write lock.
        std::mem::take(&mut self.redo)
    }
    pub fn undo(&mut self) -> Result<bool> {
        if let Some(old) = self.undo.last() {
            self.write_journal(old)?;
        } else {
            return Ok(false);
        }
        Ok(self.commit_undo())
    }
    pub fn redo(&mut self) -> Result<bool> {
        if let Some(next) = self.redo.last() {
            self.write_journal(next)?;
        } else {
            return Ok(false);
        }
        Ok(self.commit_redo())
    }
    pub(crate) fn commit_undo(&mut self) -> bool {
        if let Some(previous) = self.undo.pop() {
            self.redo.push(std::mem::replace(&mut self.data, previous));
            true
        } else {
            false
        }
    }
    pub(crate) fn commit_redo(&mut self) -> bool {
        if let Some(next) = self.redo.pop() {
            self.undo.push(std::mem::replace(&mut self.data, next));
            true
        } else {
            false
        }
    }
}
fn apply_inner(
    p: &mut ProjectData,
    v: &Value,
    cs: &mut ChangeSet,
    depth: usize,
    context: &Project,
) -> Result<()> {
    if depth > 32 {
        return Err(Error::new(1, "Batch nesting exceeds 32"));
    }
    if crate::effects::collection_command(p, v, cs)? {
        return Ok(());
    }
    match string(v, "op")? {
        "batch" => {
            let commands = v
                .get("commands")
                .and_then(Value::as_array)
                .ok_or_else(|| Error::new(1, "Missing commands"))?;
            for cmd in commands {
                apply_inner(p, cmd, cs, depth + 1, context)?;
            }
        }
        "split" => {
            let at = int(v, "at_tl_ns")?;
            if at <= 0 || at >= time::duration(&p.timeline.clips) {
                return Err(Error::new(1, "Split must be inside timeline"));
            }
            let (i, src) = time::timeline_to_source(&p.timeline.clips, at)
                .ok_or_else(|| Error::new(1, "Split outside timeline"))?;
            let c = &mut p.timeline.clips[i];
            if src <= c.src_start_ns || src >= c.src_end_ns {
                return Err(Error::new(1, "Split is already a clip boundary"));
            }
            let mut right = c.clone();
            right.id = unique_id("clip");
            right.src_start_ns = src;
            c.src_end_ns = src;
            cs.created_ids.push(right.id.clone());
            p.timeline.clips.insert(i + 1, right);
            cs.changed.push("timeline".into());
        }
        "delete_range" => {
            let a = int(v, "tl_start_ns")?;
            let b = int(v, "tl_end_ns")?;
            if a < 0 || b <= a || b > time::duration(&p.timeline.clips) {
                return Err(Error::new(1, "Invalid delete range"));
            }
            let mut clips = Vec::new();
            let mut removed = Vec::new();
            for (i, c) in p.timeline.clips.iter().enumerate() {
                let left_end = time::timeline_boundary_to_source(&p.timeline.clips, i, a).unwrap();
                let right_start =
                    time::timeline_boundary_to_source(&p.timeline.clips, i, b).unwrap();
                if left_end == right_start {
                    clips.push(c.clone());
                } else {
                    removed.push((i, left_end, right_start));
                    if left_end > c.src_start_ns {
                        let mut left = c.clone();
                        left.src_end_ns = left_end;
                        clips.push(left);
                    }
                    if right_start < c.src_end_ns {
                        let mut right = c.clone();
                        right.src_start_ns = right_start;
                        if left_end > c.src_start_ns {
                            right.id = unique_id("clip");
                            cs.created_ids.push(right.id.clone());
                        }
                        clips.push(right);
                    }
                }
            }
            let map = time::CutTimeMap::new(&p.timeline.clips, &removed);
            p.timeline.clips = clips;
            remap_effects(p, |t| map.map(t));
            cs.changed.extend([
                "timeline".into(),
                "zooms".into(),
                "camera.layouts".into(),
                "cursor.ranges".into(),
                "audio.ranges".into(),
                "canvas.highlights".into(),
            ]);
        }
        "set_speed" => {
            let id = string(v, "clip_id")?;
            let speed = number(v, "speed")?;
            if !(0.05..=32.0).contains(&speed) {
                return Err(Error::new(1, "Speed must be 0.05…32"));
            }
            let i = p
                .timeline
                .clips
                .iter()
                .position(|c| c.id == id)
                .ok_or_else(|| Error::new(1, "Unknown clip id"))?;
            if p.timeline.clips[i].speed == speed {
                return Ok(());
            }
            let map = time::SpeedTimeMap::new(&p.timeline.clips, i, speed);
            p.timeline.clips[i].speed = speed;
            remap_effects(p, |t| map.map(t));
            cs.changed.extend([
                "timeline".into(),
                "zooms".into(),
                "camera.layouts".into(),
                "cursor.ranges".into(),
                "audio.ranges".into(),
                "canvas.highlights".into(),
            ]);
        }
        "add_zoom" => {
            let mut spec = v.get("zoom").cloned().unwrap_or_else(|| v.clone());
            spec.as_object_mut()
                .ok_or_else(|| Error::new(1, "Zoom must be an object"))?
                .remove("op");
            let id = unique_id("zoom");
            spec["id"] = id.clone().into();
            let z: Zoom = serde_json::from_value(spec)?;
            p.zooms.push(z);
            cs.created_ids.push(id);
            cs.changed.push("zooms".into());
        }
        "update_zoom" => {
            let id = string(v, "id")?;
            let patch = v
                .get("patch")
                .and_then(Value::as_object)
                .ok_or_else(|| Error::new(1, "Missing zoom patch"))?;
            let z = p
                .zooms
                .iter_mut()
                .find(|z| z.id == id)
                .ok_or_else(|| Error::new(1, "Unknown zoom id"))?;
            let mut spec = serde_json::to_value(&*z)?;
            for (k, val) in patch {
                if k == "id" || spec.get(k).is_none() {
                    return Err(Error::new(1, "Unknown/immutable zoom key"));
                }
                spec[k] = val.clone();
            }
            *z = serde_json::from_value(spec)?;
            cs.changed.push("zooms".into());
        }
        "remove_zoom" => {
            let id = string(v, "id")?;
            let i = p
                .zooms
                .iter()
                .position(|z| z.id == id)
                .ok_or_else(|| Error::new(1, "Unknown zoom id"))?;
            p.zooms.remove(i);
            cs.changed.push("zooms".into());
        }
        "add_media" => {
            let path = string(v, "path")?;
            let role = string(v, "role")?;
            if role != "asset" && role != "background" {
                return Err(Error::new(1, "Invalid media role"));
            }
            let index = if let Some(i) = p.media.iter().position(|m| m.path == path) {
                i
            } else {
                let mut media = crate::project::fingerprint(&crate::project::relative_path(
                    &context.package,
                    path,
                )?)?;
                media.path = path.into();
                p.media.push(media);
                p.media.len() - 1
            };
            if role == "background" {
                p.canvas.background.kind = "image".into();
                p.canvas.background.asset = index as u32;
                cs.changed.push("canvas.background".into());
            }
            cs.created_ids.push(format!("asset-{index}"));
            cs.changed.push("media".into());
        }
        "relink_project" => {
            let original = v
                .get("project")
                .ok_or_else(|| Error::new(1, "Missing recovery project"))?;
            let mut recovered = crate::project::decode_project(&serde_json::to_vec(original)?)?;
            if recovered.recording != context.data.recording {
                return Err(Error::new(1, "Relink cannot change the recording manifest"));
            }
            let paths = v
                .get("paths")
                .and_then(Value::as_array)
                .ok_or_else(|| Error::new(1, "Missing relink paths"))?;
            for path in paths {
                let path = path
                    .as_str()
                    .ok_or_else(|| Error::new(1, "Invalid relink path"))?;
                let media = recovered
                    .media
                    .iter_mut()
                    .find(|m| m.path == path)
                    .ok_or_else(|| Error::new(1, "Relink path is not referenced media"))?;
                let mut updated = crate::project::fingerprint(&crate::project::relative_path(
                    &context.package,
                    path,
                )?)?;
                updated.path = path.into();
                *media = updated;
            }
            context.check_media_for(&recovered)?;
            *p = recovered;
            cs.changed.push("media".into());
        }
        "process_silence" => {
            let ranges = v
                .get("ranges")
                .and_then(Value::as_array)
                .ok_or_else(|| Error::new(1, "Missing silence ranges"))?;
            let mut spans = Vec::new();
            for r in ranges {
                let a = int(r, "tl_start_ns")?;
                let b = int(r, "tl_end_ns")?;
                if a < 0 || b <= a || b > time::duration(&p.timeline.clips) {
                    return Err(Error::new(1, "Invalid silence range"));
                }
                spans.push((a, b));
            }
            spans.sort();
            let mut merged: Vec<(i64, i64)> = Vec::new();
            for (a, b) in spans {
                if let Some(last) = merged.last_mut() {
                    if a <= last.1 {
                        last.1 = last.1.max(b);
                        continue;
                    }
                }
                merged.push((a, b));
            }
            let mode = string(v, "mode")?;
            if mode != "cut" && mode != "speed" {
                return Err(Error::new(1, "Invalid silence operation"));
            }
            let speed = if mode == "speed" {
                number(v, "speed")?
            } else {
                1.0
            };
            for (a, b) in merged.into_iter().rev() {
                if mode == "cut" {
                    apply_inner(
                        p,
                        &serde_json::json!({"op":"delete_range","tl_start_ns":a,"tl_end_ns":b}),
                        cs,
                        depth + 1,
                        context,
                    )?;
                } else {
                    for at in [b, a] {
                        if at > 0 && at < time::duration(&p.timeline.clips) {
                            if let Some((i, src)) = time::timeline_to_source(&p.timeline.clips, at)
                            {
                                if src > p.timeline.clips[i].src_start_ns {
                                    apply_inner(
                                        p,
                                        &serde_json::json!({"op":"split","at_tl_ns":at}),
                                        cs,
                                        depth + 1,
                                        context,
                                    )?;
                                }
                            }
                        }
                    }
                    let mut start: f64 = 0.0;
                    let mut ids = Vec::new();
                    for c in &p.timeline.clips {
                        let end = start + time::clip_duration(c);
                        if start.round() as i64 >= a && end.round() as i64 <= b {
                            ids.push(c.id.clone());
                        }
                        start = end;
                    }
                    for id in ids {
                        apply_inner(
                            p,
                            &serde_json::json!({"op":"set_speed","clip_id":id,"speed":speed}),
                            cs,
                            depth + 1,
                            context,
                        )?;
                    }
                }
            }
        }
        "import_transcript" => {
            let end = context
                .session
                .segments
                .last()
                .map_or(0, |s| s.src_start_ns + s.duration_ns);
            crate::effects::import_transcript(p, v, cs, end)?;
        }
        "auto_zooms" => {
            crate::auto::generate_zooms(p, context, v, cs)?;
        }
        "auto_speed_typing" => {
            crate::auto::speed_typing(p, context, v, cs)?;
        }
        "apply_preset" => {
            let settings = v
                .get("preset")
                .and_then(Value::as_object)
                .ok_or_else(|| Error::new(1, "Missing preset"))?;
            let mut data = serde_json::to_value(&*p)?;
            for (key, value) in settings {
                if !matches!(
                    key.as_str(),
                    "canvas" | "cursor" | "camera" | "audio" | "zoom_settings" | "export"
                ) {
                    return Err(Error::new(1, "Preset contains a non-setting field"));
                }
                data[key] = value.clone();
                cs.changed.push(key.clone());
            }
            *p = serde_json::from_value(data)?;
        }
        "set" => {
            let path = string(v, "path")?;
            let parts: Vec<_> = path.split('.').collect();
            if (parts.len() < 2 && !matches!(path, "notes" | "autosave"))
                || !matches!(
                    parts[0],
                    "canvas"
                        | "cursor"
                        | "camera"
                        | "audio"
                        | "zoom_settings"
                        | "export"
                        | "notes"
                        | "autosave"
                )
            {
                return Err(Error::new(
                    1,
                    "Set path must reference a documented setting",
                ));
            }
            let value = v
                .get("value")
                .ok_or_else(|| Error::new(1, "Missing set value"))?;
            let mut data = serde_json::to_value(&*p)?;
            let mut target = &mut data;
            for part in &parts {
                target = target
                    .get_mut(*part)
                    .ok_or_else(|| Error::new(1, format!("Unknown setting path: {path}")))?;
            }
            *target = value.clone();
            *p = serde_json::from_value(data)?;
            cs.changed.push(path.into());
        }
        other => return Err(Error::new(1, format!("Unsupported command: {other}"))),
    }
    Ok(())
}
pub(crate) fn remap_effects(p: &mut ProjectData, map: impl Fn(i64) -> i64) {
    for z in &mut p.zooms {
        z.tl_start_ns = map(z.tl_start_ns);
        z.tl_end_ns = map(z.tl_end_ns);
    }
    p.zooms.retain(|z| z.tl_end_ns > z.tl_start_ns);
    for l in &mut p.camera.layouts {
        l.tl_start_ns = map(l.tl_start_ns);
        l.tl_end_ns = map(l.tl_end_ns);
    }
    p.camera.layouts.retain(|l| l.tl_end_ns > l.tl_start_ns);
    for r in &mut p.cursor.ranges {
        r.tl_start_ns = map(r.tl_start_ns);
        r.tl_end_ns = map(r.tl_end_ns);
    }
    p.cursor.ranges.retain(|r| r.tl_end_ns > r.tl_start_ns);
    for r in &mut p.audio.ranges {
        r.tl_start_ns = map(r.tl_start_ns);
        r.tl_end_ns = map(r.tl_end_ns);
    }
    p.audio.ranges.retain(|r| r.tl_end_ns > r.tl_start_ns);
    for h in &mut p.canvas.highlights {
        h.tl_start_ns = map(h.tl_start_ns);
        h.tl_end_ns = map(h.tl_end_ns);
    }
    p.canvas.highlights.retain(|h| h.tl_end_ns > h.tl_start_ns);
    for records in [
        &mut p.canvas.annotations,
        &mut p.canvas.reactions,
        &mut p.canvas.captions,
    ] {
        for r in records.iter_mut() {
            r.tl_start_ns = map(r.tl_start_ns);
            r.tl_end_ns = map(r.tl_end_ns);
        }
        records.retain(|r| r.tl_end_ns > r.tl_start_ns);
    }
    for m in &mut p.audio.music {
        m.tl_start_ns = map(m.tl_start_ns);
        m.tl_end_ns = map(m.tl_end_ns);
        for r in &mut m.ducking.ranges {
            r.tl_start_ns = map(r.tl_start_ns);
            r.tl_end_ns = map(r.tl_end_ns);
        }
        m.ducking.ranges.retain(|r| r.tl_end_ns > r.tl_start_ns);
    }
    p.audio.music.retain(|m| m.tl_end_ns > m.tl_start_ns);
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::tests::Fixture;
    use serde_json::json;
    #[test]
    fn speaker_notes_unicode_persistence_history_and_validation() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        let notes = "Opening 👋\n第二行 — café";
        let change = p
            .apply(&json!({"op":"set","path":"notes","value":notes}))
            .unwrap();
        assert_eq!(change.changed, ["notes"]);
        assert_eq!(Project::open(&f.0).unwrap().data.notes, notes);
        let before = p.data.clone();
        let history = p.undo.len();
        assert!(p
            .apply(&json!({"op":"set","path":"notes","value":notes}))
            .unwrap()
            .changed
            .is_empty());
        for bad in [json!(null), json!(12), json!([]), json!(true)] {
            assert!(p
                .apply(&json!({"op":"set","path":"notes","value":bad}))
                .is_err());
        }
        assert_eq!(p.data, before);
        assert_eq!(p.undo.len(), history);
        p.undo().unwrap();
        assert_eq!(p.data.notes, "");
        p.redo().unwrap();
        p.save(&f.0).unwrap();
        assert_eq!(Project::open(&f.0).unwrap().data.notes, notes);
        let mut legacy = serde_json::to_value(&p.data).unwrap();
        legacy.as_object_mut().unwrap().remove("notes");
        assert_eq!(
            serde_json::from_value::<ProjectData>(legacy).unwrap().notes,
            ""
        );
    }
    #[test]
    fn commands_and_undo_redo() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        let before = p.data.clone();
        p.apply(&json!({"op":"split","at_tl_ns":2_000_000_000}))
            .unwrap();
        assert_eq!(p.data.timeline.clips.len(), 2);
        let id = p.data.timeline.clips[0].id.clone();
        p.apply(&json!({"op":"set_speed","clip_id":id,"speed":2.0}))
            .unwrap();
        assert_eq!(time::duration(&p.data.timeline.clips), 4_000_000_000);
        let z = p.apply(&json!({"op":"add_zoom","tl_start_ns":100_000_000,"tl_end_ns":900_000_000,"mode":"manual","target":[0.5,0.5],"scale":2,"ease_in_ns":100_000_000,"ease_out_ns":100_000_000})).unwrap().created_ids[0].clone();
        p.apply(&json!({"op":"update_zoom","id":z,"patch":{"scale":3}}))
            .unwrap();
        assert_eq!(p.data.zooms[0].scale, 3.0);
        p.apply(&json!({"op":"remove_zoom","id":z})).unwrap();
        p.apply(
            &json!({"op":"delete_range","tl_start_ns":1_000_000_000,"tl_end_ns":2_000_000_000}),
        )
        .unwrap();
        assert_eq!(time::duration(&p.data.timeline.clips), 3_000_000_000);
        p.apply(&json!({"op":"set","path":"canvas.padding","value":80}))
            .unwrap();
        let after = p.data.clone();
        let count = p.undo.len();
        for _ in 0..count {
            assert!(p.undo().unwrap());
        }
        assert!(!p.undo().unwrap());
        assert_eq!(p.data, before);
        for _ in 0..count {
            assert!(p.redo().unwrap());
        }
        assert!(!p.redo().unwrap());
        assert_eq!(p.data, after);
        p.undo().unwrap();
        p.apply(&json!({"op":"set","path":"canvas.padding","value":45}))
            .unwrap();
        assert!(p.redo.is_empty());
    }
    #[test]
    fn batch_failure_is_atomic_and_success_one_step() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        let original = p.data.clone();
        assert!(p.apply(&json!({"op":"batch","commands":[{"op":"set","path":"canvas.padding","value":60},{"op":"split","at_tl_ns":-1}]})).is_err());
        assert_eq!(p.data, original);
        assert!(p.undo.is_empty());
        p.apply(&json!({"op":"batch","commands":[{"op":"set","path":"canvas.padding","value":60},{"op":"set","path":"audio.mic_gain_db","value":-6}]})).unwrap();
        assert_eq!(p.undo.len(), 1);
        p.undo().unwrap();
        assert_eq!(p.data, original);
        assert!(p
            .apply(&json!({"op":"set","path":"canvas.typo","value":1}))
            .is_err());
        assert!(p
            .apply(&json!({"op":"set","path":"canvas","value":{}}))
            .is_err());
        assert!(p
            .apply(&json!({"op":"set","path":"cursor.size","value":-1}))
            .is_err());
    }
    #[test]
    fn deterministic_10000_random_edits_share_mapping() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.data.autosave = false;
        let base = p.data.clone();
        let mut seed = 0x12345678u64;
        let mut successes = 0;
        for n in 0..12_000 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
            if time::duration(&p.data.timeline.clips) < 20_000_000
                || p.data.timeline.clips.len() > 100
            {
                p.data = base.clone();
            }
            let d = time::duration(&p.data.timeline.clips);
            let command = match n % 3 {
                0 => json!({"op":"split", "at_tl_ns":1 + (seed % (d-1) as u64) as i64}),
                1 => {
                    let a = (seed % (d / 2) as u64) as i64;
                    json!({"op":"delete_range","tl_start_ns":a,"tl_end_ns":a+d/10})
                }
                _ => {
                    let c = &p.data.timeline.clips[seed as usize % p.data.timeline.clips.len()];
                    json!({"op":"set_speed","clip_id":c.id,"speed":([0.5,1.0,1.25,2.0,3.0][(seed >> 16) as usize % 5])})
                }
            };
            if p.apply(&command).is_ok() {
                successes += 1;
            }
            p.undo.clear();
            let d = time::duration(&p.data.timeline.clips);
            let units = |speed: f64| match speed {
                0.5 => 60i128,
                1.0 => 30,
                1.25 => 24,
                2.0 => 15,
                3.0 => 10,
                _ => panic!("Unexpected property-test speed"),
            };
            let total: i128 = p
                .data
                .timeline
                .clips
                .iter()
                .map(|c| (c.src_end_ns - c.src_start_ns) as i128 * units(c.speed))
                .sum();
            assert_eq!(
                d,
                ((total + 15) / 30) as i64,
                "Duration disagrees with exact rational oracle"
            );
            for fraction in [0.0, 0.13, 0.51, 0.97] {
                let t = (d as f64 * fraction) as i64;
                let (i, src) = time::timeline_to_source(&p.data.timeline.clips, t).unwrap();
                let mut prefix = 0i128;
                for (j, c) in p.data.timeline.clips.iter().enumerate() {
                    let end = prefix + (c.src_end_ns - c.src_start_ns) as i128 * units(c.speed);
                    if (t as i128) * 30 < end {
                        assert_eq!(i, j);
                        let numerator = (t as i128 * 30 - prefix) * 30;
                        let denominator = units(c.speed) * 30;
                        let expected =
                            c.src_start_ns + ((numerator + denominator / 2) / denominator) as i64;
                        assert_eq!(src, expected.clamp(c.src_start_ns, c.src_end_ns - 1));
                        break;
                    }
                    prefix = end;
                }
                let back = time::source_to_timeline(&p.data.timeline.clips, i, src).unwrap();
                assert!((t - back).abs() <= 2, "round-trip {t} vs {back}");
                let video = time::sample(&p.session, "screen", src);
                let audio = time::sample(&p.session, "system_audio", src);
                assert_eq!(video.src_ns, audio.src_ns);
                assert_eq!(video.segment, audio.segment);
                assert_eq!(video.file_ns, audio.file_ns);
                let segment = &p.session.segments[video.segment as usize];
                assert_eq!(src - segment.src_start_ns, video.file_ns); // event clock is the same
            }
        }
        assert!(successes >= 10_000, "{successes} successful operations");
    }
    #[test]
    fn splitting_does_not_accumulate_fractional_duration_error() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.data.autosave = false;
        p.data.timeline.clips[0].speed = 1.3;
        let original = time::duration(&p.data.timeline.clips);
        for n in 1i64..1000 {
            p.apply(&json!({"op":"split","at_tl_ns":n*3_000_001}))
                .unwrap();
            p.undo.clear();
        }
        assert_eq!(time::duration(&p.data.timeline.clips), original);
    }
    fn long_project() -> (Fixture, Project, i64) {
        let fixture = Fixture::new();
        let mut p = Project::create(&fixture.0).unwrap();
        let length = (1_i64 << 53) + 37;
        p.data.autosave = false;
        p.session.segments.truncate(1);
        p.session.segments[0].duration_ns = 2 * length;
        p.events.truncate(1);
        p.data.timeline.clips = vec![
            Clip {
                id: "long-1".into(),
                src_start_ns: 0,
                src_end_ns: length,
                speed: 1.0,
            },
            Clip {
                id: "long-2".into(),
                src_start_ns: length,
                src_end_ns: 2 * length,
                speed: 1.0,
            },
        ];
        (fixture, p, length)
    }
    fn put_effects(p: &mut Project, a: i64, b: i64) {
        p.apply(&json!({"op":"batch","commands":[
            {"op":"add_zoom","tl_start_ns":a,"tl_end_ns":b,"mode":"manual","target":[0.5,0.5],"scale":2,"ease_in_ns":0,"ease_out_ns":0},
            {"op":"set","path":"camera.layouts","value":[{"id":"layout","tl_start_ns":a,"tl_end_ns":b,"mode":"overlay"}]},
            {"op":"set","path":"cursor.ranges","value":[{"tl_start_ns":a,"tl_end_ns":b,"visible":false}]},
            {"op":"set","path":"audio.ranges","value":[{"id":"gain","track":"system_audio","tl_start_ns":a,"tl_end_ns":b,"start_gain_db":-6,"end_gain_db":0}]},
            {"op":"set","path":"canvas.highlights","value":[{"id":"highlight","tl_start_ns":a,"tl_end_ns":b}]}
        ]})).unwrap();
        p.undo.clear();
    }
    fn assert_effects(p: &Project, a: i64, b: i64) {
        assert_eq!(
            (p.data.zooms[0].tl_start_ns, p.data.zooms[0].tl_end_ns),
            (a, b)
        );
        assert_eq!(
            (
                p.data.camera.layouts[0].tl_start_ns,
                p.data.camera.layouts[0].tl_end_ns
            ),
            (a, b)
        );
        assert_eq!(
            (
                p.data.cursor.ranges[0].tl_start_ns,
                p.data.cursor.ranges[0].tl_end_ns
            ),
            (a, b)
        );
        assert_eq!(
            (
                p.data.audio.ranges[0].tl_start_ns,
                p.data.audio.ranges[0].tl_end_ns
            ),
            (a, b)
        );
        assert_eq!(
            (
                p.data.canvas.highlights[0].tl_start_ns,
                p.data.canvas.highlights[0].tl_end_ns
            ),
            (a, b)
        );
    }
    #[test]
    fn long_clock_speed_cut_and_noop_keep_all_effects_exact() {
        let (_fixture, mut p, l) = long_project();
        put_effects(&mut p, l + 9, l + 61);
        let before = p.data.clone();
        let changes = p
            .apply(&json!({"op":"set_speed","clip_id":"long-2","speed":1}))
            .unwrap();
        assert!(changes.changed.is_empty());
        assert!(p.undo.is_empty());
        assert_eq!(p.data, before);
        p.apply(&json!({"op":"set_speed","clip_id":"long-2","speed":2}))
            .unwrap();
        assert_effects(&p, l + 5, l + 31);
        let accelerated = p.data.clone();
        let history = p.undo.len();
        assert!(p
            .apply(&json!({"op":"set_speed","clip_id":"long-2","speed":2}))
            .unwrap()
            .changed
            .is_empty());
        assert_eq!(p.undo.len(), history);
        assert_eq!(p.data, accelerated);
        let changes = p
            .apply(&json!({"op":"delete_range","tl_start_ns":l+7,"tl_end_ns":l+18}))
            .unwrap();
        assert!(changes.changed.iter().any(|p| p == "canvas.highlights"));
        assert_eq!(p.data.timeline.clips[1].src_end_ns, l + 14);
        assert_eq!(p.data.timeline.clips[2].src_start_ns, l + 36);
        assert_effects(&p, l + 5, l + 20);
        p.undo().unwrap();
        assert_eq!(p.data, accelerated);
        p.undo().unwrap();
        assert_eq!(p.data, before);
        p.redo().unwrap();
        p.redo().unwrap();
        assert_effects(&p, l + 5, l + 20);
    }
    #[test]
    fn typing_retimes_long_clock_effects_once_and_is_idempotent() {
        let (_fixture, mut p, l) = long_project();
        p.data.timeline.clips.truncate(1);
        p.data.timeline.clips[0].src_end_ns = 2 * l;
        p.events[0] = (1..=3)
            .map(|i| {
                serde_json::from_value::<Event>(json!({"t":l+i*100_000_000,"type":"key","key":"a"}))
                    .unwrap()
            })
            .collect();
        put_effects(&mut p, l + 150_000_009, l + 650_000_011);
        let before = p.data.clone();
        let changes = p
            .apply(&json!({"op":"auto_speed_typing","speed":3}))
            .unwrap();
        assert!(changes.changed.iter().any(|p| p == "canvas.highlights"));
        assert_effects(&p, l - 50_000_000 + 66_666_670, l + 316_666_678);
        let after = p.data.clone();
        let history = p.undo.len();
        assert!(p
            .apply(&json!({"op":"auto_speed_typing","speed":3}))
            .unwrap()
            .changed
            .is_empty());
        assert_eq!(p.data, after);
        assert_eq!(p.undo.len(), history);
        p.undo().unwrap();
        assert_eq!(p.data, before);
    }
    #[test]
    fn whole_duration_cut_removes_quantized_tail_and_preserves_source_edges() {
        let fixture = Fixture::new();
        let mut p = Project::create(&fixture.0).unwrap();
        p.data.autosave = false;
        p.data.timeline.clips[0].src_end_ns = 35;
        p.data.timeline.clips[0].speed = 32.0;
        assert_eq!(time::duration(&p.data.timeline.clips), 1);
        assert_eq!(
            time::timeline_boundary_to_source(&p.data.timeline.clips, 0, 1),
            Some(35)
        );
        let before = p.data.clone();
        p.apply(&json!({"op":"delete_range","tl_start_ns":0,"tl_end_ns":1}))
            .unwrap();
        assert!(p.data.timeline.clips.is_empty());
        p.undo().unwrap();
        assert_eq!(p.data, before);
    }
    #[test]
    fn effects_snapped_to_fractional_clip_edges_stay_snapped_after_speed_edit() {
        let fixture = Fixture::new();
        let mut p = Project::create(&fixture.0).unwrap();
        p.data.autosave = false;
        p.data.timeline.clips = vec![
            Clip {
                id: "fractional-prefix".into(),
                src_start_ns: 0,
                src_end_ns: 1,
                speed: 1.3,
            },
            Clip {
                id: "short-fast".into(),
                src_start_ns: 1,
                src_end_ns: 35,
                speed: 32.0,
            },
        ];
        assert_eq!(time::clip_bounds(&p.data.timeline.clips, 1), Some((1, 2)));
        put_effects(&mut p, 1, 2);
        p.apply(&json!({"op":"set_speed","clip_id":"short-fast","speed":0.05}))
            .unwrap();
        assert_eq!(time::clip_bounds(&p.data.timeline.clips, 1), Some((1, 681)));
        assert_effects(&p, 1, 681);
    }
}
