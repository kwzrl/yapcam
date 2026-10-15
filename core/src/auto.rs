//! Automatic edits derive from captured events; no global state or device access.
use crate::{
    commands::ChangeSet,
    model::*,
    project::{Error, Project, Result},
    time,
};
use serde_json::Value;
pub(crate) fn has_mouse_data(events: &[Vec<Event>]) -> bool {
    events
        .iter()
        .flatten()
        .any(|e| matches!(e.kind.as_str(), "move" | "down" | "up" | "cursor"))
}
pub fn generate_zooms(
    p: &mut ProjectData,
    context: &Project,
    options: &Value,
    cs: &mut ChangeSet,
) -> Result<()> {
    let scale = options
        .get("scale")
        .and_then(Value::as_f64)
        .unwrap_or(p.zoom_settings.default_scale);
    if !(1.0..=16.0).contains(&scale) {
        return Err(Error::new(1, "Invalid automatic zoom scale"));
    }
    p.zooms.retain(|z| z.mode != "auto");
    if !p.zoom_settings.automatic {
        cs.changed.push("zooms".into());
        return Ok(());
    }
    let points = context.session.source.content_rect_points;
    let mut candidates = Vec::new();
    let time_index = time::ClipTimeIndex::new(&p.timeline.clips);
    for (i, clip) in p.timeline.clips.iter().enumerate() {
        for (seg, events) in context.session.segments.iter().zip(&context.events) {
            let mut cursor = [points[2] / 2.0, points[3] / 2.0];
            let a = events.partition_point(|e| seg.src_start_ns + e.t < clip.src_start_ns);
            let b = events.partition_point(|e| seg.src_start_ns + e.t < clip.src_end_ns);
            if let Some(e) = events[..a]
                .iter()
                .rev()
                .find(|e| e.x.is_some() && e.y.is_some())
            {
                cursor = [e.x.unwrap(), e.y.unwrap()];
            }
            for e in &events[a..b] {
                if let (Some(x), Some(y)) = (e.x, e.y) {
                    cursor = [x, y];
                }
                if e.kind != "down" {
                    continue;
                }
                if let Some(t) =
                    time_index.source_to_timeline(&p.timeline.clips, i, seg.src_start_ns + e.t)
                {
                    candidates.push((
                        t,
                        [
                            (cursor[0] / points[2]).clamp(0.0, 1.0),
                            (cursor[1] / points[3]).clamp(0.0, 1.0),
                        ],
                    ));
                }
            }
        }
    }
    candidates.sort_by_key(|c| c.0);
    let duration = time::duration(&p.timeline.clips);
    let latest_click = duration.saturating_sub(1_000_000_000);
    let latest_end = duration.saturating_sub(800_000_000);
    let mut clusters: Vec<(i64, i64, [f64; 2])> = Vec::new();
    for (t, target) in candidates {
        if t >= latest_click {
            continue;
        }
        let start = t.saturating_sub(300_000_000).max(1_000_000);
        let end = t.saturating_add(2_500_000_000).min(latest_end);
        if end <= start {
            continue;
        }
        if let Some(last) = clusters.last_mut() {
            if start.saturating_sub(last.1) <= 2_500_000_000 {
                last.1 = last.1.max(end);
                continue;
            }
        }
        clusters.push((start, end, target));
    }
    for (i, (start, end, target)) in clusters.into_iter().enumerate() {
        if p.zooms
            .iter()
            .any(|z| z.mode == "manual" && z.tl_start_ns < end && z.tl_end_ns > start)
        {
            continue;
        }
        let base = format!("auto-{i}");
        let mut id = base.clone();
        let mut suffix = 0;
        while p.zooms.iter().any(|z| z.id == id) {
            suffix += 1;
            id = format!("{base}-{suffix}");
        }
        p.zooms.push(Zoom {
            id: id.clone(),
            tl_start_ns: start,
            tl_end_ns: end,
            mode: "auto".into(),
            target,
            scale,
            ease_in_ns: 300_000_000,
            ease_out_ns: 300_000_000,
            enabled: true,
        });
        cs.created_ids.push(id);
    }
    p.zooms.sort_by_key(|z| z.tl_start_ns);
    cs.changed.push("zooms".into());
    Ok(())
}
#[derive(Clone, Debug)]
pub(crate) struct TypingBurst {
    pub id: String,
    pub start: i64,
    pub end: i64,
    pub count: usize,
}
pub(crate) fn typing_bursts(context: &Project) -> Vec<TypingBurst> {
    let mut bursts = Vec::new();
    let mut current: Option<(usize, i64, i64, usize)> = None;
    let mut finish = |burst: Option<(usize, i64, i64, usize)>| {
        if let Some((_, start, end, count)) = burst {
            let span = end - start;
            if span >= 1_500_000_000 && count as i128 * 1_000_000_000 >= span as i128 * 2 {
                bursts.push(TypingBurst {
                    id: format!("typing-{start}-{end}"),
                    start,
                    end,
                    count,
                });
            }
        }
    };
    for (segment, t) in context.key_overlay_index.captured_times() {
        if current.is_some_and(|(s, _, last, _)| s != segment || t - last >= 500_000_000) {
            finish(current.take());
        }
        if let Some((_, _, last, count)) = &mut current {
            *last = t;
            *count += 1;
        } else {
            current = Some((segment, t, t, 1));
        }
    }
    finish(current);
    bursts
}
pub(crate) fn typing_suggestions(context: &Project) -> Value {
    let p = &context.data;
    let clock = time::ClipTimeIndex::new(&p.timeline.clips);
    typing_bursts(context).into_iter().filter(|b| !p.typing.dismissed.contains(&b.id)).filter_map(|b| {
        let ranges:Vec<_>=p.timeline.clips.iter().enumerate().filter_map(|(i,c)| {
            let a=b.start.max(c.src_start_ns);let end=b.end.min(c.src_end_ns);
            if end<=a {return None;}
            let start=clock.source_boundary_to_timeline(&p.timeline.clips,i,a)?;
            let end=clock.source_boundary_to_timeline(&p.timeline.clips,i,end)?;
            (end>start).then(||serde_json::json!({"tl_start_ns":start,"tl_end_ns":end}))
        }).collect();
        (!ranges.is_empty()).then(||serde_json::json!({"id":b.id,"src_start_ns":b.start,"src_end_ns":b.end,"key_count":b.count,"speed":p.typing.speed,"ranges":ranges}))
    }).collect::<Vec<_>>().into()
}
pub fn speed_typing(
    p: &mut ProjectData,
    context: &Project,
    options: &Value,
    cs: &mut ChangeSet,
) -> Result<()> {
    let speed = match options.get("speed") {
        Some(v) => v
            .as_f64()
            .ok_or_else(|| Error::new(1, "Invalid typing speed"))?,
        None => p.typing.speed,
    };
    if !(1.5..=8.0).contains(&speed) {
        return Err(Error::new(1, "Invalid typing speed"));
    }
    let id = options.get("id").and_then(Value::as_str);
    if options["op"] == "apply_typing_suggestion" && id.is_none() {
        return Err(Error::new(1, "Missing suggestion id"));
    }
    let bursts = typing_bursts(context);
    if id.is_some_and(|id| {
        !bursts
            .iter()
            .any(|b| b.id == id && !p.typing.dismissed.contains(&b.id))
    }) {
        return Err(Error::new(1, "Unknown typing suggestion"));
    }
    let ranges: Vec<_> = bursts
        .iter()
        .filter(|b| !p.typing.dismissed.contains(&b.id) && id.is_none_or(|id| b.id == id))
        .map(|b| (b.start, b.end))
        .collect();
    p.typing.speed = speed;
    cs.changed.push("typing.speed".into());
    // Splits partition source ranges exactly; only one shared clip list changes.
    let mut next = Vec::new();
    for clip in &p.timeline.clips {
        let mut boundaries = vec![clip.src_start_ns, clip.src_end_ns];
        for (a, b) in &ranges {
            if *a > clip.src_start_ns && *a < clip.src_end_ns {
                boundaries.push(*a);
            }
            if *b > clip.src_start_ns && *b < clip.src_end_ns {
                boundaries.push(*b);
            }
        }
        boundaries.sort();
        boundaries.dedup();
        for (n, pair) in boundaries.windows(2).enumerate() {
            let mut c = clip.clone();
            c.src_start_ns = pair[0];
            c.src_end_ns = pair[1];
            if n > 0 {
                c.id = crate::project::unique_id("clip");
                cs.created_ids.push(c.id.clone());
            }
            next.push(c);
        }
    }
    let before = next.clone();
    for c in &mut next {
        if ranges
            .iter()
            .any(|(a, b)| c.src_start_ns >= *a && c.src_end_ns <= *b)
        {
            c.speed = speed;
        }
    }
    let map = time::BulkSpeedTimeMap::new(&before, &next);
    crate::commands::remap_effects(p, |t| map.map(t));
    p.timeline.clips = next;
    cs.changed.extend([
        "timeline".into(),
        "zooms".into(),
        "camera.layouts".into(),
        "cursor.ranges".into(),
        "audio.ranges".into(),
        "canvas.highlights".into(),
        "canvas.annotations".into(),
        "canvas.reactions".into(),
        "canvas.captions".into(),
        "audio.music".into(),
    ]);
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::{model::Event, project::tests::Fixture};
    use serde_json::json;
    #[test]
    fn typing_suggestions_are_source_stable_dismissible_and_atomic() {
        let f = Fixture::new();
        let events: Vec<_> = [
            100_000_000_i64,
            400_000_000,
            700_000_000,
            1_000_000_000,
            1_300_000_000,
            1_600_000_000,
            2_100_000_000,
            2_400_000_000,
            2_700_000_000,
        ]
        .into_iter()
        .map(|t| json!({"t":t,"type":"key","key":"a"}).to_string())
        .collect();
        std::fs::write(
            f.0.join("recording/seg-000/events.jsonl"),
            events.join("\n") + "\n",
        )
        .unwrap();
        let mut p = Project::create(&f.0).unwrap();
        p.data.autosave = false;
        let query = json!({"q":"typing_suggestions"});
        let rows = p.query(&query).unwrap();
        assert_eq!(rows.as_array().unwrap().len(), 1);
        assert_eq!(rows[0]["key_count"], 6);
        assert_eq!(rows[0]["src_end_ns"], 1_600_000_000_i64);
        let id = rows[0]["id"].as_str().unwrap().to_owned();
        let before = p.data.clone();
        let history = p.undo.len();
        for command in [
            json!({"op":"apply_typing_suggestion","id":"missing"}),
            json!({"op":"dismiss_typing_suggestion","id":"missing"}),
            json!({"op":"apply_typing_suggestion","id":id,"speed":8.1}),
            json!({"op":"auto_speed_typing","speed":"fast"}),
            json!({"op":"set","path":"typing.speed","value":1.49}),
        ] {
            assert!(p.apply(&command).is_err());
            assert_eq!(p.data, before);
            assert_eq!(p.undo.len(), history);
        }
        p.apply(&json!({"op":"dismiss_typing_suggestion","id":id}))
            .unwrap();
        assert_eq!(p.query(&query).unwrap(), json!([]));
        assert!(p
            .apply(&json!({"op":"auto_speed_typing"}))
            .unwrap()
            .changed
            .is_empty());
        p.save(&f.0).unwrap();
        let reopened = Project::open(&f.0).unwrap();
        assert_eq!(reopened.query(&query).unwrap(), json!([]));
        p.undo().unwrap();
        assert_eq!(p.query(&query).unwrap(), rows);
        p.redo().unwrap();
        p.apply(&json!({"op":"restore_typing_suggestions"}))
            .unwrap();
        let frozen = p.clone();
        p.apply(&json!({"op":"apply_typing_suggestion","id":id,"speed":2}))
            .unwrap();
        assert_eq!(p.data.typing.speed, 2.0);
        assert_eq!(p.undo.len(), history + 3);
        assert_eq!(time::duration(&p.data.timeline.clips), 4_250_000_000);
        assert_eq!(
            p.query(&query).unwrap()[0]["ranges"],
            json!([{"tl_start_ns":100_000_000,"tl_end_ns":850_000_000}])
        );
        assert_eq!(frozen.query(&query).unwrap(), rows);
        let after = p.data.clone();
        assert!(p
            .apply(&json!({"op":"auto_speed_typing"}))
            .unwrap()
            .changed
            .is_empty());
        assert_eq!(p.data, after);
        p.undo().unwrap();
        assert_eq!(p.query(&query).unwrap(), rows);
        p.data.timeline.clips = vec![
            Clip {
                id: "first".into(),
                src_start_ns: 400_000_000,
                src_end_ns: 1_000_000_000,
                speed: 1.2,
            },
            Clip {
                id: "repeat".into(),
                src_start_ns: 700_000_000,
                src_end_ns: 1_300_000_000,
                speed: 2.0,
            },
        ];
        let rows = p.query(&query).unwrap();
        assert_eq!(rows[0]["id"], id);
        assert_eq!(
            rows[0]["ranges"],
            json!([{"tl_start_ns":0,"tl_end_ns":500_000_000},{"tl_start_ns":500_000_000,"tl_end_ns":800_000_000}])
        );
        p.apply(&json!({"op":"delete_range","tl_start_ns":0,"tl_end_ns":200_000_000}))
            .unwrap();
        assert_eq!(p.query(&query).unwrap()[0]["id"], id);
        p.save(&f.0).unwrap();
        assert_eq!(
            Project::open(&f.0).unwrap().query(&query).unwrap(),
            p.query(&query).unwrap()
        );
        // Sub-threshold duration and exact 500ms gaps cannot manufacture bursts.
        p.events[0] = [
            0_i64,
            300_000_000,
            600_000_000,
            900_000_000,
            1_200_000_000,
            1_499_999_999,
            2_000_000_000,
            2_500_000_000,
        ]
        .into_iter()
        .map(|t| serde_json::from_value(json!({"t":t,"type":"key"})).unwrap())
        .collect();
        p.rebuild_key_overlay_index();
        assert!(typing_bursts(&p).is_empty());
    }
    #[test]
    fn click_windows_merge_at_gap_boundary_and_leave_a_tail() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.data.autosave = false;
        p.session.segments[0].duration_ns = 30_000_000_000;
        p.session.segments[1].src_start_ns = 30_000_000_000;
        p.data.timeline.clips = vec![Clip {
            id: "long".into(),
            src_start_ns: 0,
            src_end_ns: 30_000_000_000,
            speed: 1.0,
        }];
        p.events[0] = [
            1_000_000_000_i64,
            6_300_000_000,
            11_600_000_001,
            28_900_000_000,
            29_000_000_000,
        ]
        .into_iter()
        .enumerate()
        .map(|(i, t)| {
            serde_json::from_value(json!({"t":t,"type":"down","x":if i%2==0 {0} else {320},"y":0}))
                .unwrap()
        })
        .collect();
        p.events[0]
            .push(serde_json::from_value(json!({"t":500_000_000,"type":"key","key":"a"})).unwrap());
        p.events[0].sort_by_key(|e| e.t);
        p.events[1].clear();
        let before = p.data.clone();
        p.apply(&json!({"op":"auto_zooms"})).unwrap();
        let bounds: Vec<_> = p
            .data
            .zooms
            .iter()
            .map(|z| (z.tl_start_ns, z.tl_end_ns))
            .collect();
        assert_eq!(
            bounds,
            [
                (700_000_000, 8_800_000_000),
                (11_300_000_001, 14_100_000_001),
                (28_600_000_000, 29_200_000_000)
            ]
        );
        assert!(p
            .data
            .zooms
            .iter()
            .all(|z| z.scale == 2.0 && z.mode == "auto"));
        assert!(p
            .apply(&json!({"op":"auto_zooms"}))
            .unwrap()
            .changed
            .is_empty());
        p.undo().unwrap();
        assert_eq!(p.data, before);
        p.redo().unwrap();
        assert_eq!(p.data.zooms.len(), 3);
        p.events.iter_mut().for_each(Vec::clear);
        p.apply(&json!({"op":"add_zoom","tl_start_ns":0,"tl_end_ns":1_000_000_000,"mode":"auto","target":[0.5,0.5],"scale":2,"ease_in_ns":0,"ease_out_ns":0})).unwrap();
        assert_eq!(p.data.zooms.last().unwrap().mode, "manual");
    }
    #[test]
    fn windowed_candidates_keep_prior_coordinates_and_repeat_on_each_clip() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.events[0] = [
            json!({"t":0,"type":"move","x":32,"y":40}),
            json!({"t":700_000_000,"type":"down"}),
            json!({"t":2_900_000_000_i64,"type":"down","x":256,"y":100}),
        ]
        .into_iter()
        .map(|v| serde_json::from_value(v).unwrap())
        .collect();
        p.events[1].clear();
        p.data.timeline.clips = vec![
            Clip {
                id: "retained".into(),
                src_start_ns: 600_000_000,
                src_end_ns: 2_900_000_000,
                speed: 1.0,
            },
            Clip {
                id: "repeat".into(),
                src_start_ns: 600_000_000,
                src_end_ns: 2_900_000_000,
                speed: 2.0,
            },
        ];
        p.apply(&json!({"op":"auto_zooms"})).unwrap();
        assert_eq!(p.data.zooms.len(), 1);
        assert_eq!(p.data.zooms[0].target, [0.1, 0.2]);
        assert_eq!(p.data.zooms[0].tl_end_ns, 2_650_000_000);
        let before = p.data.clone();
        p.apply(&json!({"op":"auto_zooms"})).unwrap();
        assert_eq!(p.data, before);
    }
    #[test]
    fn clusters_typing_manual_preservation_and_global_off() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        // Three separated clusters spanning both capture segments.
        p.events[0].retain(|e| e.kind != "down");
        p.events[1].retain(|e| e.kind != "down");
        for t in [300_000_000, 400_000_000, 1_800_000_000] {
            p.events[0].push(
                serde_json::from_value::<Event>(json!({"t":t,"type":"down","x":160,"y":100}))
                    .unwrap(),
            );
        }
        p.events[1]
            .push(serde_json::from_value(json!({"t":700_000_000,"type":"key","key":"a"})).unwrap());
        for events in &mut p.events {
            events.sort_by_key(|e| e.t);
        }
        p.apply(&json!({"op":"auto_zooms"})).unwrap();
        assert_eq!(p.data.zooms.len(), 1);
        let once = p.data.zooms.clone();
        p.apply(&json!({"op":"auto_zooms"})).unwrap();
        assert_eq!(p.data.zooms, once);
        p.apply(&json!({"op":"add_zoom","zoom":{"tl_start_ns":100_000_000,"tl_end_ns":1_000_000_000,"mode":"manual","target":[0.5,0.5],"scale":2,"ease_in_ns":0,"ease_out_ns":0}})).unwrap();
        p.apply(&json!({"op":"auto_zooms"})).unwrap();
        assert_eq!(p.data.zooms.iter().filter(|z| z.mode == "auto").count(), 0);
        p.apply(&json!({"op":"set","path":"zoom_settings.automatic","value":false}))
            .unwrap();
        p.apply(&json!({"op":"auto_zooms"})).unwrap();
        assert_eq!(p.data.zooms.len(), 1);
    }
    #[test]
    fn typing_speed_and_silence_are_one_undo_step() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        let original = p.data.clone();
        for t in [
            800_000_000_i64,
            1_200_000_000,
            1_600_000_000,
            2_000_000_000,
            2_400_000_000,
        ] {
            p.events[0]
                .push(serde_json::from_value(json!({"t":t,"type":"key","key":"a"})).unwrap());
        }
        p.events[0].sort_by_key(|e| e.t);
        p.rebuild_key_overlay_index();
        p.apply(&json!({"op":"auto_speed_typing","speed":3}))
            .unwrap();
        assert_eq!(p.data.timeline.clips.len(), 3);
        assert_eq!(p.data.timeline.clips[1].speed, 3.0);
        assert_eq!(time::duration(&p.data.timeline.clips), 3_933_333_333);
        p.undo().unwrap();
        assert_eq!(p.data, original);
        p.apply(&json!({"op":"process_silence","mode":"cut","ranges":[{"tl_start_ns":0,"tl_end_ns":1_000_000_000},{"tl_start_ns":500_000_000,"tl_end_ns":2_000_000_000}]})).unwrap();
        assert_eq!(time::duration(&p.data.timeline.clips), 3_000_000_000);
        p.undo().unwrap();
        assert_eq!(p.data, original);
        p.apply(&json!({"op":"process_silence","mode":"speed","speed":2,"ranges":[{"tl_start_ns":1_000_000_000,"tl_end_ns":2_000_000_000}]})).unwrap();
        assert_eq!(time::duration(&p.data.timeline.clips), 4_500_000_000);
        p.undo().unwrap();
        assert_eq!(p.data, original);
    }
}
#[cfg(test)]
mod identity_tests {
    use super::*;
    use crate::project::tests::Fixture;
    use serde_json::json;
    #[test]
    fn moved_manual_former_auto_does_not_collide() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.apply(&json!({"op":"auto_zooms"})).unwrap();
        let id = p.data.zooms[0].id.clone();
        p.apply(&json!({"op":"update_zoom","id":id,"patch":{"mode":"manual","tl_start_ns":0,"tl_end_ns":100_000_000}})).unwrap();
        p.apply(&json!({"op":"auto_zooms"})).unwrap();
        assert!(p.data.zooms.iter().any(|z| z.id == "auto-0-1"));
        let once = p.data.zooms.clone();
        let cs = p.apply(&json!({"op":"auto_zooms"})).unwrap();
        assert_eq!(p.data.zooms, once);
        assert!(cs.changed.is_empty());
    }
}
