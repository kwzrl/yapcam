//! Reproducible M3 scale, migration and foreign-boundary stress harnesses.
use crate::{
    ffi::*,
    model::*,
    project::{tests::Fixture, Project},
};
use std::{collections::BTreeMap, ffi::CString, time::Instant};

fn rng(seed: &mut u64) -> u64 {
    *seed ^= *seed << 13;
    *seed ^= *seed >> 7;
    *seed ^= *seed << 17;
    *seed
}
fn percentiles(mut samples: Vec<u64>) -> (f64, f64, f64) {
    samples.sort_unstable();
    let pick =
        |p: usize| samples[((samples.len() * p).div_ceil(100)).saturating_sub(1)] as f64 / 1e6;
    (pick(50), pick(99), *samples.last().unwrap() as f64 / 1e6)
}
#[test]
#[ignore = "60 minute / 3.6M event release benchmark; run --release --ignored --nocapture scale_60_minutes"]
fn scale_60_minutes() {
    assert!(
        !std::hint::black_box(cfg!(debug_assertions)),
        "Scale timings require --release"
    );
    let fixture = Fixture::new();
    let mut p = Project::create(&fixture.0).unwrap();
    const END: i64 = 3_600_000_000_000;
    p.session.segments.truncate(1);
    p.session.segments[0].duration_ns = END;
    p.session.segments[0].track_start_ns.clear();
    p.data.timeline.clips = (0..5000)
        .map(|i| Clip {
            id: format!("scale-{i}"),
            src_start_ns: i * (END / 5000),
            src_end_ns: (i + 1) * (END / 5000),
            speed: 1.0,
            settings: Default::default(),
        })
        .collect();
    p.data.zooms = (0..1000)
        .map(|i| Zoom {
            style: "classic".into(),
            lens: Default::default(),
            id: format!("scale-zoom-{i}"),
            tl_start_ns: i * (END / 1000),
            tl_end_ns: (i + 1) * (END / 1000),
            mode: "manual".into(),
            target: [0.5, 0.5],
            scale: 2.0,
            ease_in_ns: 250_000_000,
            ease_out_ns: 250_000_000,
            enabled: true,
        })
        .collect();
    let build = Instant::now();
    let events: Vec<_> = (0..3_600_000)
        .map(|i| Event {
            t: i * 1_000_000,
            kind: if i % 1000 == 0 {
                "down"
            } else if i % 100 == 1 {
                "key"
            } else {
                "move"
            }
            .into(),
            x: Some(160.0 + 120.0 * (i as f64 / 1200.0).sin()),
            y: Some(100.0 + 80.0 * (i as f64 / 900.0).cos()),
            id: None,
            details: if i % 100 == 1 {
                BTreeMap::from([
                    ("key".into(), serde_json::json!("k")),
                    (
                        "modifiers".into(),
                        if i % 200 == 1 {
                            serde_json::json!(["cmd", "shift"])
                        } else {
                            serde_json::json!([])
                        },
                    ),
                ])
            } else {
                BTreeMap::new()
            },
        })
        .collect();
    p.input = vec![crate::input::InputCache::new(&events)];
    p.events = vec![events];
    p.data.cursor.key_overlay.enabled = true;
    p.data.cursor.smoothing = 1.0;
    p.data.cursor.speed_preset = "rapid".into();
    p.rebuild_key_overlay_index();
    crate::project::validate_data(&p.data).unwrap();
    let path = CString::new(fixture.0.to_str().unwrap()).unwrap();
    let handle = Box::into_raw(Box::new(YcProject::new(p)));
    struct Owned(*mut YcProject);
    impl Drop for Owned {
        fn drop(&mut self) {
            unsafe {
                yc_project_free(self.0);
            }
        }
    }
    let owned = Owned(handle);
    println!("SCALE workload=60min events=3600000 rate_hz=1000 clips=5000 zooms=1000 build_s={:.3} clock=Instant profile=release seed=0x19bc48", build.elapsed().as_secs_f64());
    let mut seed = 0x19bc48;
    let mut frame = crate::frame::Frame::default();
    let mut frames = Vec::with_capacity(2048);
    for i in 0..2080 {
        let t = (rng(&mut seed) % END as u64) as i64;
        let start = Instant::now();
        assert_eq!(unsafe { yc_frame_at(handle, t, &mut frame) }, 0);
        std::hint::black_box(frame);
        if i >= 32 {
            frames.push(start.elapsed().as_nanos() as u64);
        }
    }
    let frame_stats = percentiles(frames);
    println!(
        "SCALE yc_frame_at n=2048 p50_ms={:.6} p99_ms={:.6} max_ms={:.6}",
        frame_stats.0, frame_stats.1, frame_stats.2
    );
    assert_eq!(
        crate::allocation_test::count(|| {
            assert_eq!(unsafe { yc_frame_at(handle, END - 1, &mut frame) }, 0);
        }),
        0
    );
    let mut overlay = Vec::new();
    for _ in 0..1024 {
        let t = (rng(&mut seed) % END as u64) as i64;
        let query = CString::new(format!(r#"{{"q":"layers_at","tl_ns":{t}}}"#)).unwrap();
        let mut output = std::ptr::null_mut();
        let start = Instant::now();
        assert_eq!(unsafe { yc_query(handle, query.as_ptr(), &mut output) }, 0);
        std::hint::black_box(unsafe { std::ffi::CStr::from_ptr(output) });
        unsafe {
            yc_string_free(output);
        }
        overlay.push(start.elapsed().as_nanos() as u64);
    }
    let overlay_stats = percentiles(overlay);
    println!("SCALE key_overlay enabled=true captured_keys=36000 shortcuts=18000 yc_query_layers_at n=1024 p50_ms={:.6} p99_ms={:.6} max_ms={:.6}",overlay_stats.0,overlay_stats.1,overlay_stats.2);
    let mut worst_edit: f64 = 0.0;
    for durable in [false, true] {
        unsafe {
            (*handle).inner.write().unwrap().data.autosave = durable;
        }
        let mut applies = Vec::new();
        let mut undos = Vec::new();
        for i in 0..64 {
            let command = CString::new(format!(
                r#"{{"op":"set","path":"canvas.padding","value":{}}}"#,
                60 + i
            ))
            .unwrap();
            let start = Instant::now();
            assert_eq!(
                unsafe { yc_apply(handle, command.as_ptr(), std::ptr::null_mut()) },
                0
            );
            applies.push(start.elapsed().as_nanos() as u64);
            let mut did = 0;
            let start = Instant::now();
            assert_eq!(unsafe { yc_undo(handle, &mut did) }, 0);
            assert_eq!(did, 1);
            undos.push(start.elapsed().as_nanos() as u64);
        }
        for (op, times) in [("yc_apply", applies), ("yc_undo", undos)] {
            let stats = percentiles(times);
            worst_edit = worst_edit.max(stats.2);
            println!(
                "SCALE {op} durable={durable} n=64 p50_ms={:.6} p99_ms={:.6} max_ms={:.6}",
                stats.0, stats.1, stats.2
            );
        }
    }
    for (op, command) in [
        (
            "set_speed",
            r#"{"op":"set_speed","clip_id":"scale-2500","speed":1.5}"#,
        ),
        ("split", r#"{"op":"split","at_tl_ns":1800100000000}"#),
        (
            "insert_source",
            r#"{"op":"insert_source","src_start_ns":1800000000000,"src_end_ns":1800100000000,"at_tl_ns":1800000000000}"#,
        ),
        (
            "delete_30min",
            r#"{"op":"delete_range","tl_start_ns":900000000000,"tl_end_ns":2700000000000}"#,
        ),
    ] {
        let command = CString::new(command).unwrap();
        let mut samples = Vec::new();
        for _ in 0..8 {
            let start = Instant::now();
            assert_eq!(
                unsafe { yc_apply(handle, command.as_ptr(), std::ptr::null_mut()) },
                0
            );
            samples.push(start.elapsed().as_nanos() as u64);
            let mut did = 0;
            assert_eq!(unsafe { yc_undo(handle, &mut did) }, 0);
            assert_eq!(did, 1);
        }
        let stats = percentiles(samples);
        worst_edit = worst_edit.max(stats.2);
        println!(
            "SCALE {op} durable=true n=8 p50_ms={:.6} p99_ms={:.6} max_ms={:.6}",
            stats.0, stats.1, stats.2
        );
    }
    unsafe {
        for z in &mut (*handle).inner.write().unwrap().data.zooms {
            z.mode = "auto".into();
        }
    }
    let mut automatic = Vec::new();
    let command = CString::new(r#"{"op":"auto_zooms"}"#).unwrap();
    for _ in 0..8 {
        let start = Instant::now();
        assert_eq!(
            unsafe { yc_apply(handle, command.as_ptr(), std::ptr::null_mut()) },
            0
        );
        automatic.push(start.elapsed().as_nanos() as u64);
        let mut did = 0;
        assert_eq!(unsafe { yc_undo(handle, &mut did) }, 0);
        assert_eq!(did, 1);
    }
    let stats = percentiles(automatic);
    worst_edit = worst_edit.max(stats.2);
    println!(
        "SCALE auto_zooms durable=true n=8 p50_ms={:.6} p99_ms={:.6} max_ms={:.6}",
        stats.0, stats.1, stats.2
    );
    let query = CString::new(r#"{"q":"typing_suggestions"}"#).unwrap();
    let start = Instant::now();
    let mut rows = std::ptr::null_mut();
    assert_eq!(unsafe { yc_query(handle, query.as_ptr(), &mut rows) }, 0);
    assert!(!rows.is_null());
    unsafe {
        yc_string_free(rows);
    }
    println!(
        "SCALE typing_suggestions query_ms={:.6}",
        start.elapsed().as_secs_f64() * 1000.0
    );
    let command = CString::new(r#"{"op":"auto_speed_typing","speed":3}"#).unwrap();
    let mut typing = Vec::new();
    let mut typing_undo = Vec::new();
    for _ in 0..8 {
        let start = Instant::now();
        assert_eq!(
            unsafe { yc_apply(handle, command.as_ptr(), std::ptr::null_mut()) },
            0
        );
        typing.push(start.elapsed().as_nanos() as u64);
        let start = Instant::now();
        let mut did = 0;
        assert_eq!(unsafe { yc_undo(handle, &mut did) }, 0);
        assert_eq!(did, 1);
        typing_undo.push(start.elapsed().as_nanos() as u64);
    }
    let stats = percentiles(typing);
    worst_edit = worst_edit.max(stats.2);
    println!(
        "SCALE auto_speed_typing durable=true n=8 p50_ms={:.6} p99_ms={:.6} max_ms={:.6}",
        stats.0, stats.1, stats.2
    );
    let stats = percentiles(typing_undo);
    worst_edit = worst_edit.max(stats.2);
    println!(
        "SCALE typing_undo durable=true n=8 p50_ms={:.6} p99_ms={:.6} max_ms={:.6}",
        stats.0, stats.1, stats.2
    );
    let start = Instant::now();
    assert_eq!(unsafe { yc_project_save(handle, path.as_ptr()) }, 0);
    println!(
        "SCALE yc_project_save ms={:.6} project_json_bytes={}",
        start.elapsed().as_secs_f64() * 1000.0,
        std::fs::metadata(fixture.0.join("project.json"))
            .unwrap()
            .len()
    );
    drop(owned);
    assert!(
        frame_stats.1 <= 1.0,
        "frame p99 over 1ms: {}",
        frame_stats.1
    );
    assert!(worst_edit <= 50.0, "edit over 50ms: {worst_edit}");
    assert!(
        overlay_stats.1 <= 1.0,
        "key overlay query p99 over 1ms: {}",
        overlay_stats.1
    );
}

fn assert_original_leaves(original: &serde_json::Value, migrated: &serde_json::Value, path: &str) {
    use serde_json::Value;
    match original {
        Value::Object(map) => {
            for (key, value) in map {
                if key != "schema_version" {
                    assert_original_leaves(value, &migrated[key], &format!("{path}.{key}"));
                }
            }
        }
        Value::Array(array) => {
            assert_eq!(array.len(), migrated.as_array().unwrap().len(), "{path}");
            for (i, value) in array.iter().enumerate() {
                assert_original_leaves(value, &migrated[i], &format!("{path}[{i}]"));
            }
        }
        Value::Number(a) if original != migrated => {
            let b = migrated.as_number().expect("Number changed type");
            // JSON integer literals in floating settings serialize as e.g. -6.0.
            // Never use Double equivalence for large integer clocks/fingerprints.
            assert!(
                a.as_i64()
                    .is_none_or(|n| n.unsigned_abs() <= 9_007_199_254_740_992),
                "Large integer lost at {path}"
            );
            assert!(
                a.as_u64().is_none_or(|n| n <= 9_007_199_254_740_992),
                "Large integer lost at {path}"
            );
            assert_eq!(a.as_f64(), b.as_f64(), "Frozen numeric leaf {path}");
        }
        _ => assert_eq!(original, migrated, "Frozen schema leaf {path}"),
    }
}
#[test]
fn frozen_schema_corpus_migrates_without_losing_original_fields() {
    use serde_json::Value;
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../Tests/Fixtures/schema");
    let manifest: BTreeMap<String, String> =
        serde_json::from_slice(&std::fs::read(root.join("frozen-head-hashes.json")).unwrap())
            .unwrap();
    for (name, hash) in manifest {
        let bytes = std::fs::read(root.join(&name)).unwrap();
        let actual = bytes.iter().fold(0xcbf29ce484222325u64, |h, b| {
            (h ^ u64::from(*b)).wrapping_mul(0x100000001b3)
        });
        assert_eq!(
            format!("{actual:016x}"),
            hash,
            "Frozen bytes changed: {name}"
        );
        let original: Value = serde_json::from_slice(&bytes).unwrap();
        let data = crate::project::decode_project(&bytes).unwrap();
        assert_eq!(data.schema_version, SCHEMA_VERSION);
        let canonical = serde_json::to_vec(&data).unwrap();
        assert_original_leaves(
            &original,
            &serde_json::from_slice(&canonical).unwrap(),
            &name,
        );
        assert_eq!(crate::project::decode_project(&canonical).unwrap(), data);
        assert!(!data.audio.speech_enhancement);
        assert_eq!(data.audio.speech_enhancement_settings.high_pass_hz, 90.0);
        assert!(
            !data.cursor.always_default
                && !data.cursor.remove_shakes
                && !data.cursor.optimize_types
        );
        assert_eq!(data.camera.zoom_scale, 1.0);
        let mut future = original.clone();
        future["schema_version"] = (SCHEMA_VERSION + 1).into();
        assert_eq!(
            crate::project::decode_project(&serde_json::to_vec(&future).unwrap())
                .unwrap_err()
                .status,
            3
        );
    }
}

fn ffi_json(handle: *mut YcProject) -> serde_json::Value {
    let mut text = std::ptr::null_mut();
    assert_eq!(unsafe { yc_project_to_json(handle, &mut text) }, 0);
    let result =
        unsafe { serde_json::from_slice(std::ffi::CStr::from_ptr(text).to_bytes()).unwrap() };
    unsafe {
        yc_string_free(text);
    }
    result
}
fn arbitrary_json(seed: &mut u64, depth: u8) -> serde_json::Value {
    use serde_json::{json, Value};
    let n = rng(seed);
    match n % if depth == 0 { 6 } else { 8 } {
        0 => Value::Null,
        1 => json!(n.is_multiple_of(2)),
        2 => json!([i64::MIN, -1, 0, 1, i64::MAX][n as usize % 5]),
        3 => json!([0.05, 1.000000001, 32.0, -1.0, 1e300][n as usize % 5]),
        4 => json!(
            [
                "",
                "notes",
                "canvas.padding",
                "../escape",
                "☕\0字幕",
                "op",
                "tl_start_ns"
            ][n as usize % 7]
        ),
        5 => json!({}),
        6 => Value::Array(
            (0..n % 4)
                .map(|_| arbitrary_json(seed, depth - 1))
                .collect(),
        ),
        _ => Value::Object(
            (0..n % 4)
                .map(|i| (format!("field{i}"), arbitrary_json(seed, depth - 1)))
                .collect(),
        ),
    }
}
#[test]
fn random_json_ffi_commands_never_panic_or_corrupt_state() {
    use serde_json::{json, Value};
    struct Owned(*mut YcProject);
    impl Drop for Owned {
        fn drop(&mut self) {
            unsafe {
                yc_project_free(self.0);
            }
        }
    }
    let mut accepted = 0;
    let mut rejected = 0;
    let mut persisted = 0;
    for initial_seed in [0x5eed_u64, 0xdead_beef, 0x8000_0000_0000_0001, 0xf137_2acd] {
        let fixture = Fixture::new();
        let path = CString::new(fixture.0.to_str().unwrap()).unwrap();
        let mut handle = std::ptr::null_mut();
        assert_eq!(unsafe { yc_project_create(path.as_ptr(), &mut handle) }, 0);
        let _owned = Owned(handle);
        let off = CString::new(r#"{"op":"set","path":"autosave","value":false}"#).unwrap();
        assert_eq!(
            unsafe { yc_apply(handle, off.as_ptr(), std::ptr::null_mut()) },
            0
        );
        let mut seed = initial_seed;
        for step in 0..2500 {
            let before = ffi_json(handle);
            let undo = unsafe { yc_can_undo(handle) };
            let redo = unsafe { yc_can_redo(handle) };
            let n = rng(&mut seed);
            let duration = crate::time::duration(
                &unsafe { (*handle).inner.read().unwrap() }
                    .data
                    .timeline
                    .clips,
            );
            let clip_id = before["timeline"]["clips"][0]["id"]
                .as_str()
                .unwrap_or("missing");
            let random = arbitrary_json(&mut seed, 4);
            let mut command = match n % 31 {
                0 => random.clone(),
                1 => json!({"op":"set","path":"canvas.padding","value":random}),
                2 => json!({"op":"set","path":"notes","value":format!("fuzz-{n} ☕\0字幕")}),
                3 => {
                    json!({"op":"split","at_tl_ns":if n&16==0 {json!((n%duration.max(1) as u64) as i64)} else {random.clone()}})
                }
                4 => {
                    json!({"op":"delete_range","tl_start_ns":0,"tl_end_ns":(n%duration.max(1) as u64) as i64})
                }
                5 => {
                    json!({"op":"set_speed","clip_id":clip_id,"speed":([0.05,1.000000001,32.0,-1.0,1e300][n as usize%5])})
                }
                6 => {
                    json!({"op":"batch","commands":[{"op":"set","path":"notes","value":"must rollback"},{"op":"set","path":"canvas.crop","value":random}]})
                }
                7 => json!({"op":"add_zoom","zoom":random}),
                8 => json!({"op":"update_zoom","id":"unknown","patch":random}),
                9 => {
                    json!({"op":"set","path":(["camera.position","cursor.stop_before_end_ns","audio.speech_enhancement_settings","canvas.animation","cursor.spring","audio.music","canvas.captions"][n as usize%7]),"value":random})
                }
                10 => json!({"op":"add_media","role":"asset","path":"../../escape"}),
                11 => json!({"op":"add_caption","caption":random}),
                12 => json!({"op":"auto_speed_typing","speed":random}),
                13 => json!({"op":"apply_typing_suggestion","id":random,"speed":3}),
                14 => json!({"op":"dismiss_typing_suggestion","id":random}),
                15 => json!({"op":"restore_typing_suggestions"}),
                16 => {
                    json!({"op":"set","path":(["audio.mic_preset","audio.stereo_mic","canvas.padding_ratio","cursor.size_points","zoom_settings.start_early","typing.speed","typing.dismissed"][n as usize%7]),"value":random})
                }
                17 => json!({"op":"timeline_edit","command":{"op":"split","at_tl_ns":random}}),
                18 => {
                    json!({"op":"coalesced_edit","key":format!("fuzz-{}",n%3),"command":{"op":"set","path":"notes","value":format!("group-{n}")}})
                }
                19 => {
                    json!({"op":"insert_zoom","tl_start_ns":random,"duration_ns":arbitrary_json(&mut seed,2)})
                }
                20 => json!({"op":"insert_mask","patch":random}),
                21 => json!({"op":"insert_layout","tl_start_ns":random}),
                22 => json!({"op":"set_clip_settings","clip_id":clip_id,"patch":random}),
                23 => json!({"op":"set","path":"canvas.device_frame","value":random}),
                24 => {
                    json!({"op":"apply_preset","preset":{"timeline":random,"zooms":[{"id":"foreign"}],"canvas":{"shadow":arbitrary_json(&mut seed,2),"highlights":random},"cursor":{"key_overlay":arbitrary_json(&mut seed,2)}}})
                }
                25 => {
                    json!({"op":"insert_source","src_start_ns":0,"src_end_ns":(n%5_000_000_000) as i64,"at_tl_ns":0,"speed":random})
                }
                26 => json!({"op":"set","path":"camera.style","value":random}),
                27 => json!({"op":"set","path":"camera.layout_settings","value":random}),
                29 => {
                    json!({"op":"select_mic","original":random,"path":arbitrary_json(&mut seed,2)})
                }
                30 => json!({"op":"set","path":"audio.mic_replacements","value":random}),
                _ => {
                    json!({"op":"update_zoom","id":before["zooms"][0]["id"].as_str().unwrap_or("missing"),"patch":{"style":"lens","lens":random}})
                }
            };
            if step % 97 == 0 {
                for _ in 0..40 {
                    command = json!({"op":"batch","commands":[command]});
                }
            }
            let raw = if step % 131 == 0 {
                vec![0xff, 0xfe]
            } else if step % 113 == 0 {
                br#"{"op": "set", "value": 1e999}"#.to_vec()
            } else if step % 109 == 0 {
                b"{unclosed".to_vec()
            } else {
                serde_json::to_vec(&command).unwrap()
            };
            let raw = CString::new(raw).unwrap();
            let mut text = std::ptr::null_mut();
            let status = unsafe { yc_apply(handle, raw.as_ptr(), &mut text) };
            assert_ne!(
                status, 99,
                "FFI panic seed={initial_seed:x} step={step} command={command}"
            );
            if status != 0 {
                rejected += 1;
                assert!(text.is_null());
                assert_eq!(
                    ffi_json(handle),
                    before,
                    "Failed edit mutated state seed={initial_seed:x} step={step}"
                );
                assert_eq!(unsafe { yc_can_undo(handle) }, undo);
                assert_eq!(unsafe { yc_can_redo(handle) }, redo);
                assert!(!unsafe { std::ffi::CStr::from_ptr(yc_last_error()) }
                    .to_bytes()
                    .is_empty());
            } else {
                accepted += 1;
                assert!(!text.is_null());
                let _: Value = unsafe {
                    serde_json::from_slice(std::ffi::CStr::from_ptr(text).to_bytes()).unwrap()
                };
                unsafe {
                    yc_string_free(text);
                }
                let state = unsafe { (*handle).inner.read().unwrap() };
                crate::project::validate_data(&state.data).unwrap();
                assert!(state
                    .data
                    .timeline
                    .clips
                    .iter()
                    .all(|c| c.src_end_ns <= 5_000_000_000));
            }
            if step % 11 == 0 {
                let query = if step % 33 == 0 {
                    json!({"q":(["typing_suggestions","capabilities","history","insertion_styles","autosave_policy","timeline_constraints","markers","camera_style","camera_style_library","microphone_media"][(step as usize/33)%10])})
                } else if step % 22 == 0 {
                    json!({"q":(["effects_at","zoom_lens_at","camera_layout_at"][(n%3) as usize]),"tl_ns":arbitrary_json(&mut seed,2)})
                } else {
                    arbitrary_json(&mut seed, 3)
                };
                let query = CString::new(query.to_string()).unwrap();
                let mut result = std::ptr::null_mut();
                let status = unsafe { yc_query(handle, query.as_ptr(), &mut result) };
                assert_ne!(status, 99, "Query panic: {query:?}");
                if !result.is_null() {
                    let _: Value = unsafe {
                        serde_json::from_slice(std::ffi::CStr::from_ptr(result).to_bytes()).unwrap()
                    };
                    unsafe {
                        yc_string_free(result);
                    }
                }
            }
            if step % 7 == 0 {
                let mut did = 0;
                assert_eq!(unsafe { yc_undo(handle, &mut did) }, 0);
            }
            if step % 13 == 0 {
                let mut did = 0;
                assert_eq!(unsafe { yc_redo(handle, &mut did) }, 0);
            }
            if step % 101 == 0 {
                let canonical = ffi_json(handle);
                let mut copy = std::ptr::null_mut();
                assert_eq!(unsafe { yc_project_clone(handle, &mut copy) }, 0);
                let _copy = Owned(copy);
                assert_eq!(ffi_json(copy), canonical);
                assert_eq!(unsafe { yc_project_save(handle, path.as_ptr()) }, 0);
                persisted += 1;
                let mut reopened = std::ptr::null_mut();
                assert_eq!(unsafe { yc_project_open(path.as_ptr(), &mut reopened) }, 0);
                let _reopened = Owned(reopened);
                assert_eq!(ffi_json(reopened), canonical);
                let edit = CString::new(r#"{"op":"set","path":"notes","value":"after snapshot"}"#)
                    .unwrap();
                assert_eq!(
                    unsafe { yc_apply(handle, edit.as_ptr(), std::ptr::null_mut()) },
                    0
                );
                assert_eq!(ffi_json(copy), canonical);
            }
            let state = unsafe { (*handle).inner.read().unwrap() };
            let duration = crate::time::duration(&state.data.timeline.clips);
            let nonempty = !state.data.timeline.clips.is_empty();
            drop(state);
            let t = if step % 17 == 0 {
                -1
            } else if step % 19 == 0 {
                i64::MAX
            } else {
                duration / 2
            };
            let expected = if t < 0 || t > duration || !nonempty {
                1
            } else {
                0
            };
            let mut frame = crate::frame::Frame::default();
            let mut extras = crate::layers::FrameExtras::default();
            let mut motion = crate::motion::FrameMotion::default();
            assert_eq!(
                unsafe { yc_frame_at(handle, t, &mut frame) },
                expected,
                "Frame seed={initial_seed:x} step={step}"
            );
            assert_eq!(
                unsafe { yc_frame_extras_at(handle, t, &mut extras) },
                expected
            );
            assert_eq!(
                unsafe { yc_frame_motion_at(handle, t, &mut motion) },
                expected
            );
            if expected == 0 {
                assert!(
                    frame.screen_crop.x.is_finite()
                        && frame.screen_crop.w > 0.0
                        && frame.cursor_x.is_finite()
                        && motion.cursor_rotation_rad.is_finite()
                );
            }
        }
    }
    assert!(accepted > 500 && rejected > 5000 && persisted == 100);
    println!("FFI_FUZZ seeds=4 commands=10000 accepted={accepted} rejected={rejected} persistence_roundtrips={persisted} panics=0");
}
