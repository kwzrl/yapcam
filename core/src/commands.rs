//! Cold-path commands are transactional. A failed batch changes neither data nor history.
use crate::{model::*, project::{Error, Project, Result, unique_id, validate_data}, time};
use serde::{Serialize, Deserialize};
use serde_json::Value;
#[derive(Debug, Default, Serialize, Deserialize)]
pub struct ChangeSet {
    pub changed: Vec<String>,
    #[serde(rename="createdIDs", alias="created_ids")]
    pub created_ids: Vec<String>,
}
fn int(v: &Value, key: &str) -> Result<i64> { v.get(key).and_then(Value::as_i64).ok_or_else(|| Error::new(1, format!("Missing integer {key}"))) }
fn string<'a>(v: &'a Value, key: &str) -> Result<&'a str> { v.get(key).and_then(Value::as_str).ok_or_else(|| Error::new(1, format!("Missing string {key}"))) }
fn number(v: &Value, key: &str) -> Result<f64> { v.get(key).and_then(Value::as_f64).ok_or_else(|| Error::new(1, format!("Missing number {key}"))) }
impl Project {
    pub fn apply(&mut self, command: &Value) -> Result<ChangeSet> {
        let mut next = self.data.clone(); let mut changes = ChangeSet::default();
        apply_inner(&mut next, command, &mut changes, 0, self)?;
        validate_data(&next)?;
        let end = self.session.segments.last().map_or(0, |s| s.src_start_ns + s.duration_ns);
        if next.timeline.clips.iter().any(|c| c.src_end_ns > end) { return Err(Error::new(1, "Clip outside recording")); }
        if next != self.data {
            next.modified_at = crate::project::timestamp();
            self.write_journal(&next)?;
            self.undo.push(std::mem::replace(&mut self.data, next)); self.redo.clear();
        }
        changes.changed.sort(); changes.changed.dedup();
        Ok(changes)
    }
    pub fn undo(&mut self) -> Result<bool> {
        if let Some(old)=self.undo.last() {self.write_journal(old)?;} else {return Ok(false);}
        self.redo.push(std::mem::replace(&mut self.data,self.undo.pop().unwrap()));Ok(true)
    }
    pub fn redo(&mut self) -> Result<bool> {
        if let Some(next)=self.redo.last() {self.write_journal(next)?;} else {return Ok(false);}
        self.undo.push(std::mem::replace(&mut self.data,self.redo.pop().unwrap()));Ok(true)
    }
}
fn apply_inner(p: &mut ProjectData, v: &Value, cs: &mut ChangeSet, depth: usize, context: &Project) -> Result<()> {
    if depth > 32 { return Err(Error::new(1, "Batch nesting exceeds 32")); }
    match string(v, "op")? {
        "batch" => {
            let commands = v.get("commands").and_then(Value::as_array).ok_or_else(|| Error::new(1, "Missing commands"))?;
            for cmd in commands { apply_inner(p, cmd, cs, depth+1, context)?; }
        }
        "split" => {
            let at = int(v, "at_tl_ns")?;
            if at <= 0 || at >= time::duration(&p.timeline.clips) { return Err(Error::new(1, "Split must be inside timeline")); }
            let (i, src) = time::timeline_to_source(&p.timeline.clips, at).ok_or_else(|| Error::new(1, "Split outside timeline"))?;
            let c = &mut p.timeline.clips[i];
            if src <= c.src_start_ns || src >= c.src_end_ns { return Err(Error::new(1, "Split is already a clip boundary")); }
            let mut right = c.clone(); right.id = unique_id("clip"); right.src_start_ns = src; c.src_end_ns = src;
            cs.created_ids.push(right.id.clone()); p.timeline.clips.insert(i+1, right); cs.changed.push("timeline".into());
        }
        "delete_range" => {
            let a = int(v, "tl_start_ns")?; let b = int(v, "tl_end_ns")?;
            if a < 0 || b <= a || b > time::duration(&p.timeline.clips) { return Err(Error::new(1, "Invalid delete range")); }
            let mut start = 0.0; let mut clips = Vec::new();
            for c in &p.timeline.clips {
                let end = start + time::clip_duration(c);
                if end <= a as f64 || start >= b as f64 { clips.push(c.clone()); }
                else {
                    let source = |t: f64| (c.src_start_ns + ((t-start)*c.speed).round() as i64).clamp(c.src_start_ns, c.src_end_ns);
                    if a as f64 > start { let mut left = c.clone(); left.src_end_ns = source(a as f64); if left.src_end_ns > left.src_start_ns { clips.push(left); } }
                    if (b as f64) < end { let mut right = c.clone(); right.src_start_ns = source(b as f64); if a as f64 > start { right.id = unique_id("clip"); cs.created_ids.push(right.id.clone()); } if right.src_end_ns > right.src_start_ns { clips.push(right); } }
                }
                start = end;
            }
            p.timeline.clips = clips;
            remap_effects(p, |t| if t < a { t } else if t >= b { t-(b-a) } else { a });
            cs.changed.extend(["timeline".into(), "zooms".into(), "camera.layouts".into()]);
        }
        "set_speed" => {
            let id = string(v, "clip_id")?; let speed = number(v, "speed")?;
            if !(0.05..=32.0).contains(&speed) { return Err(Error::new(1, "Speed must be 0.05…32")); }
            let i = p.timeline.clips.iter().position(|c| c.id == id).ok_or_else(|| Error::new(1, "Unknown clip id"))?;
            let start: f64 = p.timeline.clips[..i].iter().map(time::clip_duration).sum();
            let old = time::clip_duration(&p.timeline.clips[i]); p.timeline.clips[i].speed = speed;
            let new = time::clip_duration(&p.timeline.clips[i]);
            remap_effects(p, |t| { let t = t as f64; (if t < start { t } else if t < start+old { start + (t-start)*new/old } else { t+new-old }).round() as i64 });
            cs.changed.extend(["timeline".into(), "zooms".into(), "camera.layouts".into()]);
        }
        "add_zoom" => {
            let mut spec = v.get("zoom").cloned().unwrap_or_else(|| v.clone());
            spec.as_object_mut().ok_or_else(|| Error::new(1, "Zoom must be an object"))?.remove("op");
            let id = unique_id("zoom"); spec["id"] = id.clone().into();
            let z: Zoom = serde_json::from_value(spec)?; p.zooms.push(z); cs.created_ids.push(id); cs.changed.push("zooms".into());
        }
        "update_zoom" => {
            let id = string(v, "id")?; let patch = v.get("patch").and_then(Value::as_object).ok_or_else(|| Error::new(1, "Missing zoom patch"))?;
            let z = p.zooms.iter_mut().find(|z| z.id == id).ok_or_else(|| Error::new(1, "Unknown zoom id"))?;
            let mut spec = serde_json::to_value(&*z)?;
            for (k, val) in patch { if k == "id" || spec.get(k).is_none() { return Err(Error::new(1, "Unknown/immutable zoom key")); } spec[k] = val.clone(); }
            *z = serde_json::from_value(spec)?; cs.changed.push("zooms".into());
        }
        "remove_zoom" => {
            let id = string(v, "id")?; let i = p.zooms.iter().position(|z| z.id == id).ok_or_else(|| Error::new(1, "Unknown zoom id"))?;
            p.zooms.remove(i); cs.changed.push("zooms".into());
        }
        "process_silence" => {
            let ranges=v.get("ranges").and_then(Value::as_array).ok_or_else(||Error::new(1,"Missing silence ranges"))?;
            let mut spans=Vec::new();for r in ranges {let a=int(r,"tl_start_ns")?;let b=int(r,"tl_end_ns")?;if a<0 || b<=a || b>time::duration(&p.timeline.clips) {return Err(Error::new(1,"Invalid silence range"));}spans.push((a,b));}
            spans.sort();let mut merged:Vec<(i64,i64)>=Vec::new();
            for (a,b) in spans {if let Some(last)=merged.last_mut() {if a<=last.1 {last.1=last.1.max(b);continue;}}merged.push((a,b));}
            let mode=string(v,"mode")?;if mode!="cut" && mode!="speed" {return Err(Error::new(1,"Invalid silence operation"));}
            let speed=if mode=="speed" {number(v,"speed")?} else {1.0};
            for (a,b) in merged.into_iter().rev() {
                if mode=="cut" {apply_inner(p,&serde_json::json!({"op":"delete_range","tl_start_ns":a,"tl_end_ns":b}),cs,depth+1,context)?;}
                else {
                    for at in [b,a] {if at>0 && at<time::duration(&p.timeline.clips) {if let Some((i,src))=time::timeline_to_source(&p.timeline.clips,at) {if src>p.timeline.clips[i].src_start_ns {apply_inner(p,&serde_json::json!({"op":"split","at_tl_ns":at}),cs,depth+1,context)?;}}}}
                    let mut start:f64=0.0;let mut ids=Vec::new();
                    for c in &p.timeline.clips {let end=start+time::clip_duration(c);if start.round() as i64>=a && end.round() as i64<=b {ids.push(c.id.clone());}start=end;}
                    for id in ids {apply_inner(p,&serde_json::json!({"op":"set_speed","clip_id":id,"speed":speed}),cs,depth+1,context)?;}
                }
            }
        }
        "auto_zooms" => { crate::auto::generate_zooms(p, context, v, cs)?; }
        "auto_speed_typing" => { crate::auto::speed_typing(p, context, v, cs)?; }
        "apply_preset" => {
            let settings = v.get("preset").and_then(Value::as_object).ok_or_else(|| Error::new(1,"Missing preset"))?;
            let mut data = serde_json::to_value(&*p)?;
            for (key,value) in settings {
                if !matches!(key.as_str(), "canvas" | "cursor" | "camera" | "audio" | "zoom_settings" | "export") { return Err(Error::new(1,"Preset contains a non-setting field")); }
                data[key] = value.clone(); cs.changed.push(key.clone());
            }
            *p = serde_json::from_value(data)?;
        }
        "set" => {
            let path = string(v, "path")?; let parts: Vec<_> = path.split('.').collect();
            if (parts.len() < 2 && !matches!(path,"notes"|"autosave")) || !matches!(parts[0], "canvas" | "cursor" | "camera" | "audio" | "zoom_settings" | "export" | "notes" | "autosave") { return Err(Error::new(1, "Set path must reference a documented setting")); }
            let value = v.get("value").ok_or_else(|| Error::new(1, "Missing set value"))?;
            let mut data = serde_json::to_value(&*p)?; let mut target = &mut data;
            for part in &parts { target = target.get_mut(*part).ok_or_else(|| Error::new(1, format!("Unknown setting path: {path}")))?; }
            *target = value.clone(); *p = serde_json::from_value(data)?; cs.changed.push(path.into());
        }
        other => return Err(Error::new(1, format!("Unsupported command: {other}"))),
    }
    Ok(())
}
pub(crate) fn remap_effects(p: &mut ProjectData, map: impl Fn(i64)->i64) {
    for z in &mut p.zooms { z.tl_start_ns = map(z.tl_start_ns); z.tl_end_ns = map(z.tl_end_ns); }
    p.zooms.retain(|z| z.tl_end_ns > z.tl_start_ns);
    for l in &mut p.camera.layouts { l.tl_start_ns = map(l.tl_start_ns); l.tl_end_ns = map(l.tl_end_ns); }
    p.camera.layouts.retain(|l| l.tl_end_ns > l.tl_start_ns);
    for r in &mut p.cursor.ranges { r.tl_start_ns=map(r.tl_start_ns); r.tl_end_ns=map(r.tl_end_ns); }
    p.cursor.ranges.retain(|r| r.tl_end_ns>r.tl_start_ns);
    for r in &mut p.audio.ranges { r.tl_start_ns=map(r.tl_start_ns); r.tl_end_ns=map(r.tl_end_ns); }
    p.audio.ranges.retain(|r| r.tl_end_ns>r.tl_start_ns);
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::tests::Fixture;
    use serde_json::json;
    #[test]
    fn commands_and_undo_redo() {
        let f = Fixture::new(); let mut p = Project::create(&f.0).unwrap();
        let before = p.data.clone();
        p.apply(&json!({"op":"split","at_tl_ns":2_000_000_000})).unwrap();
        assert_eq!(p.data.timeline.clips.len(), 2);
        let id = p.data.timeline.clips[0].id.clone();
        p.apply(&json!({"op":"set_speed","clip_id":id,"speed":2.0})).unwrap();
        assert_eq!(time::duration(&p.data.timeline.clips), 4_000_000_000);
        let z = p.apply(&json!({"op":"add_zoom","tl_start_ns":100_000_000,"tl_end_ns":900_000_000,"mode":"manual","target":[0.5,0.5],"scale":2,"ease_in_ns":100_000_000,"ease_out_ns":100_000_000})).unwrap().created_ids[0].clone();
        p.apply(&json!({"op":"update_zoom","id":z,"patch":{"scale":3}})).unwrap();
        assert_eq!(p.data.zooms[0].scale, 3.0);
        p.apply(&json!({"op":"remove_zoom","id":z})).unwrap();
        p.apply(&json!({"op":"delete_range","tl_start_ns":1_000_000_000,"tl_end_ns":2_000_000_000})).unwrap();
        assert_eq!(time::duration(&p.data.timeline.clips), 3_000_000_000);
        p.apply(&json!({"op":"set","path":"canvas.padding","value":80})).unwrap();
        let after = p.data.clone(); let count = p.undo.len();
        for _ in 0..count { assert!(p.undo().unwrap()); } assert!(!p.undo().unwrap()); assert_eq!(p.data, before);
        for _ in 0..count { assert!(p.redo().unwrap()); } assert!(!p.redo().unwrap()); assert_eq!(p.data, after);
        p.undo().unwrap(); p.apply(&json!({"op":"set","path":"canvas.padding","value":45})).unwrap(); assert!(p.redo.is_empty());
    }
    #[test]
    fn batch_failure_is_atomic_and_success_one_step() {
        let f = Fixture::new(); let mut p = Project::create(&f.0).unwrap(); let original = p.data.clone();
        assert!(p.apply(&json!({"op":"batch","commands":[{"op":"set","path":"canvas.padding","value":60},{"op":"split","at_tl_ns":-1}]})).is_err());
        assert_eq!(p.data, original); assert!(p.undo.is_empty());
        p.apply(&json!({"op":"batch","commands":[{"op":"set","path":"canvas.padding","value":60},{"op":"set","path":"audio.mic_gain_db","value":-6}]})).unwrap();
        assert_eq!(p.undo.len(), 1); p.undo().unwrap(); assert_eq!(p.data, original);
        assert!(p.apply(&json!({"op":"set","path":"canvas.typo","value":1})).is_err());
        assert!(p.apply(&json!({"op":"set","path":"canvas","value":{}})).is_err());
        assert!(p.apply(&json!({"op":"set","path":"cursor.size","value":-1})).is_err());
    }
    #[test]
    fn deterministic_10000_random_edits_share_mapping() {
        let f = Fixture::new(); let mut p = Project::create(&f.0).unwrap();
        p.data.autosave=false; let base = p.data.clone(); let mut seed = 0x12345678u64; let mut successes = 0;
        for n in 0..12_000 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
            if time::duration(&p.data.timeline.clips) < 20_000_000 || p.data.timeline.clips.len() > 100 { p.data = base.clone(); }
            let d = time::duration(&p.data.timeline.clips);
            let command = match n % 3 {
                0 => json!({"op":"split", "at_tl_ns":1 + (seed % (d-1) as u64) as i64}),
                1 => { let a = (seed % (d/2) as u64) as i64; json!({"op":"delete_range","tl_start_ns":a,"tl_end_ns":a+d/10}) },
                _ => { let c = &p.data.timeline.clips[seed as usize % p.data.timeline.clips.len()]; json!({"op":"set_speed","clip_id":c.id,"speed":([0.5,1.0,1.25,2.0,3.0][(seed >> 16) as usize % 5])}) },
            };
            if p.apply(&command).is_ok() { successes += 1; }
            p.undo.clear();
            let d = time::duration(&p.data.timeline.clips);
            for fraction in [0.0, 0.13, 0.51, 0.97] {
                let t = (d as f64 * fraction) as i64;
                let (i, src) = time::timeline_to_source(&p.data.timeline.clips, t).unwrap();
                let back = time::source_to_timeline(&p.data.timeline.clips, i, src).unwrap();
                assert!((t-back).abs() <= 2, "round-trip {t} vs {back}");
                let video = time::sample(&p.session, "screen", src); let audio = time::sample(&p.session, "system_audio", src);
                assert_eq!(video.src_ns, audio.src_ns); assert_eq!(video.segment, audio.segment); assert_eq!(video.file_ns, audio.file_ns);
                let segment = &p.session.segments[video.segment as usize];
                assert_eq!(src-segment.src_start_ns, video.file_ns); // event clock is the same
            }
        }
        assert!(successes >= 10_000, "{successes} successful operations");
    }
    #[test]
    fn splitting_does_not_accumulate_fractional_duration_error() {
        let f = Fixture::new(); let mut p = Project::create(&f.0).unwrap();
        p.data.autosave=false; p.data.timeline.clips[0].speed = 1.3;
        let original = time::duration(&p.data.timeline.clips);
        for n in 1i64..1000 { p.apply(&json!({"op":"split","at_tl_ns":n*3_000_001})).unwrap(); p.undo.clear(); }
        assert_eq!(time::duration(&p.data.timeline.clips), original);
    }
}
