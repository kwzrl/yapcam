//! Measures how much an automatic zoom pans while it follows the cursor.
//! `cargo test zoom_calm_measure -- --ignored --nocapture` (needs ZOOMCALM_PROJECT).
use crate::project::Project;

pub(crate) struct PanStats {
    pub path: f64,
    pub moving_frames: usize,
    pub runs: usize,
    pub max_speed: f64,
    pub frames: usize,
}

/// Samples the crop centre every 1/60 s in [start, end] and sums its movement.
pub(crate) fn pan_stats(p: &Project, start_ns: i64, end_ns: i64) -> PanStats {
    const STEP: i64 = 1_000_000_000 / 60;
    const MOVING: f64 = 1e-4;
    let mut stats = PanStats {
        path: 0.0,
        moving_frames: 0,
        runs: 0,
        max_speed: 0.0,
        frames: 0,
    };
    let mut previous: Option<[f64; 2]> = None;
    let mut was_moving = false;
    let mut tl = start_ns;
    while tl <= end_ns {
        let c = p.frame(tl).unwrap().screen_crop;
        let centre = [c.x + c.w / 2.0, c.y + c.h / 2.0];
        if let Some(prev) = previous {
            let d = ((centre[0] - prev[0]).powi(2) + (centre[1] - prev[1]).powi(2)).sqrt();
            stats.path += d;
            stats.max_speed = stats.max_speed.max(d * 60.0);
            let moving = d > MOVING;
            if moving {
                stats.moving_frames += 1;
                if !was_moving {
                    stats.runs += 1;
                }
            }
            was_moving = moving;
        }
        previous = Some(centre);
        stats.frames += 1;
        tl += STEP;
    }
    stats
}

fn print(label: &str, s: &PanStats) {
    println!(
        "{label}: path {:.4} | moving frames {}/{} | pan runs {} | max speed {:.4}/s",
        s.path, s.moving_frames, s.frames, s.runs, s.max_speed
    );
}

#[test]
#[ignore]
fn zoom_calm_measure() {
    let path = std::env::var("ZOOMCALM_PROJECT").expect("set ZOOMCALM_PROJECT");
    let mut p = Project::open(std::path::Path::new(&path)).unwrap();
    p.data.autosave = false;
    let zooms: Vec<(i64, i64, i64, i64)> = p
        .data
        .zooms
        .iter()
        .map(|z| (z.tl_start_ns, z.tl_end_ns, z.ease_in_ns, z.ease_out_ns))
        .collect();
    for (start, end, ease_in, ease_out) in zooms.iter().copied() {
        print("whole zoom", &pan_stats(&p, start, end));
        print(
            "hold only ",
            &pan_stats(&p, start + ease_in, end - ease_out),
        );
    }
    if std::env::var("ZOOMCALM_TRACE").is_ok() {
        let (start, end, _, _) = zooms[0];
        let mut tl = start;
        while tl <= end {
            let c = p.frame(tl).unwrap().screen_crop;
            let (_, src) = crate::time::timeline_to_source(&p.data.timeline.clips, tl).unwrap();
            let seg = crate::time::sample(&p.session, "screen", src).segment as usize;
            let pt = p.input[seg]
                .position_filtered(
                    src - p.session.segments[seg].src_start_ns,
                    p.data.cursor.remove_shakes,
                )
                .unwrap();
            let r = p.session.source.content_rect_points;
            println!(
                "{:.2}s crop {:.4} {:.4} {:.4} {:.4} cursor {:.3} {:.3}",
                tl as f64 / 1e9,
                c.x,
                c.y,
                c.w,
                c.h,
                pt.x / r[2],
                pt.y / r[3]
            );
            tl += 100_000_000;
        }
    }
    p.data.zoom_settings.follow_cursor = false;
    for (start, end, _, _) in zooms {
        print("no follow ", &pan_stats(&p, start, end));
    }
}

fn synthetic(path: impl Fn(f64) -> [f64; 2]) -> (Project, crate::project::tests::Fixture) {
    let fixture = crate::project::tests::Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();
    p.data.autosave = false;
    p.data.zoom_settings.smart_framing = false;
    p.data.zooms = vec![crate::model::Zoom {
        style: "classic".into(),
        lens: Default::default(),
        id: "calm".into(),
        tl_start_ns: 0,
        tl_end_ns: 3_000_000_000,
        mode: "auto".into(),
        target: [0.5, 0.5],
        scale: 2.0,
        ease_in_ns: 0,
        ease_out_ns: 0,
        enabled: true,
    }];
    p.events[0] = (0..180)
        .map(|i| {
            let t = i as f64 / 60.0;
            let [x, y] = path(t);
            serde_json::from_value(serde_json::json!({
                "t": (t * 1e9) as i64, "type": "move", "x": x * 320.0, "y": y * 200.0
            }))
            .unwrap()
        })
        .collect();
    p.input[0] = crate::input::InputCache::new(&p.events[0]);
    (p, fixture)
}

fn jitter(t: f64) -> f64 {
    0.01 * (t * 37.0).sin()
}

#[test]
fn calm_follow_ignores_small_moves_inside_the_zoomed_view() {
    let (p, _f) = synthetic(|t| [0.5 + 0.12 * (t * 2.0).sin() + jitter(t), 0.45 + jitter(t)]);
    assert_eq!(p.data.zoom_settings.physics_version, 2);
    let s = pan_stats(&p, 0, 2_900_000_000);
    assert_eq!(
        s.path, 0.0,
        "view moved {} without the cursor nearing an edge",
        s.path
    );
}

#[test]
fn calm_follow_glides_once_when_the_cursor_reaches_the_edge() {
    // The cursor creeps right to the edge of the 0.25..0.75 view and fidgets there.
    let creep = |t: f64| [0.5 + 0.24 * (t / 1.5).min(1.0) + jitter(t), 0.5 + jitter(t)];
    let (mut p, _f) = synthetic(creep);
    let calm = pan_stats(&p, 0, 2_900_000_000);
    let end = p.frame(2_900_000_000).unwrap().screen_crop;
    // The cursor (~0.74) is brought back out of the 0.1 edge band, towards 0.2.
    let inside = (end.x + end.w - 0.74) / end.w;
    assert!(inside > 0.11 && inside < 0.21, "{end:?}");
    assert_eq!(calm.runs, 1, "one glide, not {} twitches", calm.runs);
    // Legacy follow (physics v1) keeps chasing every fidget at the edge.
    p.data.zoom_settings.physics_version = 1;
    let legacy = pan_stats(&p, 0, 2_900_000_000);
    assert!(
        legacy.moving_frames > calm.moving_frames,
        "{} vs {}",
        legacy.moving_frames,
        calm.moving_frames
    );
}
