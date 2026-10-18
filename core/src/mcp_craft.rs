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
// Hints are revision-local evidence from the app's decoder, never project state.
#[derive(Default)]
struct VisionHints {
    supplied: bool,
    static_cuts: Vec<i64>,
    changes: Vec<i64>,
    regions: Vec<(i64, [f64; 4], Option<usize>)>,
}
impl VisionHints {
    fn parse(a: &Value, duration: i64) -> Result<Self> {
        fn array<'a>(a: &'a Value, key: &str) -> Result<&'a [Value]> {
            a.get(key).map_or(Ok(&[][..]), |v| {
                v.as_array()
                    .filter(|v| v.len() <= 4096)
                    .map(Vec::as_slice)
                    .ok_or_else(|| bad("Vision hints must be arrays of at most 4096 entries"))
            })
        }
        let mut hints = Self::default();
        for key in ["static_cuts_s", "visual_view_changes_s"] {
            hints.supplied |= a.get(key).is_some();
            let mut times = vec![];
            for v in array(a, key)? {
                let at = ns(&json!({"at_s":v}), "at_s", 0)?;
                if at > duration {
                    return Err(bad("Vision hint exceeds current timeline"));
                }
                times.push(at);
            }
            times.sort_unstable();
            times.dedup();
            if key == "static_cuts_s" {
                hints.static_cuts = times;
            } else {
                hints.changes = times;
            }
        }
        hints.supplied |= a.get("visual_view_changes").is_some();
        for row in array(a, "visual_view_changes")? {
            if row.get("at_s").is_none() {
                return Err(bad("Visual change requires at_s"));
            }
            let at = ns(row, "at_s", 0)?;
            if at > duration {
                return Err(bad("Vision hint exceeds current timeline"));
            }
            let rect = &row["bbox"];
            if !["x", "y", "w", "h"].iter().all(|k| rect.get(*k).is_some()) {
                return Err(bad("Visual change bbox requires normalized x,y,w,h"));
            }
            let rect = [
                number(rect, "x", 0.0)?,
                number(rect, "y", 0.0)?,
                number(rect, "w", 0.0)?,
                number(rect, "h", 0.0)?,
            ];
            if rect[2] <= 0.0
                || rect[3] <= 0.0
                || rect[0] + rect[2] > 1.0
                || rect[1] + rect[3] > 1.0
            {
                return Err(bad("Visual change bbox must lie inside normalized source"));
            }
            let click = row
                .get("click_index")
                .map(|v| {
                    v.as_u64()
                        .and_then(|n| usize::try_from(n).ok())
                        .ok_or_else(|| {
                            bad("Visual change click_index must be a nonnegative integer")
                        })
                })
                .transpose()?;
            hints.regions.push((at, rect, click));
            hints.changes.push(at);
        }
        hints.changes.sort_unstable();
        hints.changes.dedup();
        Ok(hints)
    }
    fn static_cut(&self, at: i64) -> bool {
        self.static_cuts.iter().any(|t| (t - at).abs() <= 1_000_000)
    }
}
#[derive(Clone)]
struct Word {
    text: String,
    start: i64,
    end: i64,
    timed: bool,
}
#[derive(Clone, Default, PartialEq)]
struct View {
    app: Option<String>,
    title: Option<String>,
    url: Option<String>,
    window_rect: Option<Value>,
    window_id: Option<Value>,
}
impl View {
    fn update(&mut self, event: &crate::model::Event) {
        if let Some(rect) = event.details.get("window_rect").filter(|r| r.is_array()) {
            self.window_rect = Some(rect.clone());
        }
        if let Some(id) = event.details.get("window_id").filter(|v| v.is_number()) {
            self.window_id = Some(id.clone());
        }
        // Capture metadata is sparse. Missing fields must not erase prior context.
        for (field, keys) in [
            (&mut self.app, &["app_bundle_id"][..]),
            (&mut self.title, &["window_title", "title"][..]),
            (&mut self.url, &["url", "window_url", "document_url"][..]),
        ] {
            if let Some(value) = keys
                .iter()
                .find_map(|k| event.details.get(*k).and_then(Value::as_str))
            {
                *field = Some(value.to_owned());
            }
        }
    }
    fn row(&self, t: i64, reason: &str) -> Value {
        json!({"kind":"view_change","start_s":seconds(t),"app_bundle_id":self.app,"window_title":self.title,"url":self.url,"reason":reason})
    }
}
fn printable(e: &Value) -> Option<&str> {
    if e["type"] != "key"
        || e["modifiers"].as_array().is_some_and(|m| {
            m.iter()
                .any(|v| !matches!(v.as_str(), Some("shift" | "caps_lock")))
        })
    {
        return None;
    }
    let key = e["key"].as_str()?;
    if key == "space" {
        return Some(" ");
    }
    (key.chars().count() == 1 && !key.chars().any(char::is_control)).then_some(key)
}
fn overlaps(ranges: &[(i64, i64)], start: i64, end: i64) -> bool {
    ranges.iter().any(|&(a, b)| a < end && start < b)
}
impl Server<'_> {
    fn source_views(&self) -> (View, Vec<(i64, View)>) {
        let initial = View {
            app: self.project.session.source.app_bundle_id.clone(),
            title: self.project.session.source.window_title.clone(),
            url: None,
            window_rect: None,
            window_id: None,
        };
        let mut state = initial.clone();
        let mut events: Vec<_> = self
            .project
            .session
            .segments
            .iter()
            .zip(&self.project.events)
            .flat_map(|(s, events)| {
                events
                    .iter()
                    .filter(|e| {
                        matches!(
                            e.kind.as_str(),
                            "focus"
                                | "window_title"
                                | "title"
                                | "url"
                                | "navigation"
                                | "navigate"
                                | "view_change"
                        )
                    })
                    .map(move |e| (s.src_start_ns + e.t, e))
            })
            .collect();
        events.sort_by_key(|(t, _)| *t);
        let mut changes = vec![];
        for (t, e) in events {
            let before = state.clone();
            state.update(e);
            if before != state {
                changes.push((t, state.clone()));
            }
        }
        (initial, changes)
    }
    fn view_changes(&self, hints: &VisionHints) -> Vec<Value> {
        let (initial, changes) = self.source_views();
        let clips = &self.project.data.timeline.clips;
        let mut rows = vec![];
        for (i, c) in clips.iter().enumerate() {
            if i > 0 && clips[i - 1].src_end_ns != c.src_start_ns {
                let at = time::clip_bounds(clips, i).unwrap().0;
                let left = clips[i - 1].src_end_ns;
                let right = c.src_start_ns;
                let view_at = |src| {
                    changes
                        .iter()
                        .rev()
                        .find(|(t, _)| *t <= src)
                        .map_or(&initial, |(_, v)| v)
                };
                // Cursor travel alone does not change a page. Inspect SOURCE events:
                // querying retained events would lose the very activity removed by the cut.
                let activity = self
                    .project
                    .session
                    .segments
                    .iter()
                    .zip(&self.project.events)
                    .any(|(segment, events)| {
                        events.iter().any(|e| {
                            let t = segment.src_start_ns + e.t;
                            t >= left.min(right)
                                && t < left.max(right)
                                && matches!(
                                    e.kind.as_str(),
                                    "down"
                                        | "scroll"
                                        | "key"
                                        | "focus"
                                        | "window_title"
                                        | "title"
                                        | "url"
                                        | "navigation"
                                        | "navigate"
                                        | "view_change"
                                )
                        })
                    });
                if !hints.static_cut(at)
                    && (activity || view_at(left.saturating_sub(1)) != view_at(right))
                {
                    rows.push(view_at(right).row(at, "cut"));
                }
            }
            for (src, view) in &changes {
                if let Some(t) = time::source_to_timeline(clips, i, *src) {
                    rows.push(view.row(t, "metadata"));
                }
            }
        }
        for &at in &hints.changes {
            rows.push(json!({"kind":"view_change","start_s":seconds(at),"reason":"visual"}));
        }
        rows.sort_by(|a, b| {
            a["start_s"]
                .as_f64()
                .partial_cmp(&b["start_s"].as_f64())
                .unwrap()
        });
        rows
    }
    fn key_rows(&self, events: &[Value]) -> Vec<Value> {
        let clips = &self.project.data.timeline.clips;
        let clip_at = |t| {
            (0..clips.len()).find(|&i| {
                let (a, b) = time::clip_bounds(clips, i).unwrap();
                a <= t && t < b
            })
        };
        let mut rows = vec![];
        let mut run: Vec<&Value> = vec![];
        let flush = |run: &mut Vec<&Value>, rows: &mut Vec<Value>| {
            if let (Some(first), Some(last)) = (run.first(), run.last()) {
                if run.len() > 1 {
                    rows.push(json!({"kind":"typing","start_s":seconds(first["tl_ns"].as_i64().unwrap()),"end_s":seconds(last["tl_ns"].as_i64().unwrap()+1),"key_count":run.len(),"text":run.iter().filter_map(|e| printable(e)).collect::<String>()}));
                } else {
                    rows.push(json!({"kind":"key","start_s":seconds(first["tl_ns"].as_i64().unwrap()),"key":first["key"],"modifiers":first["modifiers"]}));
                }
            }
            run.clear();
        };
        for e in events {
            if printable(e).is_some() {
                if run.last().is_some_and(|last| {
                    let gap = e["src_ns"].as_i64().unwrap() - last["src_ns"].as_i64().unwrap();
                    !(0..500_000_000).contains(&gap)
                        || e["segment"] != last["segment"]
                        || clip_at(e["tl_ns"].as_i64().unwrap())
                            != clip_at(last["tl_ns"].as_i64().unwrap())
                }) {
                    flush(&mut run, &mut rows);
                }
                run.push(e);
            } else if matches!(
                e["type"].as_str(),
                Some("key" | "down" | "scroll" | "focus" | "navigation" | "url" | "window_title")
            ) {
                flush(&mut run, &mut rows);
                if e["type"] == "key" {
                    rows.push(json!({"kind":"key","start_s":seconds(e["tl_ns"].as_i64().unwrap()),"key":e["key"],"modifiers":e["modifiers"]}));
                }
            }
        }
        flush(&mut run, &mut rows);
        rows
    }
    fn typing_ranges(&self) -> Vec<(i64, i64)> {
        // Use the same source bursts as auto_speed_typing, including dismissed ones.
        let clips = &self.project.data.timeline.clips;
        let clock = time::ClipTimeIndex::new(clips);
        crate::auto::typing_bursts(self.project)
            .iter()
            .flat_map(|b| {
                clips
                    .iter()
                    .enumerate()
                    .filter_map(|(i, c)| {
                        let a = b.start.max(c.src_start_ns);
                        let end = b.end.min(c.src_end_ns);
                        if end <= a {
                            return None;
                        }
                        Some((
                            clock.source_boundary_to_timeline(clips, i, a)?,
                            clock.source_boundary_to_timeline(clips, i, end)?,
                        ))
                    })
                    .collect::<Vec<_>>()
            })
            .collect()
    }
    fn activity_ranges(&self) -> Result<Vec<(i64, i64)>> {
        let events = self.project.query(&json!({"q":"events"}))?;
        let events = events.as_array().unwrap();
        let mut ranges = self.typing_ranges();
        ranges.extend(
            events
                .iter()
                .filter(|e| matches!(e["type"].as_str(), Some("down" | "scroll" | "key")))
                .map(|e| {
                    let t = e["tl_ns"].as_i64().unwrap();
                    (t, t + 1)
                }),
        );
        ranges.extend(
            self.key_rows(events)
                .iter()
                .filter(|r| r["kind"] == "typing")
                .map(|r| {
                    (
                        (r["start_s"].as_f64().unwrap() * SECOND as f64).round() as i64,
                        (r["end_s"].as_f64().unwrap() * SECOND as f64).round() as i64,
                    )
                }),
        );
        Ok(ranges)
    }
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
            "check" => self.craft_check(a),
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
        let (initial, views) = self.source_views();
        let hints = VisionHints::parse(a, time::duration(&self.project.data.timeline.clips))?;
        let changes = self.view_changes(&hints);
        for (click_index, e) in events
            .as_array()
            .unwrap()
            .iter()
            .filter(|e| e["type"] == "down")
            .enumerate()
        {
            let t = e["tl_ns"].as_i64().unwrap();
            let src = e["src_ns"].as_i64().unwrap();
            let view = views
                .iter()
                .rev()
                .find(|(at, _)| *at <= src)
                .map_or(&initial, |(_, v)| v);
            let next = changes
                .iter()
                .find(|r| r["start_s"].as_f64().unwrap() > seconds(t))
                .map(|r| r["start_s"].clone());
            rows.push(json!({"kind":"click","start_s":seconds(t),"click_index":click_index,"x":e["x"],"y":e["y"],"button":e["button"],"app_bundle_id":view.app,"window_title":view.title,"url":view.url,"view_change_s":next}));
        }
        rows.extend(self.key_rows(events.as_array().unwrap()));
        rows.extend(changes);
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
            json!({"hints_accepted":hints.supplied,"duration_s":seconds(time::duration(clips)),"transcript_available":available,"word_timing_available":!words.is_empty() && words.iter().all(|w|w.timed),"view_changes":rows.iter().filter(|r| r["kind"] == "view_change").collect::<Vec<_>>(),"moments":rows,"note":"Times are current timeline seconds; indices are zero-based and global before range filtering. Re-read after edits. Click x/y are capture points, not normalized coordinates."}),
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
                let activity = self.activity_ranges()?;
                let mut skipped = vec![];
                let mut ranges = vec![];
                // Running maximum handles overlapping recognizer words safely.
                let mut end = words[0].end;
                for w in &words[1..] {
                    if w.start - end > max_gap {
                        let x = (end + keep / 2).max(from);
                        let y = (w.start - (keep - keep / 2)).min(to);
                        if y > x {
                            if overlaps(&activity, end, w.start) {
                                skipped.push((end, w.start));
                            } else {
                                ranges.push((x, y));
                            }
                        }
                    }
                    end = end.max(w.end);
                }
                if to == duration && duration - end > 800_000_000 {
                    if overlaps(&activity, end, duration) {
                        skipped.push((end, duration));
                    } else {
                        ranges.push(((end + 800_000_000).max(from), duration));
                    }
                }
                let mut result = self.cut_ranges(ranges, "pauses")?;
                result["activity_pauses_kept"] = json!(skipped
                    .iter()
                    .map(|(a, b)| json!({"from_s":seconds(*a),"to_s":seconds(*b)}))
                    .collect::<Vec<_>>());
                if !skipped.is_empty() {
                    result["message"] = format!(
                        "{} Kept {} pause(s) with typing, clicks or scrolls.",
                        result["message"].as_str().unwrap(),
                        skipped.len()
                    )
                    .into();
                }
                Ok(result)
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
        let mut scale = number(a, "scale", 1.8)?;
        if !(1.05..=4.0).contains(&scale) {
            return Err(bad("Craft zoom scale must be between 1.05 and 4."));
        }
        let mut target = [x / geometry[2], y / geometry[3]];
        let mut last_included = t;
        if let Some(include) = a.get("include") {
            let items = include.as_array().ok_or_else(|| {
                bad("include must be an array of click indices or normalized {x,y,w,h} rectangles")
            })?;
            if !items.is_empty() {
                let mut bounds = [target[0], target[1], target[0], target[1]];
                for item in items {
                    let rect = if let Some(index) = item.as_u64() {
                        let c = clicks
                            .get(index as usize)
                            .ok_or_else(|| bad("include click index out of range"))?;
                        last_included = last_included.max(c["tl_ns"].as_i64().unwrap());
                        [
                            c["x"]
                                .as_f64()
                                .ok_or_else(|| bad("Included click has no position"))?
                                / geometry[2],
                            c["y"]
                                .as_f64()
                                .ok_or_else(|| bad("Included click has no position"))?
                                / geometry[3],
                            0.0,
                            0.0,
                        ]
                    } else {
                        let o = item
                            .as_object()
                            .ok_or_else(|| bad("include entries must be indices or rectangles"))?;
                        if o.len() != 4 || !["x", "y", "w", "h"].iter().all(|k| o.contains_key(*k))
                        {
                            return Err(bad("include rectangles require exactly x,y,w,h"));
                        }
                        let rect = [
                            number(item, "x", 0.0)?,
                            number(item, "y", 0.0)?,
                            number(item, "w", 0.0)?,
                            number(item, "h", 0.0)?,
                        ];
                        if rect[2] <= 0.0 || rect[3] <= 0.0 {
                            return Err(bad("include rectangle sizes must be positive"));
                        }
                        rect
                    };
                    if rect[0] < 0.0
                        || rect[1] < 0.0
                        || rect[0] + rect[2] > 1.0
                        || rect[1] + rect[3] > 1.0
                    {
                        return Err(bad("include must lie inside the normalized source picture"));
                    }
                    bounds[0] = bounds[0].min(rect[0]);
                    bounds[1] = bounds[1].min(rect[1]);
                    bounds[2] = bounds[2].max(rect[0] + rect[2]);
                    bounds[3] = bounds[3].max(rect[1] + rect[3]);
                }
                let crop = self.project.data.canvas.crop;
                if bounds[0] < crop[0]
                    || bounds[1] < crop[1]
                    || bounds[2] > crop[0] + crop[2]
                    || bounds[3] > crop[1] + crop[3]
                {
                    return Err(bad(
                        "Included context is outside canvas.crop; widen the crop first.",
                    ));
                }
                let fit = (crop[2] / (bounds[2] - bounds[0]).max(f64::EPSILON))
                    .min(crop[3] / (bounds[3] - bounds[1]).max(f64::EPSILON));
                if fit < 1.3 {
                    return Err(bad("Included context cannot fit at 1.3×; use a smaller region or leave this shot at 1×."));
                }
                scale = scale.clamp(1.3, 2.0).min(fit);
                for axis in 0..2 {
                    let half = crop[axis + 2] / scale / 2.0;
                    target[axis] = ((bounds[axis] + bounds[axis + 2]) / 2.0)
                        .clamp(crop[axis] + half, crop[axis] + crop[axis + 2] - half);
                }
            }
        }
        let lead = ns(a, "lead_s", 400_000_000)?.min(2 * SECOND);
        let hold = ns(a, "hold_s", 1_600_000_000)?.clamp(SECOND, 6 * SECOND);
        let duration = time::duration(&self.project.data.timeline.clips);
        let requested_start = ns(a, "start_s", (t - lead).max(0))?;
        let hints = VisionHints::parse(a, duration)?;
        let changes = self.view_changes(&hints);
        let include_extended = a.get("end_s").is_none() && last_included > t;
        let requested_end = ns(a, "end_s", last_included.saturating_add(hold))?;
        if requested_start > t || requested_end <= t || requested_end <= requested_start {
            return Err(bad("start_s/end_s must enclose the selected click."));
        }
        let mut start = requested_start;
        let mut end = requested_end.min(duration);
        let view_change = changes
            .iter()
            .map(|r| (r["start_s"].as_f64().unwrap() * SECOND as f64).round() as i64)
            .find(|&at| at > t);
        if let Some(change) = view_change {
            end = end.min(change.saturating_sub(50_000_000));
        }
        let mut earliest = 0;
        // Static cuts do not bound the lead; only plausible or confirmed changes do.
        for change in &changes {
            let at = (change["start_s"].as_f64().unwrap() * SECOND as f64).round() as i64;
            if at <= t {
                earliest = earliest.max(at);
            }
        }
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
                earliest = earliest.max(z.tl_end_ns);
            }
            if z.tl_start_ns > t {
                end = end.min(z.tl_start_ns);
            }
        }
        start = start.min(end - SECOND).max(earliest);
        if include_extended {
            end = end.min(start.saturating_add(8 * SECOND));
        }
        if start > t || end <= t || end - start < SECOND || end - start > 8 * SECOND {
            return Err(bad(
                "Cannot fit a 1–8 second zoom around this click within view changes, other zooms and timeline bounds. Zoom on the result instead.",
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
        let clamped = start != requested_start || end != requested_end;
        let reason = if view_change.is_some_and(|v| end == v.saturating_sub(50_000_000)) {
            "; clamped before the view change (50 ms margin), lead adjusted to keep at least 1 s"
        } else if clamped {
            "; clamped to the available interval, lead adjusted to keep at least 1 s"
        } else {
            ""
        };
        let timing = if include_extended {
            "; extended requested end to include later clicks plus hold (safety bounds still apply)"
        } else {
            ""
        };
        let ease = if self.project.data.zoom_settings.physics_version >= 2 {
            SECOND
        } else {
            300_000_000
        };
        let change=self.project.apply(&json!({"op":"batch","commands":[{"op":"add_zoom","mode":"manual","target":target,"scale":scale,"tl_start_ns":start,"tl_end_ns":end,"ease_in_ns":ease,"ease_out_ns":ease}]}))?;
        Ok(
            json!({"hints_accepted":hints.supplied,"include_extended":include_extended,"requested_end_s":seconds(requested_end),"changed":true,"message":format!("Zoom {scale:.2}× on click {} ({}–{}){reason}{timing}",clock(t),clock(start),clock(end)),"click_index":index,"at_s":seconds(t),"from_s":seconds(start),"to_s":seconds(end),"scale":scale,"target":target,"clamped":clamped,"view_change_s":view_change.map(seconds),"change":change}),
        )
    }
}
fn normalize(s: &str) -> String {
    s.trim_matches(|c: char| !c.is_alphanumeric())
        .to_lowercase()
}
impl Server<'_> {
    fn craft_check(&self, a: &Value) -> Result<Value> {
        let p = &self.project.data;
        let duration = time::duration(&p.timeline.clips);
        let hints = VisionHints::parse(a, duration)?;
        let (words, available) = self.craft_words()?;
        let activity = self.activity_ranges()?;
        let typing = self.typing_ranges();
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
            for &(at, rect, _) in &hints.regions {
                if z.tl_start_ns <= at && at < z.tl_end_ns && at < duration {
                    // Use the renderer's evaluated crop, including easing, canvas crop,
                    // cursor-follow and adaptive framing, rather than a guessed 1/scale box.
                    let crop = self.project.frame_geometry(at)?.screen_crop;
                    if rect[0] < crop.x - 1e-6
                        || rect[1] < crop.y - 1e-6
                        || rect[0] + rect[2] > crop.x + crop.w + 1e-6
                        || rect[1] + rect[3] > crop.y + crop.h + 1e-6
                    {
                        issue("warning", "zoom_hides_change", at,
                            format!("Zoom '{}' crops a visual change outside the visible source frame.", z.id),
                            "Include the result rectangle, reduce the zoom, or end it before the result; verify with capture.");
                    }
                }
            }
            if overlaps(&typing, z.tl_start_ns, z.tl_end_ns) {
                issue(
                    "warning",
                    "zoom_during_typing",
                    z.tl_start_ns,
                    format!("Zoom '{}' overlaps a fast typing burst.", z.id),
                    "Move the zoom to the typing result, or shorten it to avoid the burst.",
                );
            }
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
        let events = self.project.query(&json!({"q":"events"}))?;
        let clicks: Vec<i64> = events
            .as_array()
            .unwrap()
            .iter()
            .filter(|e| e["type"] == "down")
            .map(|e| e["tl_ns"].as_i64().unwrap())
            .collect();
        if hints
            .regions
            .iter()
            .any(|(_, _, i)| i.is_some_and(|i| i >= clicks.len()))
        {
            return Err(bad(
                "Visual change click_index out of range; re-read moments",
            ));
        }
        let clips = &p.timeline.clips;
        let source_end = self
            .project
            .session
            .segments
            .iter()
            .map(|s| s.src_start_ns + s.duration_ns)
            .max()
            .unwrap_or(0);
        let mut cuts = vec![];
        for (i, c) in clips.iter().enumerate() {
            let next_source = clips
                .get(i + 1)
                .map_or(source_end, |next| next.src_start_ns);
            if next_source > c.src_end_ns {
                cuts.push(time::clip_bounds(clips, i).unwrap().1);
            }
        }
        // Pixel evidence is preferred for results. Metadata is a fallback, not proof
        // that a toast was visible. Each warning is a review candidate, never an edit.
        let results: Vec<i64> =
            if a.get("visual_view_changes_s").is_some() || a.get("visual_view_changes").is_some() {
                hints.changes.clone()
            } else {
                self.view_changes(&hints)
                    .iter()
                    .filter(|r| r["reason"] == "metadata")
                    .map(|r| (r["start_s"].as_f64().unwrap() * SECOND as f64).round() as i64)
                    .collect()
            };
        for result in results {
            let explicit_click = hints
                .regions
                .iter()
                .find(|(at, _, i)| *at == result && i.is_some())
                .and_then(|(_, _, i)| *i)
                .map(|i| clicks[i]);
            let click =
                explicit_click.or_else(|| clicks.iter().rev().copied().find(|&t| t <= result));
            if let Some(click) = click.filter(|&t| t <= result && result - t <= 3 * SECOND) {
                if let Some(&cut) = cuts.iter().find(|&&cut| {
                    cut > result
                        && cut - result < SECOND
                        && !cuts.iter().any(|&prior| click < prior && prior <= result)
                }) {
                    issue("warning", "toast_cut_short", cut,
                        format!("A cut leaves only {:.2} s after the click result at {:.2} s.", seconds(cut-result), seconds(result)),
                        "Keep at least 1 s of the result before cutting, or remove the whole step; verify the result with capture.");
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
                    let busy = overlaps(&activity, end, w.start);
                    issue(
                        if busy { "info" } else { "warning" },
                        if busy { "activity_pause" } else { "long_pause" },
                        end,
                        format!("{:.2} s between transcribed words.", seconds(w.start - end)),
                        if busy {
                            "Recorded activity occupies this pause; keep it for context or deliberately speed it up after visual review."
                        } else {
                            "Review the gap, then tighten_pauses to retain 0.35 s breathing room."
                        },
                    );
                }
                end = end.max(w.end);
            }
            if duration - end > 800_000_000 {
                let busy = overlaps(&activity, end, duration);
                issue(
                    if busy { "info" } else { "warning" },
                    if busy { "activity_pause" } else { "long_tail" },
                    end,
                    format!(
                        "{:.2} s after the last transcribed word.",
                        seconds(duration - end)
                    ),
                    if busy {
                        "Recorded activity continues after speech; verify the visible result before trimming."
                    } else {
                        "Use tighten_pauses to retain at most 0.8 s of tail; verify transcript coverage."
                    },
                );
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
            json!({"hints_accepted":hints.supplied,"issues":issues,"duration_s":seconds(duration),"transcript_available":available,"word_timing_available":!words.is_empty() && words.iter().all(|w|w.timed),"limitations":["Transcript gaps are timing candidates, not acoustic silence detection.","Without the original recording transcript, cuts inside source words cannot be checked.","Black pixels and composition quality require capture/filmstrip; this structural check does not decode video."]}),
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
        ("moments","Start here: one chronological timeline of sentences with word indices/timings, clicks with capture-point x/y, known app/window/URL and next metadata/pixel-informed view_change_s (null if unknown), view_changes rows, shortcuts, printable typing text (including short bursts), zooms and cuts. All times SECONDS. Indices are zero-based/global; re-read after edits. Example: moments {}.",range,vec![]),
        ("check","Verify after every edit stage: structural errors and craft warnings with severity, kind, at_s in SECONDS, message and fix_hint. Checks source-word cuts, zoom_during_typing, activity_pause (info), toast_cut_short (<1 s of a click result before a cut), and zoom_hides_change using optional visual_view_changes bbox hints. Does not decode video itself. Follow with capture to verify appearance. Example: check {}.",json!({}),vec![]),
        ("cut_words","Remove an inclusive range of word indices from moments; snap to timed speech boundaries, retain up to 0.35 s breathing room, ripple all tracks. One undo step. Requires word timing, refuses overlaps with retained speech. Example: cut_words {\"from_word_index\":3,\"to_word_index\":4}.",json!({"from_word_index":{"type":"integer","minimum":0},"to_word_index":{"type":"integer","minimum":0}}),vec!["from_word_index","to_word_index"]),
        ("tighten_pauses","Tighten gaps between timed transcript words over max_gap_s (default 0.5 SECONDS), retaining keep_s (default 0.35, clamped 0.3–0.5). Skips whole gaps/tails containing typing, clicks or scrolls and reports activity_pauses_kept. Otherwise trim tail to 0.8 s when range reaches end. Transcript gaps need review; missing words do not prove silence. One undo step. Example: tighten_pauses {\"max_gap_s\":0.5,\"keep_s\":0.35}.",pauses,vec![]),
        ("remove_fillers","Remove exact case-insensitive timed filler words, ignoring surrounding punctuation. Defaults um, uh, erm, er, hmm; never automatically remove like/so/also. Keeps breathing room and makes one undo step. Example: remove_fillers {\"words\":[\"um\",\"uh\"]}.",json!({"words":{"type":"array","items":{"type":"string"}}}),vec![]),
        ("trim_start_to_first_word","Trim opening to first timed word minus lead_s (default 0.1 SECONDS, clamped 0–0.5). No transcript means an explicit error, never guessed silence. One undo step. Example: trim_start_to_first_word {\"lead_s\":0.1}.",json!({"lead_s":{"type":"number","default":0.1,"minimum":0,"maximum":0.5}}),vec![]),
        ("zoom_on_click","Focus an important captured click by global click_index from moments OR at_s (nearest click within 0.25 SECONDS). Default scale 1.8, lead_s 0.4, hold_s 1.6. Optional start_s/end_s override timing in seconds; ends 0.05 s before next known view change, extends lead for >=1 s without crossing previous view changes. include is an array of other click indices and/or normalized source {x,y,w,h} rectangles; fits union at 1.3–2x or refuses if impossible. Included clicks extend end to the last included click plus hold unless end_s is explicit (still clamped, max 8 s). Static cuts do not bound timing. Reports clamps; eased 0.3 s, clamped to timeline and free interval, 1–8 s long, max 6/minute. Refuses a click already zoomed; update/remove existing zoom via apply instead. One undo step. Example: zoom_on_click {\"click_index\":0}.",json!({"click_index":{"type":"integer","minimum":0},"at_s":{"type":"number","minimum":0},"scale":{"type":"number","default":1.8,"minimum":1.05,"maximum":4},"lead_s":{"type":"number","default":0.4,"minimum":0},"hold_s":{"type":"number","default":1.6,"minimum":0},"start_s":{"type":"number","minimum":0},"end_s":{"type":"number","minimum":0},"include":{"type":"array","items":{"oneOf":[{"type":"integer","minimum":0},{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":1},"y":{"type":"number","minimum":0,"maximum":1},"w":{"type":"number","exclusiveMinimum":0,"maximum":1},"h":{"type":"number","exclusiveMinimum":0,"maximum":1}},"required":["x","y","w","h"],"additionalProperties":false}]}}}),vec![]),
    ].into_iter().map(|(name,description,mut properties,required)| {
        if matches!(name, "moments" | "zoom_on_click" | "check") {
            properties["static_cuts_s"] = json!({"type":"array","maxItems":4096,"items":{"type":"number","minimum":0},"description":"Current-timeline cut times proven static by pixels; suppresses cut heuristics within 1 ms. Not persisted."});
            properties["visual_view_changes_s"] = json!({"type":"array","maxItems":4096,"items":{"type":"number","minimum":0},"description":"Current-timeline pixel change times in seconds; adds hard view bounds. Explicit visual changes win over static-cut hints. Not persisted."});
        }
        if name == "check" {
            properties["visual_view_changes"] = json!({"type":"array","maxItems":4096,"description":"Current-timeline pixel changes and normalized source-space bounding boxes. Optional click_index associates a result with a retained click.","items":{"type":"object","properties":{"at_s":{"type":"number","minimum":0},"click_index":{"type":"integer","minimum":0},"bbox":{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":1},"y":{"type":"number","minimum":0,"maximum":1},"w":{"type":"number","exclusiveMinimum":0,"maximum":1},"h":{"type":"number","exclusiveMinimum":0,"maximum":1}},"required":["x","y","w","h"],"additionalProperties":false}},"required":["at_s","bbox"],"additionalProperties":false}});
        }
        json!({"name":name,"description":description,"inputSchema":{"type":"object","properties":properties,"required":required,"additionalProperties":false},"annotations":{"readOnlyHint":name=="moments" || name=="check","openWorldHint":false}})
    }).collect()
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
    fn events(p: &mut Project, rows: Value) {
        p.events.iter_mut().for_each(Vec::clear);
        p.events[0] = rows
            .as_array()
            .unwrap()
            .iter()
            .map(|e| serde_json::from_value(e.clone()).unwrap())
            .collect();
        p.rebuild_key_overlay_index();
    }
    #[test]
    fn static_cuts_allow_zoom_lead_but_removed_activity_and_pixel_changes_bound_it() {
        for kind in ["move", "down", "scroll", "key", "focus"] {
            let (_f, mut p) = setup();
            events(
                &mut p,
                json!([
                    {"t":1_500_000_000,"type":kind,"x":160,"y":100},
                    {"t":2_200_000_000_i64,"type":"down","x":160,"y":100}
                ]),
            );
            p.apply(
                &json!({"op":"delete_range","tl_start_ns":1_000_000_000,"tl_end_ns":2_000_000_000}),
            )
            .unwrap();
            let m = call(&mut p, "moments", json!({}));
            assert_eq!(
                m["view_changes"].as_array().unwrap().is_empty(),
                kind == "move"
            );
            assert!(m["moments"]
                .as_array()
                .unwrap()
                .iter()
                .any(|r| r["kind"] == "cut"));
            let before = p.data.clone();
            let args = json!({"click_index":0,"end_s":1.7});
            let result = Server {
                project: &mut p,
                initialized: true,
            }
            .craft("zoom_on_click", &args);
            assert_eq!(result.is_ok(), kind == "move");
            if result.is_ok() {
                p.undo().unwrap();
            }
            assert_eq!(p.data, before);
            let z = call(
                &mut p,
                "zoom_on_click",
                json!({"click_index":0,"end_s":1.7,"static_cuts_s":[1.0]}),
            );
            assert_eq!(z["from_s"], 0.7);
            assert_eq!(z["hints_accepted"], true);
            p.undo().unwrap();
            let m = call(
                &mut p,
                "moments",
                json!({"static_cuts_s":[1.0],"visual_view_changes_s":[1.0,1.8]}),
            );
            assert_eq!(m["view_changes"].as_array().unwrap().len(), 2);
            assert_eq!(
                m["moments"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .find(|r| r["kind"] == "click")
                    .unwrap()["view_change_s"],
                1.8
            );
            assert!(Server {project:&mut p, initialized:true}.craft("zoom_on_click", &json!({"click_index":0,"end_s":1.7,"static_cuts_s":[1.0],"visual_view_changes_s":[1.0]})).is_err());
            assert_eq!(p.data, before);
        }
    }
    #[test]
    fn cut_focus_comparison_handles_backward_jumps_and_speed() {
        let (_f, mut p) = setup();
        p.session.source.window_title = Some("Before".into());
        events(
            &mut p,
            json!([
                {"t":1_500_000_000,"type":"focus","window_title":"After"},
                {"t":2_200_000_000_i64,"type":"down","x":160,"y":100}
            ]),
        );
        let mut c = p.data.timeline.clips[0].clone();
        c.src_start_ns = 2 * SECOND;
        c.src_end_ns = 3 * SECOND;
        c.speed = 2.0;
        let mut next = c.clone();
        next.id = "backwards".into();
        next.src_start_ns = 0;
        next.src_end_ns = SECOND;
        p.data.timeline.clips = vec![c, next];
        let m = call(&mut p, "moments", json!({}));
        assert!(m["view_changes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["reason"] == "cut" && r["start_s"] == 0.5));
    }
    #[test]
    fn source_focus_geometry_is_a_view_change_even_with_the_same_title() {
        let (_f, mut p) = setup();
        events(
            &mut p,
            json!([
                {"t":0,"type":"focus","window_title":"Browser","window_rect":[0,0,320,200]},
                {"t":1_500_000_000,"type":"focus","window_title":"Browser","window_rect":[20,20,300,180]}
            ]),
        );
        p.apply(
            &json!({"op":"delete_range","tl_start_ns":1_000_000_000,"tl_end_ns":2_000_000_000}),
        )
        .unwrap();
        let m = call(&mut p, "moments", json!({}));
        assert!(m["view_changes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["reason"] == "cut" && r["start_s"] == 1.0));
    }
    #[test]
    fn included_clicks_extend_timing_with_override_view_and_duration_limits() {
        let (_f, mut p) = setup();
        events(
            &mut p,
            json!([
                {"t":1_000_000_000,"type":"down","x":140,"y":100},
                {"t":2_500_000_000_i64,"type":"down","x":180,"y":100}
            ]),
        );
        let before = p.data.clone();
        for (extra, end, extended) in [
            (json!({}), 4.1, true),
            (json!({"end_s":2.0}), 2.0, false),
            (json!({"visual_view_changes_s":[2.9]}), 2.85, true),
        ] {
            let mut args = json!({"click_index":0,"include":[1]});
            args.as_object_mut()
                .unwrap()
                .extend(extra.as_object().unwrap().clone());
            let z = call(&mut p, "zoom_on_click", args);
            assert_eq!(z["to_s"], end);
            assert_eq!(z["include_extended"], extended);
            assert_eq!(p.undo.len(), 1);
            p.undo().unwrap();
            assert_eq!(p.data, before);
        }
        // The fixture is 5 s; slow it down to exercise the 8 s bound.
        for c in &mut p.data.timeline.clips {
            c.speed = 0.25;
        }
        let z = call(
            &mut p,
            "zoom_on_click",
            json!({"click_index":0,"include":[1],"hold_s":2.0}),
        );
        assert_eq!(
            z["to_s"].as_f64().unwrap() - z["from_s"].as_f64().unwrap(),
            8.0
        );
        assert_eq!(z["clamped"], true);
    }
    #[test]
    fn visual_hint_errors_are_atomic_and_reads_preserve_history() {
        let (_f, mut p) = setup();
        events(
            &mut p,
            json!([{ "t":1_500_000_000,"type":"down","x":160,"y":100 }]),
        );
        let before = p.data.clone();
        for invalid in [
            json!({"static_cuts_s":{}}),
            json!({"visual_view_changes_s":[-1]}),
            json!({"visual_view_changes_s":["1"]}),
            json!({"static_cuts_s":[6]}),
            json!({"visual_view_changes":[{"at_s":2,"bbox":{"x":0.9,"y":0,"w":0.2,"h":0.1}}]}),
            json!({"visual_view_changes":[{"bbox":{"x":0,"y":0,"w":0.2,"h":0.1}}]}),
        ] {
            for tool in ["moments", "check", "zoom_on_click"] {
                let mut args = invalid.clone();
                if tool == "zoom_on_click" {
                    args["click_index"] = json!(0);
                }
                assert!(
                    Server {
                        project: &mut p,
                        initialized: true
                    }
                    .craft(tool, &args)
                    .is_err(),
                    "{tool}: {args}"
                );
                assert_eq!(p.data, before);
                assert!(p.undo.is_empty());
            }
        }
        call(
            &mut p,
            "moments",
            json!({"visual_view_changes_s":[2.0,2.0]}),
        );
        call(&mut p, "check", json!({"visual_view_changes_s":[2.0]}));
        assert_eq!(p.data, before);
        assert!(p.undo.is_empty());
    }
    #[test]
    fn check_visual_regions_use_evaluated_zoom_and_ignore_disabled_zooms() {
        let (_f, mut p) = setup();
        events(
            &mut p,
            json!([{ "t":1_000_000_000,"type":"down","x":160,"y":100 }]),
        );
        call(
            &mut p,
            "zoom_on_click",
            json!({"click_index":0,"scale":2.0}),
        );
        let hints = json!({"visual_view_changes":[
            {"at_s":1.5,"bbox":{"x":0.9,"y":0.8,"w":0.08,"h":0.1},"click_index":0},
            {"at_s":1.6,"bbox":{"x":0.45,"y":0.45,"w":0.1,"h":0.1}},
            {"at_s":3.0,"bbox":{"x":0.9,"y":0.8,"w":0.08,"h":0.1}}
        ]});
        let result = call(&mut p, "check", hints.clone());
        let warnings: Vec<_> = result["issues"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|r| r["kind"] == "zoom_hides_change")
            .collect();
        assert_eq!(warnings.len(), 1);
        assert_eq!(warnings[0]["at_s"], 1.5);
        assert_eq!(p.undo.len(), 1);
        p.data.zooms[0].enabled = false;
        assert!(!call(&mut p, "check", hints)["issues"]
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["kind"] == "zoom_hides_change"));
    }
    #[test]
    fn toast_cut_short_requires_result_click_and_less_than_one_second_before_cut() {
        let (_f, mut p) = setup();
        events(
            &mut p,
            json!([
                {"t":800_000_000,"type":"down","x":160,"y":100},
                {"t":1_000_000_000,"type":"focus","window_title":"Result"}
            ]),
        );
        p.apply(
            &json!({"op":"delete_range","tl_start_ns":1_400_000_000,"tl_end_ns":2_000_000_000}),
        )
        .unwrap();
        assert!(kinds(&mut p).contains(&"toast_cut_short".into()));
        for (hints, count) in [
            (json!({"visual_view_changes_s":[1.0]}), 1),
            (json!({"visual_view_changes_s":[]}), 0),
            (json!({"visual_view_changes_s":[0.2]}), 0),
            (json!({"visual_view_changes_s":[1.4]}), 0),
        ] {
            assert_eq!(
                call(&mut p, "check", hints)["issues"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .filter(|r| r["kind"] == "toast_cut_short")
                    .count(),
                count
            );
        }
        p.undo().unwrap();
        p.apply(
            &json!({"op":"delete_range","tl_start_ns":2_000_000_000,"tl_end_ns":3_000_000_000_i64}),
        )
        .unwrap();
        assert!(!kinds(&mut p).contains(&"toast_cut_short".into()));
        p.undo().unwrap();
        p.apply(
            &json!({"op":"delete_range","tl_start_ns":1_400_000_000,"tl_end_ns":5_000_000_000_i64}),
        )
        .unwrap();
        assert!(kinds(&mut p).contains(&"toast_cut_short".into()));
    }
    #[test]
    fn view_metadata_clamps_zoom_and_survives_cuts_speed_and_repeats() {
        let (_f, mut p) = setup();
        p.session.source.window_title = Some("Before".into());
        events(
            &mut p,
            json!([
                {"t":100_000_000,"type":"focus","window_title":"Before"},
                {"t":1_500_000_000,"type":"down","x":160,"y":100},
                {"t":1_600_000_000,"type":"focus","window_title":"Before"},
                {"t":1_800_000_000,"type":"focus","window_title":"After"},
                {"t":2_000_000_000,"type":"url","url":"https://example.test/result"}
            ]),
        );
        let m = call(&mut p, "moments", json!({}));
        assert_eq!(m["view_changes"].as_array().unwrap().len(), 2);
        assert_eq!(m["moments"][0]["view_change_s"], 1.8);
        let before = p.data.clone();
        let z = call(&mut p, "zoom_on_click", json!({"click_index":0}));
        assert_eq!(z["from_s"], 0.75);
        assert_eq!(z["to_s"], 1.75);
        assert_eq!(z["clamped"], true);
        assert!(z["message"].as_str().unwrap().contains("view change"));
        assert_eq!(p.undo.len(), 1);
        p.undo().unwrap();
        assert_eq!(p.data, before);
        let z = call(
            &mut p,
            "zoom_on_click",
            json!({"click_index":0,"start_s":0.2,"end_s":1.7}),
        );
        assert_eq!(z["from_s"], 0.2);
        assert_eq!(z["to_s"], 1.7);
        assert_eq!(z["clamped"], false);
        p.undo().unwrap();
        p.apply(&json!({"op":"delete_range","tl_start_ns":0,"tl_end_ns":500_000_000}))
            .unwrap();
        let mut c = p.data.timeline.clips[0].clone();
        c.speed = 2.0;
        let mut repeat = c.clone();
        repeat.id = "repeat".into();
        p.data.timeline.clips = vec![c, repeat];
        let m = call(&mut p, "moments", json!({"from_s":2.3}));
        let clicks: Vec<_> = m["moments"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|r| r["kind"] == "click")
            .collect();
        assert_eq!(clicks.len(), 1);
        assert_eq!(clicks[0]["click_index"], 1);
        assert_eq!(clicks[0]["window_title"], "Before");
        assert_eq!(clicks[0]["start_s"], 2.75);
        assert_eq!(clicks[0]["view_change_s"], 2.9);
    }
    #[test]
    fn zoom_timing_failures_and_context_fit_are_atomic() {
        let (_f, mut p) = setup();
        events(
            &mut p,
            json!([
                {"t":1_500_000_000,"type":"down","x":80,"y":100},
                {"t":2_000_000_000,"type":"down","x":240,"y":100}
            ]),
        );
        let before = p.data.clone();
        let z = call(
            &mut p,
            "zoom_on_click",
            json!({"click_index":0,"scale":4,"include":[1,{"x":0.2,"y":0.3,"w":0.6,"h":0.4}]}),
        );
        assert!((z["scale"].as_f64().unwrap() - 1.0 / 0.6).abs() < 1e-9);
        assert_eq!(z["target"], json!([0.5, 0.5]));
        let visible = p.frame_geometry(1_500_000_000).unwrap().screen_crop;
        assert!(visible.x <= 0.2 + 1e-9 && visible.x + visible.w >= 0.8 - 1e-9);
        assert!(visible.y <= 0.3 + 1e-9 && visible.y + visible.h >= 0.7 - 1e-9);
        p.undo().unwrap();
        assert_eq!(p.data, before);
        for args in [
            json!({"click_index":0,"start_s":1.6}),
            json!({"click_index":0,"end_s":1.5}),
            json!({"click_index":0,"include":[99]}),
            json!({"click_index":0,"include":[{"x":0,"y":0,"w":1,"h":1}]}),
            json!({"click_index":0,"include":[{"x":0.2,"y":0.2,"w":-0.1,"h":0.1}]}),
            json!({"click_index":0,"include":{}}),
        ] {
            assert!(
                Server {
                    project: &mut p,
                    initialized: true
                }
                .craft("zoom_on_click", &args)
                .is_err(),
                "{args}"
            );
            assert_eq!(p.data, before);
            assert!(p.undo.is_empty());
        }
        events(
            &mut p,
            json!([
                {"t":1_400_000_000,"type":"focus","window_title":"New"},
                {"t":1_500_000_000,"type":"down","x":80,"y":100},
                {"t":1_700_000_000,"type":"focus","window_title":"Next"}
            ]),
        );
        assert!(Server {
            project: &mut p,
            initialized: true
        }
        .craft("zoom_on_click", &json!({"click_index":0}))
        .is_err());
        assert_eq!(p.data, before);
    }
    #[test]
    fn activity_pauses_keep_clicks_scrolls_short_typing_and_active_tail() {
        for event in [
            json!({"type":"down","x":80,"y":100}),
            json!({"type":"scroll","dy":2}),
            json!({"type":"key","key":"a"}),
        ] {
            let (_f, mut p) = setup();
            speech(&mut p);
            let mut middle = event.clone();
            middle["t"] = json!(2_000_000_000);
            let mut tail = event;
            tail["t"] = json!(4_500_000_000_i64);
            events(&mut p, json!([middle, tail]));
            let before = p.data.clone();
            let issues = call(&mut p, "check", json!({}));
            assert_eq!(
                issues["issues"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .filter(|r| r["kind"] == "activity_pause" && r["severity"] == "info")
                    .count(),
                2
            );
            assert!(!kinds(&mut p).contains(&"long_pause".into()));
            let r = call(&mut p, "tighten_pauses", json!({}));
            assert_eq!(r["changed"], false);
            assert_eq!(r["activity_pauses_kept"].as_array().unwrap().len(), 2);
            assert_eq!(p.data, before);
            assert!(p.undo.is_empty());
            // A restricted range still preserves activity elsewhere in the same gap.
            assert_eq!(
                call(&mut p, "tighten_pauses", json!({"from_s":2.1,"to_s":2.6}))["changed"],
                false
            );
        }
    }
    #[test]
    fn typing_text_shortcuts_short_runs_and_zoom_warning() {
        let (_f, mut p) = setup();
        let mut input = vec![json!({"t":0,"type":"key","key":"k","modifiers":["cmd"]})];
        for (i, key) in ["H", "i", "space", "é", "!", "a", "b"].iter().enumerate() {
            input.push(json!({"t":100_000_000+i as i64*300_000_000,"type":"key","key":key}));
        }
        input.extend([
            json!({"t":2_500_000_000_i64,"type":"key","key":"x"}),
            json!({"t":2_600_000_000_i64,"type":"key","key":"y"}),
        ]);
        events(&mut p, json!(input));
        let m = call(&mut p, "moments", json!({}));
        let rows = m["moments"].as_array().unwrap();
        assert_eq!(rows.iter().filter(|r| r["kind"] == "key").count(), 1);
        let typing: Vec<_> = rows.iter().filter(|r| r["kind"] == "typing").collect();
        assert_eq!(typing.len(), 2);
        assert_eq!(typing[0]["text"], "Hi é!ab");
        assert_eq!(typing[1]["text"], "xy");
        assert_eq!(typing[1]["key_count"], 2);
        p.apply(&json!({"op":"add_zoom","tl_start_ns":0,"tl_end_ns":2_000_000_000,"target":[0.5,0.5],"scale":1.8})).unwrap();
        assert!(kinds(&mut p).contains(&"zoom_during_typing".into()));
        p.data.zooms[0].enabled = false;
        assert!(!kinds(&mut p).contains(&"zoom_during_typing".into()));
    }
    #[test]
    fn typing_activity_retimes_and_dismissal_does_not_hide_it() {
        let (_f, mut p) = setup();
        events(
            &mut p,
            json!((0..7)
                .map(|i| json!({"t":1_000_000_000_i64+i*300_000_000,"type":"key","key":"a"}))
                .collect::<Vec<_>>()),
        );
        let id = crate::auto::typing_bursts(&p)[0].id.clone();
        p.data.typing.dismissed.push(id);
        p.apply(&json!({"op":"delete_range","tl_start_ns":0,"tl_end_ns":500_000_000}))
            .unwrap();
        let id = p.data.timeline.clips[0].id.clone();
        p.apply(&json!({"op":"set_speed","clip_id":id,"speed":2}))
            .unwrap();
        let server = Server {
            project: &mut p,
            initialized: true,
        };
        assert_eq!(server.typing_ranges(), vec![(250_000_000, 1_150_000_000)]);
        assert!(overlaps(
            &server.activity_ranges().unwrap(),
            700_000_000,
            800_000_000
        ));
        p.apply(&json!({"op":"add_zoom","tl_start_ns":1_200_000_000,"tl_end_ns":2_400_000_000_i64,"target":[0.5,0.5],"scale":1.8})).unwrap();
        assert!(!kinds(&mut p).contains(&"zoom_during_typing".into()));
        p.undo().unwrap();
        p.apply(&json!({"op":"add_zoom","tl_start_ns":0,"tl_end_ns":1_100_000_000,"target":[0.5,0.5],"scale":1.8})).unwrap();
        assert!(kinds(&mut p).contains(&"zoom_during_typing".into()));
    }
    #[test]
    fn word_tools_atomic_and_noop_history() {
        let (_f, mut p) = setup();
        events(&mut p, json!([]));
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
        assert_eq!(z.ease_in_ns, 1_000_000_000);
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
        events(&mut p, json!([]));
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
        // Lead now extends to retain a full second when space exists.
        let extended = server
            .craft("zoom_on_click", &json!({"click_index":0}))
            .unwrap();
        assert_eq!(extended["from_s"], seconds(click - 900_000_000));
        server.project.undo().unwrap();
        let mut previous = base.clone();
        previous.id = "previous".into();
        previous.tl_start_ns = 0;
        previous.tl_end_ns = click - 500_000_000;
        server.project.data.zooms.push(previous);
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
