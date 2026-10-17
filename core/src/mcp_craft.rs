//! Intention-level MCP edits. Public clocks are seconds; commands remain ns.
use crate::{
    mcp::Server,
    project::{Error, Result},
    time,
};
use serde_json::{json, Value};
const SECOND: i64 = 1_000_000_000;
fn bad(s: &str) -> Error {
    Error::new(1, s)
}
fn seconds(t: i64) -> f64 {
    t as f64 / SECOND as f64
}
fn clock(t: i64) -> String {
    format!("{}:{:02}", t / SECOND / 60, t / SECOND % 60)
}
fn number(a: &Value, key: &str, default: f64) -> Result<f64> {
    a.get(key).map_or(Ok(default), |v| {
        v.as_f64()
            .filter(|v| v.is_finite() && *v >= 0.0 && *v < i64::MAX as f64 / SECOND as f64)
            .ok_or_else(|| bad("Expected finite, nonnegative seconds/number"))
    })
}
fn ns(a: &Value, key: &str, default: i64) -> Result<i64> {
    Ok((number(a, key, seconds(default))? * SECOND as f64).round() as i64)
}
#[derive(Clone)]
struct Word {
    text: String,
    start: i64,
    end: i64,
    timed: bool,
}
impl Server<'_> {
    fn craft_words(&self) -> Result<(Vec<Word>, bool)> {
        // User-authored caption cards are not speech. Prefer explicit word timings,
        // then the immutable recording transcript; expose untimed cards only as spans.
        let timed = self
            .project
            .data
            .canvas
            .captions
            .iter()
            .any(|c| !c.words.is_empty());
        let mut transcript = self.transcript(if timed { "captions" } else { "recording" })?;
        if transcript["available"] != true {
            transcript = self.transcript("captions")?;
        }
        let mut words: Vec<_> = transcript["words"]
            .as_array()
            .unwrap()
            .iter()
            .map(|w| {
                let is_timed = if transcript["source"] == "recording" {
                    true
                } else {
                    self.project
                        .data
                        .canvas
                        .captions
                        .iter()
                        .find(|c| w["caption_id"] == c.id)
                        .is_some_and(|c| !c.words.is_empty())
                };
                Word {
                    text: w["text"].as_str().unwrap_or("").into(),
                    start: w["tl_start_ns"].as_i64().unwrap(),
                    end: w["tl_end_ns"].as_i64().unwrap(),
                    timed: is_timed,
                }
            })
            .collect();
        // Ignore untimed title cards when real speech timing is available.
        if words.iter().any(|w| w.timed) {
            words.retain(|w| w.timed);
        }
        words.sort_by_key(|w| (w.start, w.end));
        words.dedup_by(|a, b| a.start == b.start && a.end == b.end && a.text == b.text);
        Ok((words, transcript["available"] == true))
    }
    fn craft_bounds(&self, a: &Value) -> Result<(i64, i64)> {
        let end = time::duration(&self.project.data.timeline.clips);
        let from = ns(a, "from_s", 0)?;
        let to = ns(a, "to_s", end)?;
        if to < from {
            return Err(bad("to_s precedes from_s"));
        }
        Ok((from.min(end), to.min(end)))
    }
    pub(crate) fn craft(&mut self, name: &str, a: &Value) -> Result<Value> {
        match name {
            "moments" => self.moments(a),
            "check" => self.craft_check(),
            "zoom_on_click" => self.zoom_on_click(a),
            _ => self.word_edit(name, a),
        }
    }
    fn moments(&self, a: &Value) -> Result<Value> {
        let (from, to) = self.craft_bounds(a)?;
        let (words, available) = self.craft_words()?;
        let mut rows = vec![];
        let mut i = 0;
        while i < words.len() {
            let first = i;
            let mut end = words[i].end;
            while i + 1 < words.len()
                && !words[i].text.ends_with(['.', '!', '?'])
                && words[i + 1].start - end < 800_000_000
                && words[i].timed == words[i + 1].timed
            {
                i += 1;
                end = end.max(words[i].end);
            }
            rows.push(json!({"kind":"sentence","start_s":seconds(words[first].start),"end_s":seconds(end),"text":words[first..=i].iter().map(|w|w.text.as_str()).collect::<Vec<_>>().join(" "),"from_word_index":first,"to_word_index":i,"word_timing":words[first].timed,"words":words[first..=i].iter().enumerate().map(|(j,w)| json!({"word_index":first+j,"text":w.text,"start_s":seconds(w.start),"end_s":seconds(w.end)})).collect::<Vec<_>>()}));
            i += 1;
        }
        let events = self.project.query(&json!({"q":"events"}))?;
        let mut click_index = 0;
        for e in events.as_array().unwrap() {
            if e["type"] != "down" && e["type"] != "key" {
                continue;
            }
            let t = e["tl_ns"].as_i64().unwrap();
            if e["type"] == "down" {
                // Focus metadata must be found in SOURCE time, even if its event
                // was cut out of the edited timeline before this click.
                let src = e["src_ns"].as_i64().unwrap();
                let mut app = self.project.session.source.app_bundle_id.clone();
                let mut title = self.project.session.source.window_title.clone();
                for (segment, input) in self
                    .project
                    .session
                    .segments
                    .iter()
                    .zip(&self.project.events)
                {
                    for event in input {
                        if event.kind == "focus" && segment.src_start_ns + event.t <= src {
                            app = event
                                .details
                                .get("app_bundle_id")
                                .and_then(Value::as_str)
                                .map(str::to_owned);
                            title = event
                                .details
                                .get("window_title")
                                .and_then(Value::as_str)
                                .map(str::to_owned);
                        }
                    }
                }
                rows.push(json!({"kind":"click","start_s":seconds(t),"click_index":click_index,"x":e["x"],"y":e["y"],"button":e["button"],"app_bundle_id":app,"window_title":title}));
                click_index += 1;
            } else {
                rows.push(json!({"kind":"key","start_s":seconds(t),"key":e["key"],"modifiers":e["modifiers"]}));
            }
        }
        // Include dismissed bursts too: dismissal changes suggestions, not history.
        let mut p = self.project.clone();
        p.data.typing.dismissed.clear();
        for phase in p
            .query(&json!({"q":"typing_suggestions"}))?
            .as_array()
            .unwrap()
        {
            for r in phase["ranges"].as_array().unwrap() {
                rows.push(json!({"kind":"typing","id":phase["id"],"start_s":seconds(r["tl_start_ns"].as_i64().unwrap()),"end_s":seconds(r["tl_end_ns"].as_i64().unwrap()),"key_count":phase["key_count"]}));
            }
        }
        for z in &self.project.data.zooms {
            rows.push(json!({"kind":"zoom","id":z.id,"start_s":seconds(z.tl_start_ns),"end_s":seconds(z.tl_end_ns),"scale":z.scale,"enabled":z.enabled}));
        }
        let clips = &self.project.data.timeline.clips;
        for (i, c) in clips.iter().enumerate() {
            if (i == 0 && c.src_start_ns > 0)
                || (i > 0 && clips[i - 1].src_end_ns != c.src_start_ns)
            {
                rows.push(json!({"kind":"cut","start_s":seconds(time::clip_bounds(clips,i).unwrap().0),"source_from_s":seconds(if i==0 {0} else {clips[i-1].src_end_ns}),"source_to_s":seconds(c.src_start_ns)}));
            }
        }
        if let Some(c) = clips.last() {
            let source_end = self
                .project
                .session
                .segments
                .last()
                .map_or(0, |s| s.src_start_ns + s.duration_ns);
            if c.src_end_ns < source_end {
                rows.push(json!({"kind":"cut","start_s":seconds(time::duration(clips)),"source_from_s":seconds(c.src_end_ns),"source_to_s":seconds(source_end)}));
            }
        }
        rows.retain(|r| {
            let t = r["start_s"].as_f64().unwrap();
            (t < seconds(to)
                || (r["kind"] == "cut" && t == seconds(to) && to == time::duration(clips)))
                && r["end_s"]
                    .as_f64()
                    .map_or(t >= seconds(from), |end| end > seconds(from))
        });
        rows.sort_by(|a, b| {
            a["start_s"]
                .as_f64()
                .partial_cmp(&b["start_s"].as_f64())
                .unwrap()
        });
        Ok(
            json!({"duration_s":seconds(time::duration(clips)),"transcript_available":available,"word_timing_available":!words.is_empty() && words.iter().all(|w|w.timed),"moments":rows,"note":"Times are current timeline seconds; indices are zero-based and global before range filtering. Re-read after edits. Click x/y are capture points, not normalized coordinates."}),
        )
    }
    fn cut_ranges(&mut self, mut ranges: Vec<(i64, i64)>, noun: &str) -> Result<Value> {
        let duration = time::duration(&self.project.data.timeline.clips);
        for (a, b) in &mut ranges {
            *a = (*a).clamp(0, duration);
            *b = (*b).clamp(0, duration);
        }
        ranges.retain(|(a, b)| b > a);
        ranges.sort_unstable();
        let mut merged: Vec<(i64, i64)> = vec![];
        for (a, b) in ranges {
            if let Some(last) = merged.last_mut().filter(|r| a <= r.1) {
                last.1 = last.1.max(b);
            } else {
                merged.push((a, b));
            }
        }
        let total: i64 = merged.iter().map(|(a, b)| b - a).sum();
        if total >= duration && total > 0 {
            return Err(bad(
                "This would remove the entire recording; retain at least one word or clip.",
            ));
        }
        let commands: Vec<_> = merged
            .iter()
            .rev()
            .map(|(a, b)| json!({"op":"delete_range","tl_start_ns":a,"tl_end_ns":b}))
            .collect();
        let change = if commands.is_empty() {
            Value::Null
        } else {
            serde_json::to_value(
                self.project
                    .apply(&json!({"op":"batch","commands":commands}))?,
            )?
        };
        Ok(
            json!({"changed":!merged.is_empty(),"message":if merged.is_empty() {format!("No {noun} to remove.")} else {format!("Removed {} {} ({:.2} s total) at {}",merged.len(),if merged.len()==1 {noun.trim_end_matches('s')} else {noun},seconds(total),merged.iter().map(|(a,_)|clock(*a)).collect::<Vec<_>>().join(", "))},"removed_count":merged.len(),"removed_s":seconds(total),"ranges":merged.iter().map(|(a,b)|json!({"from_s":seconds(*a),"to_s":seconds(*b)})).collect::<Vec<_>>(),"change":change}),
        )
    }
    fn word_edit(&mut self, name: &str, a: &Value) -> Result<Value> {
        let (words, _) = self.craft_words()?;
        if words.is_empty() || words.iter().any(|w| !w.timed) {
            return Err(bad("Word timing is unavailable. Transcribe first; caption cards alone are not evidence of speech or silence."));
        }
        let duration = time::duration(&self.project.data.timeline.clips);
        match name {
            "trim_start_to_first_word" => {
                let lead = ns(a, "lead_s", 100_000_000)?.min(500_000_000);
                self.cut_ranges(vec![(0, (words[0].start - lead).max(0))], "opening pauses")
            }
            "tighten_pauses" => {
                let (from, to) = self.craft_bounds(a)?;
                let max_gap = ns(a, "max_gap_s", 500_000_000)?;
                let keep = ns(a, "keep_s", 350_000_000)?.clamp(300_000_000, 500_000_000);
                if max_gap < keep {
                    return Err(bad(
                        "max_gap_s must be at least keep_s (clamped to 0.3–0.5 seconds).",
                    ));
                }
                let mut ranges = vec![];
                // Running maximum handles overlapping recognizer words safely.
                let mut end = words[0].end;
                for w in &words[1..] {
                    if w.start - end > max_gap {
                        let x = (end + keep / 2).max(from);
                        let y = (w.start - (keep - keep / 2)).min(to);
                        if y > x {
                            ranges.push((x, y));
                        }
                    }
                    end = end.max(w.end);
                }
                if to == duration && duration - end > 800_000_000 {
                    ranges.push(((end + 800_000_000).max(from), duration));
                }
                self.cut_ranges(ranges, "pauses")
            }
            "cut_words" | "remove_fillers" => {
                let mut selected = vec![false; words.len()];
                if name == "cut_words" {
                    let first = a["from_word_index"]
                        .as_u64()
                        .ok_or_else(|| bad("from_word_index must be a zero-based integer"))?
                        as usize;
                    let last = a["to_word_index"].as_u64().ok_or_else(|| {
                        bad("to_word_index must be an inclusive zero-based integer")
                    })? as usize;
                    if first > last || last >= words.len() {
                        return Err(bad(
                            "Word index out of range; read moments again after edits.",
                        ));
                    }
                    selected[first..=last].fill(true);
                } else {
                    let defaults = json!(["um", "uh", "erm", "er", "hmm"]);
                    let fillers = a
                        .get("words")
                        .unwrap_or(&defaults)
                        .as_array()
                        .ok_or_else(|| bad("words must be an array of filler strings"))?;
                    let fillers = fillers
                        .iter()
                        .map(|w| {
                            w.as_str()
                                .filter(|s| {
                                    !s.trim().is_empty() && s.split_whitespace().count() == 1
                                })
                                .map(normalize)
                                .ok_or_else(|| bad("Each filler must be one nonempty word"))
                        })
                        .collect::<Result<Vec<_>>>()?;
                    for (i, w) in words.iter().enumerate() {
                        selected[i] = fillers.contains(&normalize(&w.text));
                    }
                }
                let mut ranges = vec![];
                let mut i = 0;
                while i < words.len() {
                    if !selected[i] {
                        i += 1;
                        continue;
                    }
                    let first = i;
                    let mut end = words[i].end;
                    while i + 1 < words.len() && selected[i + 1] {
                        i += 1;
                        end = end.max(words[i].end);
                    }
                    let previous = words[..first].iter().map(|w| w.end).max().unwrap_or(0);
                    let next = words.get(i + 1).map_or(duration, |w| w.start);
                    if previous > words[first].start || next < end {
                        return Err(bad("Selected words overlap retained speech; refusing to cut inside another word."));
                    }
                    let (start, end) = if first == 0 && i + 1 == words.len() {
                        (0, duration)
                    } else if first == 0 {
                        (
                            0,
                            words
                                .get(i + 1)
                                .unwrap()
                                .start
                                .saturating_sub(100_000_000)
                                .max(end),
                        )
                    } else if i + 1 == words.len() {
                        (words[first].start.min(previous + 350_000_000), duration)
                    } else {
                        let left = (words[first].start - previous).min(175_000_000);
                        let right = (next - end).min(350_000_000 - left);
                        let left = (words[first].start - previous).min(350_000_000 - right);
                        (previous + left, next - right)
                    };
                    ranges.push((start, end));
                    i += 1;
                }
                let text = words
                    .iter()
                    .zip(&selected)
                    .filter(|(_, s)| **s)
                    .map(|(w, _)| w.text.as_str())
                    .collect::<Vec<_>>()
                    .join(" ");
                let mut result = self.cut_ranges(
                    ranges,
                    if name == "cut_words" {
                        "word ranges"
                    } else {
                        "fillers"
                    },
                )?;
                result["text"] = text.into();
                Ok(result)
            }
            _ => Err(bad("Unknown craft tool")),
        }
    }
    fn zoom_on_click(&mut self, a: &Value) -> Result<Value> {
        if a.get("click_index").is_some() == a.get("at_s").is_some() {
            return Err(bad("Supply exactly one of click_index or at_s."));
        }
        let events = self.project.query(&json!({"q":"events"}))?;
        let clicks: Vec<_> = events
            .as_array()
            .unwrap()
            .iter()
            .filter(|e| e["type"] == "down")
            .collect();
        let index = if let Some(i) = a.get("click_index") {
            i.as_u64()
                .ok_or_else(|| bad("click_index must be a zero-based integer"))?
                as usize
        } else {
            let at = ns(a, "at_s", 0)?;
            clicks
                .iter()
                .enumerate()
                .min_by_key(|(_, c)| (c["tl_ns"].as_i64().unwrap() - at).abs())
                .filter(|(_, c)| (c["tl_ns"].as_i64().unwrap() - at).abs() <= 250_000_000)
                .map(|(i, _)| i)
                .ok_or_else(|| {
                    bad("No click within 0.25 seconds of at_s; use a click_index from moments.")
                })?
        };
        let click = clicks
            .get(index)
            .ok_or_else(|| bad("click_index out of range; read moments again."))?;
        let t = click["tl_ns"].as_i64().unwrap();
        let x = click["x"]
            .as_f64()
            .ok_or_else(|| bad("Click has no captured position"))?;
        let y = click["y"]
            .as_f64()
            .ok_or_else(|| bad("Click has no captured position"))?;
        let geometry = self.project.session.source.content_rect_points;
        if x < 0.0 || y < 0.0 || x > geometry[2] || y > geometry[3] {
            return Err(bad(
                "Click lies outside the captured picture; choose another click.",
            ));
        }
        let scale = number(a, "scale", 1.8)?;
        if !(1.05..=4.0).contains(&scale) {
            return Err(bad("Craft zoom scale must be between 1.05 and 4."));
        }
        let lead = ns(a, "lead_s", 400_000_000)?.min(2 * SECOND);
        let hold = ns(a, "hold_s", 1_600_000_000)?.clamp(SECOND, 6 * SECOND);
        let duration = time::duration(&self.project.data.timeline.clips);
        let mut start = (t - lead).max(0);
        let mut end = t.saturating_add(hold).min(duration);
        let active: Vec<_> = self
            .project
            .data
            .zooms
            .iter()
            .filter(|z| {
                z.enabled && (z.mode != "auto" || self.project.data.zoom_settings.automatic)
            })
            .collect();
        for z in &active {
            if z.tl_start_ns <= t && t < z.tl_end_ns {
                return Err(bad("This click already has a zoom. Update or remove that zoom instead of overlapping it."));
            }
            if z.tl_end_ns <= t {
                start = start.max(z.tl_end_ns);
            }
            if z.tl_start_ns > t {
                end = end.min(z.tl_start_ns);
            }
        }
        if end - start < SECOND {
            return Err(bad(
                "Less than 1 second is free around this click before another zoom or the end.",
            ));
        }
        // A rolling minute limit avoids bursts even on short recordings.
        let mut starts: Vec<_> = active.iter().map(|z| z.tl_start_ns).collect();
        starts.push(start);
        starts.sort_unstable();
        if starts
            .windows(7)
            .any(|w| w[6] - w[0] < 60 * SECOND && w[0] <= start && start <= w[6])
        {
            return Err(bad("Zoom budget reached: at most 6 zooms in any minute. Choose fewer important clicks."));
        }
        let change=self.project.apply(&json!({"op":"batch","commands":[{"op":"add_zoom","mode":"manual","target":[x/geometry[2],y/geometry[3]],"scale":scale,"tl_start_ns":start,"tl_end_ns":end,"ease_in_ns":300_000_000,"ease_out_ns":300_000_000}]}))?;
        Ok(
            json!({"changed":true,"message":format!("Zoom {scale}× on click {} ({}–{})",clock(t),clock(start),clock(end)),"click_index":index,"at_s":seconds(t),"from_s":seconds(start),"to_s":seconds(end),"scale":scale,"change":change}),
        )
    }
}
fn normalize(s: &str) -> String {
    s.trim_matches(|c: char| !c.is_alphanumeric())
        .to_lowercase()
}
impl Server<'_> {
    fn craft_check(&self) -> Result<Value> {
        let p = &self.project.data;
        let duration = time::duration(&p.timeline.clips);
        let (words, available) = self.craft_words()?;
        let mut issues = vec![];
        let mut issue = |severity: &str, kind: &str, at: i64, message: String, hint: &str| {
            issues.push(json!({"severity":severity,"kind":kind,"at_s":seconds(at),"message":message,"fix_hint":hint}));
        };
        let zooms: Vec<_> = p
            .zooms
            .iter()
            .filter(|z| z.enabled && (z.mode != "auto" || p.zoom_settings.automatic))
            .collect();
        for (i, z) in zooms.iter().enumerate() {
            if z.tl_end_ns > duration {
                issue(
                    "error",
                    "zoom_past_end",
                    z.tl_start_ns,
                    format!("Zoom '{}' ends after the timeline.", z.id),
                    "Shorten or remove the zoom with update_zoom/remove_zoom via apply.",
                );
            }
            if z.tl_end_ns - z.tl_start_ns < SECOND || z.tl_end_ns - z.tl_start_ns > 8 * SECOND {
                issue(
                    "warning",
                    "zoom_duration",
                    z.tl_start_ns,
                    format!(
                        "Zoom '{}' lasts {:.2} s; prefer 1–8 s.",
                        z.id,
                        seconds(z.tl_end_ns - z.tl_start_ns)
                    ),
                    "Adjust the zoom endpoints; prefer zoom_on_click for new zooms.",
                );
            }
            for other in &zooms[..i] {
                if z.tl_start_ns < other.tl_end_ns && other.tl_start_ns < z.tl_end_ns {
                    issue(
                        "warning",
                        "overlapping_zooms",
                        z.tl_start_ns.max(other.tl_start_ns),
                        format!("Zooms '{}' and '{}' overlap.", other.id, z.id),
                        "Remove one zoom or trim the endpoints so they do not overlap.",
                    );
                }
            }
        }
        if words.iter().any(|w| w.timed) {
            if words[0].start > 500_000_000 {
                issue(
                    "warning",
                    "dead_air_start",
                    0,
                    format!(
                        "First transcribed word begins at {:.2} s.",
                        seconds(words[0].start)
                    ),
                    "Use trim_start_to_first_word; verify the transcript covers the opening.",
                );
            }
            let mut end = words[0].end;
            for w in &words[1..] {
                if w.start - end > 1_200_000_000 {
                    issue(
                        "warning",
                        "long_pause",
                        end,
                        format!("{:.2} s between transcribed words.", seconds(w.start - end)),
                        "Review the gap, then tighten_pauses to retain 0.35 s breathing room.",
                    );
                }
                end = end.max(w.end);
            }
            if duration - end > 800_000_000 {
                issue("warning","long_tail",end,format!("{:.2} s after the last transcribed word.",seconds(duration-end)),"Use tighten_pauses to retain at most 0.8 s of tail; verify transcript coverage.");
            }
        }
        // Timeline captions have already been clipped, so use original word
        // boundaries to detect partial-word cuts. Contiguous splits are not cuts.
        let original = self.transcript("recording")?;
        if let Some(source_words) = original["source_words"].as_array() {
            for (i, c) in p.timeline.clips.iter().enumerate() {
                let (start, end) = time::clip_bounds(&p.timeline.clips, i).unwrap();
                let boundaries = [
                    (
                        c.src_start_ns,
                        start,
                        i == 0 || p.timeline.clips[i - 1].src_end_ns != c.src_start_ns,
                    ),
                    (
                        c.src_end_ns,
                        end,
                        i + 1 == p.timeline.clips.len()
                            || p.timeline.clips[i + 1].src_start_ns != c.src_end_ns,
                    ),
                ];
                for (src, at, cut) in boundaries {
                    if cut {
                        for w in source_words {
                            if w["src_start_ns"].as_i64().is_some_and(|s| s < src)
                                && w["src_end_ns"].as_i64().is_some_and(|e| src < e)
                            {
                                issue(
                                    "error",
                                    "cut_inside_word",
                                    at,
                                    format!(
                                        "Cut intersects the source word '{}'.",
                                        w["text"].as_str().unwrap_or("")
                                    ),
                                    "Undo the cut, then use cut_words with indices from moments.",
                                );
                            }
                        }
                    }
                }
            }
        }
        for (i, c) in p.canvas.captions.iter().enumerate() {
            for other in &p.canvas.captions[..i] {
                if c.tl_start_ns < other.tl_end_ns && other.tl_start_ns < c.tl_end_ns {
                    issue(
                        "warning",
                        "captions_overlapping",
                        c.tl_start_ns.max(other.tl_start_ns),
                        format!("Captions '{}' and '{}' overlap.", other.id, c.id),
                        "Adjust caption timing or remove duplicate captions.",
                    );
                }
            }
        }
        // All persisted timeline records share these endpoint names.
        fn intervals(value: &Value, path: &str, out: &mut Vec<(String, i64, i64)>) {
            match value {
                Value::Object(o) => {
                    if let (Some(a), Some(b)) = (
                        o.get("tl_start_ns").and_then(Value::as_i64),
                        o.get("tl_end_ns").and_then(Value::as_i64),
                    ) {
                        out.push((path.into(), a, b));
                    }
                    for (k, v) in o {
                        intervals(v, &format!("{path}.{k}"), out);
                    }
                }
                Value::Array(a) => {
                    for (i, v) in a.iter().enumerate() {
                        intervals(v, &format!("{path}[{i}]"), out);
                    }
                }
                _ => {}
            }
        }
        let mut records = vec![];
        intervals(&serde_json::to_value(p)?, "project", &mut records);
        for (path, start, end) in records {
            if end > duration && !path.starts_with("project.zooms[") {
                issue(
                    "error",
                    "item_after_end",
                    start,
                    format!("{path} extends beyond the timeline."),
                    "Shorten or remove this timeline item.",
                );
            }
        }
        if duration == 0 {
            issue(
                "error",
                "empty_timeline",
                0,
                "The timeline contains no frames.".into(),
                "Undo the last cut or restore source media.",
            );
        }
        for (i, c) in p.timeline.clips.iter().enumerate() {
            for s in &self.project.session.segments {
                if c.src_start_ns < s.src_start_ns + s.duration_ns && c.src_end_ns > s.src_start_ns
                {
                    if let Some(file) = s.files.get("screen") {
                        let missing = crate::project::relative_path(
                            &self.project.package,
                            &format!("recording/{file}"),
                        )
                        .map_or(true, |path| !path.is_file());
                        if missing {
                            issue(
                                "error",
                                "missing_screen_media",
                                time::clip_bounds(&p.timeline.clips, i).unwrap().0,
                                "A retained clip's screen media is missing.".into(),
                                "Restore the recording media before rendering or exporting.",
                            );
                        }
                    }
                }
            }
        }
        issues.sort_by(|a, b| a["at_s"].as_f64().partial_cmp(&b["at_s"].as_f64()).unwrap());
        issues.dedup();
        Ok(
            json!({"issues":issues,"duration_s":seconds(duration),"transcript_available":available,"word_timing_available":!words.is_empty() && words.iter().all(|w|w.timed),"limitations":["Transcript gaps are timing candidates, not acoustic silence detection.","Without the original recording transcript, cuts inside source words cannot be checked.","Black pixels and composition quality require capture/filmstrip; this structural check does not decode video."]}),
        )
    }
}
pub(crate) fn catalog() -> Vec<Value> {
    let range =
        json!({"from_s":{"type":"number","minimum":0},"to_s":{"type":"number","minimum":0}});
    let mut pauses = range.clone();
    pauses["max_gap_s"] = json!({"type":"number","default":0.5,"minimum":0.3});
    pauses["keep_s"] = json!({"type":"number","default":0.35,"minimum":0.3,"maximum":0.5});
    vec![
        ("moments","Start here: one chronological timeline of sentences with word indices/timings, clicks with capture-point x/y and known app/window, shortcuts, typing, zooms and cuts. All times SECONDS. Indices are zero-based/global; re-read after edits. Example: moments {}.",range,vec![]),
        ("check","Verify after every edit stage: structural errors and craft warnings with severity, kind, at_s in SECONDS, message and fix_hint. Checks source-word cuts when original transcript exists; no pixel analysis. Follow with capture to verify appearance. Example: check {}.",json!({}),vec![]),
        ("cut_words","Remove an inclusive range of word indices from moments; snap to timed speech boundaries, retain up to 0.35 s breathing room, ripple all tracks. One undo step. Requires word timing, refuses overlaps with retained speech. Example: cut_words {\"from_word_index\":3,\"to_word_index\":4}.",json!({"from_word_index":{"type":"integer","minimum":0},"to_word_index":{"type":"integer","minimum":0}}),vec!["from_word_index","to_word_index"]),
        ("tighten_pauses","Tighten gaps between timed transcript words over max_gap_s (default 0.5 SECONDS), retaining keep_s (default 0.35, clamped 0.3–0.5). Also trim tail to 0.8 s when range reaches end. Transcript gaps need review; missing words do not prove silence. One undo step. Example: tighten_pauses {\"max_gap_s\":0.5,\"keep_s\":0.35}.",pauses,vec![]),
        ("remove_fillers","Remove exact case-insensitive timed filler words, ignoring surrounding punctuation. Defaults um, uh, erm, er, hmm; never automatically remove like/so/also. Keeps breathing room and makes one undo step. Example: remove_fillers {\"words\":[\"um\",\"uh\"]}.",json!({"words":{"type":"array","items":{"type":"string"}}}),vec![]),
        ("trim_start_to_first_word","Trim opening to first timed word minus lead_s (default 0.1 SECONDS, clamped 0–0.5). No transcript means an explicit error, never guessed silence. One undo step. Example: trim_start_to_first_word {\"lead_s\":0.1}.",json!({"lead_s":{"type":"number","default":0.1,"minimum":0,"maximum":0.5}}),vec![]),
        ("zoom_on_click","Focus an important captured click by global click_index from moments OR at_s (nearest click within 0.25 SECONDS). Default scale 1.8, lead_s 0.4, hold_s 1.6; eased 0.3 s, clamped to timeline and free interval, 1–8 s long, max 6/minute. Refuses a click already zoomed; update/remove existing zoom via apply instead. One undo step. Example: zoom_on_click {\"click_index\":0}.",json!({"click_index":{"type":"integer","minimum":0},"at_s":{"type":"number","minimum":0},"scale":{"type":"number","default":1.8,"minimum":1.05,"maximum":4},"lead_s":{"type":"number","default":0.4,"minimum":0},"hold_s":{"type":"number","default":1.6,"minimum":0}}),vec![]),
    ].into_iter().map(|(name,description,properties,required)| json!({"name":name,"description":description,"inputSchema":{"type":"object","properties":properties,"required":required,"additionalProperties":false},"annotations":{"readOnlyHint":name=="moments" || name=="check","openWorldHint":false}})).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        model::TextRecord,
        project::{tests::Fixture, Project},
    };
    fn setup() -> (Fixture, Project) {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.snapshot = true;
        p.data.zooms.clear();
        (f, p)
    }
    fn transcript(p: &mut Project, rows: Value) {
        let data =
            json!({"schema_version":1,"engine":"synthetic-test","locale":"en-US","words":rows});
        std::fs::write(
            p.package.join("recording/transcript.json"),
            data.to_string(),
        )
        .unwrap();
    }
    fn speech(p: &mut Project) {
        transcript(
            p,
            json!([
                {"text":"Hello.","src_start_ns":600_000_000,"src_end_ns":900_000_000},
                {"text":"Um,","src_start_ns":1_300_000_000,"src_end_ns":1_500_000_000},
                {"text":"Deploy","src_start_ns":3_000_000_000_i64,"src_end_ns":3_400_000_000_i64},
                {"text":"now.","src_start_ns":3_500_000_000_i64,"src_end_ns":3_800_000_000_i64}
            ]),
        );
    }
    fn call(p: &mut Project, name: &str, args: Value) -> Value {
        Server {
            project: p,
            initialized: true,
        }
        .craft(name, &args)
        .unwrap()
    }
    fn kinds(p: &mut Project) -> Vec<String> {
        call(p, "check", json!({}))["issues"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v["kind"].as_str().unwrap().into())
            .collect()
    }
    #[test]
    fn word_tools_atomic_and_noop_history() {
        let (_f, mut p) = setup();
        speech(&mut p);
        for (name, args, total) in [
            ("trim_start_to_first_word", json!({}), 0.5),
            ("tighten_pauses", json!({}), 1.55),
            ("remove_fillers", json!({}), 1.75),
            (
                "cut_words",
                json!({"from_word_index":1,"to_word_index":1}),
                1.75,
            ),
        ] {
            let before = p.data.clone();
            let depth = p.undo.len();
            let result = call(&mut p, name, args);
            assert!(
                (result["removed_s"].as_f64().unwrap() - total).abs() < 1e-8,
                "{name}: {result}"
            );
            assert_eq!(p.undo.len(), depth + 1);
            if name == "tighten_pauses" {
                let duration = seconds(time::duration(&p.data.timeline.clips));
                let moments = call(&mut p, "moments", json!({}));
                assert!(moments["moments"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|m| m["kind"] == "cut" && m["start_s"] == duration));
            }
            assert!(p.undo().unwrap());
            assert_eq!(p.data, before);
        }
        call(&mut p, "remove_fillers", json!({"words":["uh"]}));
        assert!(p.undo.is_empty());
        let result = call(&mut p, "tighten_pauses", json!({"from_s":1.7,"to_s":2.4}));
        assert_eq!(result["removed_s"], 0.7);
    }
    #[test]
    fn missing_and_untimed_speech_refused_and_invalid_args_atomic() {
        let (_f, mut p) = setup();
        p.data.canvas.captions.push(TextRecord {
            id: "title".into(),
            text: "A title card".into(),
            tl_start_ns: 0,
            tl_end_ns: SECOND,
            ..Default::default()
        });
        for name in [
            "trim_start_to_first_word",
            "tighten_pauses",
            "remove_fillers",
            "cut_words",
        ] {
            assert!(Server {
                project: &mut p,
                initialized: true
            }
            .craft(name, &json!({}))
            .is_err());
        }
        assert!(kinds(&mut p).is_empty());
        speech(&mut p);
        for (name, args) in [
            ("cut_words", json!({"from_word_index":0,"to_word_index":4})),
            ("cut_words", json!({"from_word_index":0,"to_word_index":3})),
            ("tighten_pauses", json!({"max_gap_s":0.1})),
            ("tighten_pauses", json!({"from_s":3,"to_s":1})),
            ("trim_start_to_first_word", json!({"lead_s":-1})),
            ("remove_fillers", json!({"words":[3]})),
        ] {
            let before = p.data.clone();
            assert!(
                Server {
                    project: &mut p,
                    initialized: true
                }
                .craft(name, &args)
                .is_err(),
                "{name} {args}"
            );
            assert_eq!(p.data, before);
        }
        assert!(p.undo.is_empty());
    }
    #[test]
    fn fillers_preserve_meaning_and_refuse_overlapping_speech() {
        let (_f, mut p) = setup();
        transcript(
            &mut p,
            json!([
                {"text":"like","src_start_ns":100_000_000,"src_end_ns":300_000_000},
                {"text":"um!","src_start_ns":400_000_000,"src_end_ns":600_000_000},
                {"text":"word","src_start_ns":500_000_000,"src_end_ns":800_000_000}
            ]),
        );
        assert!(Server {
            project: &mut p,
            initialized: true
        }
        .craft("remove_fillers", &json!({}))
        .is_err());
        assert_eq!(
            call(&mut p, "remove_fillers", json!({"words":["uh"]}))["changed"],
            false
        );
    }
    #[test]
    fn moments_sorted_indices_focus_and_exact_retiming() {
        let (_f, mut p) = setup();
        speech(&mut p);
        p.events[0].push(
            serde_json::from_value(
                json!({"t":0,"type":"focus","app_bundle_id":"test.app","window_title":"Deploy"}),
            )
            .unwrap(),
        );
        for n in 0..7 {
            p.events[0].push(serde_json::from_value(json!({"t":100_000_000 + n * 300_000_000,"type":"key","key":"a","modifiers":[]})).unwrap());
        }
        p.events[0].sort_by_key(|e| e.t);
        p.key_overlay_index =
            crate::key_overlay::KeyOverlayIndex::new(&p.session, &p.events, &p.data.timeline.clips);
        let before = call(&mut p, "moments", json!({}));
        let rows = before["moments"].as_array().unwrap();
        assert!(rows
            .windows(2)
            .all(|w| w[0]["start_s"].as_f64() <= w[1]["start_s"].as_f64()));
        let click = rows.iter().find(|r| r["kind"] == "click").unwrap();
        assert_eq!(click["app_bundle_id"], "test.app");
        assert_eq!(click["window_title"], "Deploy");
        assert!(rows.iter().any(|r| r["kind"] == "key"));
        assert!(rows.iter().any(|r| r["kind"] == "typing"));
        assert!(rows
            .iter()
            .any(|r| r["kind"] == "sentence" && r["from_word_index"] == 0));
        call(&mut p, "trim_start_to_first_word", json!({}));
        let after = call(&mut p, "moments", json!({}));
        assert_eq!(
            after["moments"]
                .as_array()
                .unwrap()
                .iter()
                .find(|r| r["kind"] == "click")
                .unwrap()["app_bundle_id"],
            "test.app"
        );
        let clip = p.data.timeline.clips[0].id.clone();
        p.apply(&json!({"op":"set_speed","clip_id":clip,"speed":2}))
            .unwrap();
        let filtered = call(&mut p, "moments", json!({"from_s":0.8}));
        assert!(filtered["moments"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|r| r["kind"] == "sentence")
            .all(|r| r["from_word_index"].as_u64().unwrap() > 0));
    }
    #[test]
    fn zoom_eased_clamped_atomic_and_overlap_refused() {
        let (_f, mut p) = setup();
        let before = p.data.clone();
        let result = call(&mut p, "zoom_on_click", json!({"click_index":0}));
        assert_eq!(p.undo.len(), 1);
        let z = &p.data.zooms[0];
        assert!(z.tl_start_ns >= 0 && z.tl_end_ns <= 5 * SECOND);
        assert_eq!(z.scale, 1.8);
        assert_eq!(z.ease_in_ns, 300_000_000);
        assert_eq!(z.target, [238.0 / 320.0, 139.0 / 200.0]);
        assert!(Server {
            project: &mut p,
            initialized: true
        }
        .craft("zoom_on_click", &json!({"at_s":result["at_s"]}))
        .is_err());
        assert_eq!(p.undo.len(), 1);
        p.undo().unwrap();
        assert_eq!(p.data, before);
        for args in [
            json!({}),
            json!({"click_index":0,"at_s":0}),
            json!({"at_s":100}),
            json!({"click_index":999}),
            json!({"click_index":0,"scale":0}),
        ] {
            assert!(Server {
                project: &mut p,
                initialized: true
            }
            .craft("zoom_on_click", &args)
            .is_err());
        }
        p.events[0][0].x = Some(-1.0); // independently verify a captured outside click below
        let event = p.events[0].iter_mut().find(|e| e.kind == "down").unwrap();
        event.x = Some(-1.0);
        assert!(Server {
            project: &mut p,
            initialized: true
        }
        .craft("zoom_on_click", &json!({"click_index":0}))
        .is_err());
    }
    #[test]
    fn check_clean_and_all_structural_rules() {
        let (_f, mut p) = setup();
        assert!(kinds(&mut p).is_empty());
        speech(&mut p);
        let k = kinds(&mut p);
        for kind in ["dead_air_start", "long_pause", "long_tail"] {
            assert!(k.contains(&kind.into()), "{k:?}");
        }
        p.apply(&json!({"op":"add_zoom","tl_start_ns":0,"tl_end_ns":500_000_000,"scale":2,"mode":"manual","target":[0.5,0.5]})).unwrap();
        p.apply(&json!({"op":"add_zoom","tl_start_ns":100_000_000,"tl_end_ns":2_000_000_000,"scale":2,"mode":"manual","target":[0.5,0.5]})).unwrap();
        // Malformed persisted legacy effects can outlive the timeline.
        p.data.zooms[1].tl_end_ns = 10 * SECOND;
        for (id, start, end) in [("a", 0, SECOND), ("b", 500_000_000, 6 * SECOND)] {
            p.data.canvas.captions.push(TextRecord {
                id: id.into(),
                text: id.into(),
                tl_start_ns: start,
                tl_end_ns: end,
                ..Default::default()
            });
        }
        let k = kinds(&mut p);
        for kind in [
            "zoom_past_end",
            "zoom_duration",
            "overlapping_zooms",
            "captions_overlapping",
            "item_after_end",
        ] {
            assert!(k.contains(&kind.into()), "{kind}: {k:?}");
        }
        p.data.zooms.clear();
        p.data.canvas.captions.clear();
        p.apply(&json!({"op":"delete_range","tl_start_ns":0,"tl_end_ns":700_000_000}))
            .unwrap();
        assert!(kinds(&mut p).contains(&"cut_inside_word".into()));
        p.undo().unwrap();
        p.apply(&json!({"op":"split","at_tl_ns":700_000_000}))
            .unwrap();
        assert!(
            !kinds(&mut p).contains(&"cut_inside_word".into()),
            "An intact split is not a word cut"
        );
        std::fs::remove_file(p.package.join("recording/seg-000/screen.mov")).unwrap();
        assert!(kinds(&mut p).contains(&"missing_screen_media".into()));
        p.data.timeline.clips.clear();
        assert!(kinds(&mut p).contains(&"empty_timeline".into()));
    }
    #[test]
    fn clean_speech_and_corrected_caption_word_timings() {
        let (_f, mut p) = setup();
        transcript(
            &mut p,
            json!([
                {"text":"First.","src_start_ns":100_000_000,"src_end_ns":2_000_000_000},
                {"text":"Last.","src_start_ns":2_350_000_000_i64,"src_end_ns":4_300_000_000_i64}
            ]),
        );
        assert!(kinds(&mut p).is_empty());
        let t: Value = serde_json::from_slice(
            &std::fs::read(p.package.join("recording/transcript.json")).unwrap(),
        )
        .unwrap();
        p.apply(&json!({"op":"import_transcript","transcript":t}))
            .unwrap();
        p.data.canvas.captions[0].words[0].text = "Corrected.".into();
        let moments = call(&mut p, "moments", json!({}));
        assert_eq!(moments["moments"][0]["text"], "Corrected.");
        assert!(kinds(&mut p).is_empty());
    }
    #[test]
    fn public_rpc_contract_and_unknown_arguments() {
        let (_f, mut p) = setup();
        speech(&mut p);
        let mut server = Server {
            project: &mut p,
            initialized: true,
        };
        for name in ["moments", "check", "tighten_pauses"] {
            let result=server.rpc(json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":name,"arguments":{}}})).unwrap();
            assert_eq!(result["result"]["isError"], false, "{result}");
        }
        let result=server.rpc(json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"moments","arguments":{"from_ns":1}}})).unwrap();
        assert_eq!(result["result"]["isError"], true);
        assert!(crate::mcp::catalog()
            .iter()
            .filter(|t| t["name"] == "moments" || t["name"] == "check")
            .all(|t| t["annotations"]["readOnlyHint"] == true));
    }
}

