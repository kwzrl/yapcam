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
/// One automatic zoom: a run of clicks without a long pause whose bounding box still fits one zoomed view.
/// `wide`: the clicks spread over the screen too fast to follow; that stretch gets no zoom.
struct Cluster {
    start: i64,
    end: i64,
    min: [f64; 2],
    max: [f64; 2],
    wide: bool,
}
/// A pause longer than this ends a run of clicks.
const PAUSE_NS: i64 = 2_500_000_000;
/// A cluster only zooms if its clicks, with margin, fit a view at least this deep.
const MIN_FIT_SCALE: f64 = 1.5;
/// Room kept around the outermost clicks, per side (normalized content coordinates).
const BOX_MARGIN: f64 = 0.1;
/// A zoom that has held this long ends at a far click instead of the whole stretch going wide.
const SETTLED_NS: i64 = 3_000_000_000;
/// Zooms closer than this join when their clicks fit one view.
const JOIN_GAP_NS: i64 = 1_000_000_000;

fn grow(min: [f64; 2], max: [f64; 2], p: [f64; 2]) -> ([f64; 2], [f64; 2]) {
    ([min[0].min(p[0]), min[1].min(p[1])], [max[0].max(p[0]), max[1].max(p[1])])
}
/// The deepest zoom that still shows the whole box with margin, if it is at least `MIN_FIT_SCALE`.
fn fit_scale(min: [f64; 2], max: [f64; 2]) -> Option<f64> {
    let side = (max[0] - min[0]).max(max[1] - min[1]) + 2.0 * BOX_MARGIN;
    let scale = 1.0 / side;
    (scale >= MIN_FIT_SCALE).then_some(scale)
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
    if !p.zoom_settings.automatic || crate::capabilities::external(&context.session.source.kind) {
        cs.changed.push("zooms".into());
        return Ok(());
    }
    let points = context.session.source.content_rect_points;
    let mut candidates = Vec::new();
    let time_index = time::ClipTimeIndex::new(&p.timeline.clips);
    for (i, clip) in p.timeline.clips.iter().enumerate() {
        for (seg, input) in context.session.segments.iter().zip(&context.input) {
            let a = input
                .clicks
                .partition_point(|e| seg.src_start_ns + e.t < clip.src_start_ns);
            let b = input
                .clicks
                .partition_point(|e| seg.src_start_ns + e.t < clip.src_end_ns);
            for (j, e) in input.clicks[a..b].iter().enumerate() {
                let cursor = if input.click_has_position[a + j] {
                    [e.x, e.y]
                } else {
                    [points[2] / 2.0, points[3] / 2.0]
                };
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
    let mut clusters: Vec<Cluster> = Vec::new();
    for (t, target) in candidates {
        if t >= latest_click {
            continue;
        }
        let start = t.saturating_sub(300_000_000).max(1_000_000);
        let end = t.saturating_add(2_500_000_000).min(latest_end);
        if end <= start {
            continue;
        }
        if let Some(c) = clusters.last_mut() {
            if start.saturating_sub(c.end) <= PAUSE_NS {
                if c.wide {
                    c.end = c.end.max(end);
                    continue;
                }
                let (min, max) = grow(c.min, c.max, target);
                if fit_scale(min, max).is_some() {
                    (c.min, c.max, c.end) = (min, max, c.end.max(end));
                    continue;
                }
                if t - c.start < SETTLED_NS {
                    // Clicks all over the screen in quick succession: show the whole screen, not a zoom ping-pong.
                    c.wide = true;
                    c.end = c.end.max(end);
                    continue;
                }
                // A settled zoom hands over where the far click's zoom starts; zooms never overlap.
                c.end = c.end.min(start).max(c.start + 1);
            }
        }
        clusters.push(Cluster { start, end, min: target, max: target, wide: false });
    }
    // Zooms less than a second apart become one when their clicks still fit one view.
    let mut joined: Vec<Cluster> = Vec::new();
    for c in clusters {
        if let Some(prev) = joined.last_mut() {
            let (min, max) = grow(prev.min, prev.max, c.min);
            let (min, max) = grow(min, max, c.max);
            if !prev.wide && !c.wide && c.start - prev.end < JOIN_GAP_NS && fit_scale(min, max).is_some() {
                (prev.min, prev.max, prev.end) = (min, max, prev.end.max(c.end));
                continue;
            }
        }
        joined.push(c);
    }
    // New projects carry their zoom ease in the insertion style; automatic zooms move the same way.
    let ease = if p.zoom_settings.physics_version >= 2 {
        p.insertion_styles
            .zoom
            .as_ref()
            .map_or(1_000_000_000, |s| s.ease_in_ns)
    } else {
        300_000_000
    };
    let zooming = joined.into_iter().filter(|c| !c.wide);
    for (i, c) in zooming.enumerate() {
        let (start, end) = (c.start, c.end);
        let target = [(c.min[0] + c.max[0]) / 2.0, (c.min[1] + c.max[1]) / 2.0];
        // Close enough to show every click of the cluster, never deeper than the project's zoom.
        let scale = fit_scale(c.min, c.max).map_or(scale, |fit| fit.min(scale));
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
            style: "classic".into(),
            lens: Default::default(),
            id: id.clone(),
            tl_start_ns: start,
            tl_end_ns: end,
            mode: "auto".into(),
            target,
            scale,
            ease_in_ns: ease,
            ease_out_ns: ease,
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
    let clock = time::ClipTimeIndex::new(&before);
    let boundaries: Vec<_> = before
        .iter()
        .enumerate()
        .map(|(i, c)| {
            clock
                .source_boundary_to_timeline(&before, i, c.src_start_ns)
                .unwrap()
        })
        .collect();
    crate::commands::seed_mask_keyframes(p, &boundaries);
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
                settings: Default::default(),
            },
            Clip {
                id: "repeat".into(),
                src_start_ns: 700_000_000,
                src_end_ns: 1_300_000_000,
                speed: 2.0,
                settings: Default::default(),
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
        p.apply(&json!({"op":"auto_speed_typing","speed":3}))
            .unwrap();
        assert_eq!(time::duration(&p.data.timeline.clips), 320_000_000);
        assert_eq!(
            p.query(&query).unwrap()[0]["ranges"],
            json!([{"tl_start_ns":0,"tl_end_ns":120_000_000},{"tl_start_ns":120_000_000,"tl_end_ns":320_000_000}])
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
            settings: Default::default(),
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
            serde_json::from_value(json!({"t":t,"type":"down","x":if i%2==0 {0} else {10},"y":0}))
                .unwrap()
        })
        .collect();
        p.events[0]
            .push(serde_json::from_value(json!({"t":500_000_000,"type":"key","key":"a"})).unwrap());
        p.events[0].sort_by_key(|e| e.t);
        p.events[1].clear();
        p.input = p
            .events
            .iter()
            .map(|e| crate::input::InputCache::new(e))
            .collect();
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
    fn auto_zoom_bounds(events: Vec<Value>) -> Vec<(i64, i64, [f64; 2])> {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.data.autosave = false;
        p.session.segments[0].duration_ns = 60_000_000_000;
        p.session.segments[1].src_start_ns = 60_000_000_000;
        p.data.timeline.clips = vec![Clip {
            id: "long".into(),
            src_start_ns: 0,
            src_end_ns: 60_000_000_000,
            speed: 1.0,
            settings: Default::default(),
        }];
        p.events[0] = events.into_iter().map(|e| serde_json::from_value(e).unwrap()).collect();
        p.events[1].clear();
        p.input = p.events.iter().map(|e| crate::input::InputCache::new(e)).collect();
        p.apply(&json!({"op":"auto_zooms"})).unwrap();
        p.data.zooms.iter().map(|z| (z.tl_start_ns, z.tl_end_ns, z.target)).collect()
    }
    fn content_points() -> [f64; 4] {
        let f = Fixture::new();
        let points = Project::create(&f.0).unwrap().session.source.content_rect_points;
        points
    }
    #[test]
    fn nearby_clicks_become_one_zoom_that_shows_all_of_them() {
        let s = 1_000_000_000_i64;
        let w = content_points()[2];
        let z = auto_zoom_bounds(vec![
            json!({"t":s,"type":"down","x":w*0.2,"y":0,"button":"left"}),
            json!({"t":3*s,"type":"down","x":w*0.4,"y":0,"button":"left"}),
            json!({"t":5*s,"type":"down","x":w*0.3,"y":0,"button":"left"}),
        ]);
        assert_eq!(z.len(), 1);
        assert_eq!((z[0].0, z[0].1), (700_000_000, 7_500_000_000));
        assert!((z[0].2[0] - 0.3).abs() < 1e-9);
    }
    #[test]
    fn clicks_all_over_the_screen_in_quick_succession_get_no_zoom() {
        let s = 1_000_000_000_i64;
        let w = content_points()[2];
        let z = auto_zoom_bounds(
            [0.05, 0.95, 0.1, 0.9, 0.5]
                .iter()
                .enumerate()
                .map(|(i, x)| json!({"t":(i as i64 + 1)*s,"type":"down","x":w*x,"y":0,"button":"left"}))
                .collect(),
        );
        assert!(z.is_empty(), "{z:?}");
    }
    #[test]
    fn a_settled_zoom_hands_over_to_a_far_click_without_overlap() {
        let s = 1_000_000_000_i64;
        let w = content_points()[2];
        let z = auto_zoom_bounds(vec![
            json!({"t":s,"type":"down","x":0,"y":0}),
            json!({"t":3*s,"type":"down","x":w*0.05,"y":0}),
            json!({"t":5*s,"type":"down","x":w,"y":0}),
        ]);
        assert_eq!(z.len(), 2, "{z:?}");
        assert_eq!(z[0].1, z[1].0, "the first zoom ends where the second starts");
        assert!(z[1].2[0] > 0.9);
    }
    #[test]
    fn a_long_run_of_clicks_in_one_place_stays_one_zoom() {
        let s = 1_000_000_000_i64;
        let z = auto_zoom_bounds((1..=25).map(|i| json!({"t":i*s,"type":"down","x":0,"y":0})).collect());
        assert_eq!(z.len(), 1);
    }
    #[test]
    fn kilians_take_of_october_19_gives_four_calm_zooms_instead_of_eight() {
        // The 12 clicks of Recording-2026-10-19T175625 (content 1680x1050), scaled to the fixture.
        let points = content_points();
        let clicks = [
            (2_229_366_042_i64, 661.3, 683.5), (7_025_663_833, 380.0, 207.2), (7_822_470_417, 673.0, 845.1),
            (8_407_338_667, 705.7, 826.9), (9_757_279_375, 976.9, 821.8), (10_457_907_083, 1301.2, 773.6),
            (12_658_082_708, 1127.5, 591.6), (13_524_133_500, 843.6, 565.9), (14_273_590_792, 494.8, 373.9),
            (16_425_015_125, 1208.3, 473.5), (18_140_068_458, 1655.6, 569.0), (20_492_256_083, 1071.6, 467.7),
        ];
        let z = auto_zoom_bounds(
            clicks
                .iter()
                .map(|(t, x, y)| json!({"t":t,"type":"down","x":x/1680.0*points[2],"y":y/1050.0*points[3],"button":"left"}))
                .collect(),
        );
        assert_eq!(z.len(), 4, "{z:?}");
        assert!(z.windows(2).all(|w| w[0].1 <= w[1].0));
    }
    #[test]
    fn right_and_other_clicks_do_not_zoom() {
        let s = 1_000_000_000_i64;
        assert!(auto_zoom_bounds(vec![
            json!({"t":s,"type":"down","x":0,"y":0,"button":"right"}),
            json!({"t":10*s,"type":"down","x":0,"y":0,"button":"other"}),
        ])
        .is_empty());
        // Left clicks and recordings from before the button was captured still zoom.
        assert_eq!(
            auto_zoom_bounds(vec![
                json!({"t":s,"type":"down","x":0,"y":0,"button":"left"}),
                json!({"t":10*s,"type":"down","x":0,"y":0}),
            ])
            .len(),
            2
        );
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
        p.input = p
            .events
            .iter()
            .map(|e| crate::input::InputCache::new(e))
            .collect();
        p.data.timeline.clips = vec![
            Clip {
                id: "retained".into(),
                src_start_ns: 600_000_000,
                src_end_ns: 2_900_000_000,
                speed: 1.0,
                settings: Default::default(),
            },
            Clip {
                id: "repeat".into(),
                src_start_ns: 600_000_000,
                src_end_ns: 2_900_000_000,
                speed: 2.0,
                settings: Default::default(),
            },
        ];
        p.apply(&json!({"op":"auto_zooms"})).unwrap();
        assert_eq!(p.data.zooms.len(), 1);
        assert_eq!(p.data.zooms[0].target, [0.1, 0.2]);
        assert_eq!(p.data.zooms[0].tl_end_ns, 2_650_000_000);
        let before = p.data.clone();
        p.apply(&json!({"op":"auto_zooms"})).unwrap();
        assert_eq!(p.data, before);
        // A down without any earlier position uses the center, including when a
        // move at the same timestamp was recorded later in the event sequence.
        p.events[0] = vec![
            serde_json::from_value(json!({"t":700_000_000,"type":"down"})).unwrap(),
            serde_json::from_value(json!({"t":700_000_000,"type":"move","x":0,"y":0})).unwrap(),
        ];
        p.input = p
            .events
            .iter()
            .map(|e| crate::input::InputCache::new(e))
            .collect();
        p.apply(&json!({"op":"auto_zooms"})).unwrap();
        assert_eq!(p.data.zooms[0].target, [0.5, 0.5]);
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
        p.input = p
            .events
            .iter()
            .map(|e| crate::input::InputCache::new(e))
            .collect();
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