#[cfg(test)]
mod edge_tests {
    use super::*;
    use crate::{
        model::Zoom,
        project::{tests::Fixture, Project},
    };
    #[test]
    fn zoom_budget_and_free_interval_are_enforced() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.snapshot = true;
        p.data.zooms.clear();
        let click = p.events[0].iter().find(|e| e.kind == "down").unwrap().t;
        let mut server = Server {
            project: &mut p,
            initialized: true,
        };
        server
            .craft("zoom_on_click", &json!({"click_index":0}))
            .unwrap();
        let base = server.project.data.zooms[0].clone();
        server.project.undo().unwrap();
        // Free space is clipped to a neighboring zoom without changing that zoom.
        let mut neighbor = base.clone();
        neighbor.id = "neighbor".into();
        neighbor.tl_start_ns = click + SECOND;
        neighbor.tl_end_ns = 5 * SECOND;
        server.project.data.zooms.push(neighbor.clone());
        let result = server
            .craft(
                "zoom_on_click",
                &json!({"at_s":seconds(click),"lead_s":0.4}),
            )
            .unwrap();
        assert_eq!(result["to_s"], seconds(click + SECOND));
        assert_eq!(server.project.data.zooms[0], neighbor);
        server.project.undo().unwrap();
        server.project.data.zooms[0].tl_start_ns = click + 100_000_000;
        assert!(server
            .craft("zoom_on_click", &json!({"click_index":0}))
            .is_err());
        server.project.data.zooms = (0..6)
            .map(|i| Zoom {
                id: format!("budget-{i}"),
                tl_start_ns: 10 * SECOND + i * 2 * SECOND,
                tl_end_ns: 11 * SECOND + i * 2 * SECOND,
                ..base.clone()
            })
            .collect();
        assert!(server
            .craft("zoom_on_click", &json!({"click_index":0}))
            .unwrap_err()
            .message
            .contains("budget"));
        assert!(result["changed"] == true);
    }
    #[test]
    fn read_tools_do_not_write_package_or_history_and_fixture_is_clean() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        let before = p.data.clone();
        let mut server = Server {
            project: &mut p,
            initialized: true,
        };
        assert_eq!(
            server.craft("check", &json!({})).unwrap()["issues"],
            json!([])
        );
        server.craft("moments", &json!({})).unwrap();
        assert_eq!(server.project.data, before);
        assert!(server.project.undo.is_empty());
        assert!(!f.0.join("autosave/project.json").exists());
    }
    #[test]
    fn cuts_and_speeds_keep_word_indices_and_breathing_room() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.snapshot = true;
        let transcript = json!({"schema_version":1,"words":[
            {"text":"first","src_start_ns":100_000_000,"src_end_ns":500_000_000},
            {"text":"um","src_start_ns":800_000_000,"src_end_ns":900_000_000},
            {"text":"last","src_start_ns":1_500_000_000,"src_end_ns":2_000_000_000}
        ]});
        std::fs::write(
            f.0.join("recording/transcript.json"),
            transcript.to_string(),
        )
        .unwrap();
        let clip = p.data.timeline.clips[0].id.clone();
        p.apply(&json!({"op":"set_speed","clip_id":clip,"speed":2}))
            .unwrap();
        let before = p.data.clone();
        let mut server = Server {
            project: &mut p,
            initialized: true,
        };
        server
            .craft("cut_words", &json!({"from_word_index":1,"to_word_index":1}))
            .unwrap();
        let (words, _) = server.craft_words().unwrap();
        assert_eq!(words.len(), 2);
        assert_eq!(words[1].start - words[0].end, 350_000_000);
        assert!(!server.craft("check", &json!({})).unwrap()["issues"]
            .as_array()
            .unwrap()
            .iter()
            .any(|i| i["kind"] == "cut_inside_word"));
        server.project.undo().unwrap();
        assert_eq!(server.project.data, before);
    }
}
