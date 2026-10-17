//! Caption metadata/timing is evaluated once on the cold path; glyph shaping
//! belongs to Render. Existing full-line sans captions retain their appearance.
use crate::{
    model::{CaptionWord, TextRecord, TextStyle},
    project::Result,
};
use serde::Serialize;
use serde_json::{json, Map, Value};

pub(crate) fn valid_language(value: &str) -> bool {
    if value == "auto" {
        return true;
    }
    if value.len() > 63 {
        return false;
    }
    let mut parts = value.split(['-', '_']);
    let first = parts.next().unwrap_or("");
    (2..=8).contains(&first.len())
        && first.bytes().all(|c| c.is_ascii_alphabetic())
        && parts.all(|part| {
            (1..=8).contains(&part.len()) && part.bytes().all(|c| c.is_ascii_alphanumeric())
        })
}
pub(crate) fn valid_style(style: &TextStyle) -> bool {
    matches!(style.font_family.as_str(), "sans" | "serif" | "mono")
        && matches!(style.reveal.as_str(), "line" | "word")
        && matches!(style.growth.as_str(), "full" | "expanding" | "centered")
        && matches!(style.entrance.as_str(), "appear" | "fade" | "slide")
        && valid_language(&style.language)
        && style
            .font_size_ratio
            .is_none_or(|v| (0.005..=0.25).contains(&v))
}
pub(crate) fn factory_style(revision: u32) -> TextStyle {
    let mut style = TextStyle::default();
    if revision >= 2 {
        style.font_size = 54.0;
        style.font_size_ratio = Some(0.05);
        style.growth = "expanding".into();
        style.background = [0.0, 0.0, 0.0, 1.0];
    }
    style
}
fn normalized(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}
pub(crate) fn valid_words(record: &TextRecord) -> bool {
    let mut previous = record.tl_start_ns;
    for word in &record.words {
        if word.text.trim().is_empty()
            || word.tl_start_ns < previous
            || word.tl_end_ns <= word.tl_start_ns
            || word.tl_end_ns > record.tl_end_ns
        {
            return false;
        }
        previous = word.tl_end_ns;
    }
    record.words.is_empty()
        || normalized(&record.text)
            == normalized(
                &record
                    .words
                    .iter()
                    .map(|w| w.text.as_str())
                    .collect::<Vec<_>>()
                    .join(" "),
            )
}
pub(crate) fn options() -> Value {
    json!({"font_families":["sans","serif","mono"],"reveal_modes":["line","word"],
        "growth_modes":["full","expanding","centered"],"entrances":["appear","fade","slide"],
        "language":{"automatic":"auto","supports_locale_tags":true,"supported_locales_require_capture":true}})
}

/// All mapping closures use the same exact timeline boundaries as media. If
/// timed content is removed, keep text and timing consistent rather than falling
/// back to re-revealing words that were explicitly cut.
pub(crate) fn remap_words(
    record: &mut TextRecord,
    start: impl Fn(i64) -> i64,
    end: impl Fn(i64) -> i64,
) {
    if record.words.is_empty() {
        return;
    }
    let count = record.words.len();
    for word in &mut record.words {
        word.tl_start_ns = start(word.tl_start_ns).max(record.tl_start_ns);
        word.tl_end_ns = end(word.tl_end_ns).min(record.tl_end_ns);
    }
    record
        .words
        .retain(|word| word.tl_end_ns > word.tl_start_ns);
    if record.words.len() != count {
        record.text = record
            .words
            .iter()
            .map(|w| w.text.as_str())
            .collect::<Vec<_>>()
            .join(" ");
        if record.words.is_empty() {
            record.tl_end_ns = record.tl_start_ns;
        }
    }
}

/// Preserve existing editor retiming/text-correction commands: explicit words
/// win; changed text invalidates prior alignment; otherwise scale old clocks.
pub(crate) fn did_patch(
    row: &mut Value,
    previous: &Value,
    patch: &Map<String, Value>,
) -> Result<()> {
    if let Some(style) = patch.get("style").and_then(Value::as_object) {
        if style.contains_key("font_size") && !style.contains_key("font_size_ratio") {
            row["style"]["font_size_ratio"] = Value::Null;
        }
    }
    if patch.contains_key("words") {
        return Ok(());
    }
    if patch.contains_key("text") && row["text"] != previous["text"] {
        row["words"] = json!([]);
    } else if patch.contains_key("tl_start_ns") || patch.contains_key("tl_end_ns") {
        let old: TextRecord = serde_json::from_value(previous.clone())?;
        let mut updated: TextRecord = serde_json::from_value(row.clone())?;
        if old.tl_end_ns > old.tl_start_ns
            && updated.tl_start_ns >= 0
            && updated.tl_end_ns > updated.tl_start_ns
        {
            let old_span = i128::from(old.tl_end_ns) - i128::from(old.tl_start_ns);
            let new_span = i128::from(updated.tl_end_ns) - i128::from(updated.tl_start_ns);
            let at = updated.tl_start_ns;
            let map = |time: i64| {
                let offset = (i128::from(time) - i128::from(old.tl_start_ns)).clamp(0, old_span);
                at + ((offset * new_span + old_span / 2) / old_span) as i64
            };
            remap_words(&mut updated, map, map);
            *row = serde_json::to_value(updated)?;
        }
    }
    Ok(())
}

#[derive(Serialize)]
pub(crate) struct WordEvaluation {
    text: String,
    tl_start_ns: i64,
    tl_end_ns: i64,
    visible: bool,
    progress: f64,
    opacity: f64,
    offset_y: f64,
}
#[derive(Serialize)]
pub(crate) struct Evaluation {
    pub full_text: String,
    pub visible_text: String,
    font_family: String,
    reveal: String,
    growth: String,
    entrance: String,
    language: String,
    pub line_opacity: f64,
    pub line_offset_y: f64,
    words: Vec<WordEvaluation>,
}
fn progress(start: i64, end: i64, time: i64) -> f64 {
    let duration = end.saturating_sub(start).clamp(1, 200_000_000);
    (time.saturating_sub(start).max(0) as f64 / duration as f64).clamp(0.0, 1.0)
}
pub(crate) fn evaluate(record: &TextRecord, time: i64) -> Option<Evaluation> {
    if time < record.tl_start_ns || time >= record.tl_end_ns {
        return None;
    }
    let derived;
    let words = if record.words.is_empty() {
        let pieces: Vec<_> = record.text.split_whitespace().collect();
        let span = i128::from(record.tl_end_ns) - i128::from(record.tl_start_ns);
        derived = pieces
            .iter()
            .enumerate()
            .map(|(index, text)| {
                let start =
                    record.tl_start_ns + (index as i128 * span / pieces.len() as i128) as i64;
                let end =
                    record.tl_start_ns + ((index + 1) as i128 * span / pieces.len() as i128) as i64;
                CaptionWord {
                    text: (*text).into(),
                    tl_start_ns: start,
                    tl_end_ns: end.max(start + 1),
                }
            })
            .collect::<Vec<_>>();
        &derived
    } else {
        &record.words
    };
    let line = record.style.reveal == "line";
    let words: Vec<_> = words
        .iter()
        .map(|word| {
            let visible = line || time >= word.tl_start_ns;
            let phase = progress(
                if line {
                    record.tl_start_ns
                } else {
                    word.tl_start_ns
                },
                if line {
                    record.tl_end_ns
                } else {
                    word.tl_end_ns
                },
                time,
            );
            WordEvaluation {
                text: word.text.clone(),
                tl_start_ns: word.tl_start_ns,
                tl_end_ns: word.tl_end_ns,
                visible,
                progress: if visible { phase } else { 0.0 },
                opacity: if !visible {
                    0.0
                } else if record.style.entrance == "fade" {
                    phase
                } else {
                    1.0
                },
                offset_y: if visible && record.style.entrance == "slide" {
                    0.25 * (1.0 - phase)
                } else {
                    0.0
                },
            }
        })
        .collect();
    let visible_text = if line {
        record.text.clone()
    } else {
        words
            .iter()
            .filter(|w| w.visible)
            .map(|w| w.text.as_str())
            .collect::<Vec<_>>()
            .join(" ")
    };
    let phase = progress(record.tl_start_ns, record.tl_end_ns, time);
    Some(Evaluation {
        full_text: record.text.clone(),
        visible_text,
        font_family: record.style.font_family.clone(),
        reveal: record.style.reveal.clone(),
        growth: record.style.growth.clone(),
        entrance: record.style.entrance.clone(),
        language: record.style.language.clone(),
        line_opacity: if line && record.style.entrance == "fade" {
            phase
        } else {
            1.0
        },
        line_offset_y: if line && record.style.entrance == "slide" {
            0.25 * (1.0 - phase)
        } else {
            0.0
        },
        words,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::{tests::Fixture, Project};
    fn add(p: &mut Project, style: Value) -> String {
        p.apply(&json!({"op":"add_caption","record":{"text":"one two three","tl_start_ns":0,"tl_end_ns":3_000_000_000_i64,"style":style,
            "words":[{"text":"one","tl_start_ns":0,"tl_end_ns":1_000_000_000},{"text":"two","tl_start_ns":1_000_000_000,"tl_end_ns":2_000_000_000_i64},{"text":"three","tl_start_ns":2_000_000_000_i64,"tl_end_ns":3_000_000_000_i64}]}})).unwrap().created_ids[0].clone()
    }
    fn layer(p: &Project, id: &str, time: i64) -> Option<Value> {
        p.query(&json!({"q":"layers_at","tl_ns":time}))
            .unwrap()
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["id"] == format!("core:caption:{id}"))
            .cloned()
    }
    #[test]
    fn caption_options_styles_defaults_and_legacy_roundtrip_are_explicit() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        let id = add(&mut p, json!({}));
        let row = layer(&p, &id, 1_000_000_000).unwrap();
        assert_eq!(row["text"], "one two three");
        assert_eq!(row["font_family"], "sans");
        assert_eq!(row["caption"]["growth"], "full");
        let original = p.data.canvas.captions[0].clone();
        let snapshot = p.clone();
        p.apply(&json!({"op":"update_caption","id":id,"patch":{"style":{"font_family":"serif","reveal":"word","growth":"centered","entrance":"fade","language":"zh-Hans-CN"}}})).unwrap();
        let selected = p.data.canvas.captions[0].clone();
        p.undo().unwrap();
        assert_eq!(p.data.canvas.captions[0], original);
        p.redo().unwrap();
        assert_eq!(p.data.canvas.captions[0], selected);
        assert_eq!(snapshot.data.canvas.captions[0], original);
        p.save(&f.0).unwrap();
        assert_eq!(
            Project::open(&f.0).unwrap().data.canvas.captions[0],
            selected
        );
        assert_eq!(
            p.query(&json!({"q":"caption_options"})).unwrap()["font_families"],
            json!(["sans", "serif", "mono"])
        );
        let mut old = serde_json::to_value(&p.data).unwrap();
        for field in ["font_family", "reveal", "growth", "entrance", "language"] {
            old["canvas"]["captions"][0]["style"]
                .as_object_mut()
                .unwrap()
                .remove(field);
        }
        old["canvas"]["captions"][0]
            .as_object_mut()
            .unwrap()
            .remove("words");
        let legacy = crate::project::decode_project(&serde_json::to_vec(&old).unwrap()).unwrap();
        assert_eq!(legacy.canvas.captions[0].style, TextStyle::default());
        assert!(legacy.canvas.captions[0].words.is_empty());
        assert!(p.query(&json!({"q":"preset"})).unwrap()["canvas"]
            .get("captions")
            .is_none());
        for language in ["auto", "en", "de_DE", "zh-Hans-CN", "sr-Latn-RS", "es-419"] {
            assert!(valid_language(language));
        }
        for language in [
            "",
            "e",
            "en/US",
            "en--US",
            "en-",
            "☕",
            "en-US\0",
            &"en-a".repeat(30),
        ] {
            assert!(!valid_language(language));
        }
        for (key, value) in [
            ("font_family", json!("script")),
            ("reveal", json!("char")),
            ("growth", json!("unknown")),
            ("entrance", json!("bounce")),
            ("language", json!("../escape")),
        ] {
            let mut style = serde_json::to_value(TextStyle::default()).unwrap();
            style[key] = value;
            let before = p.data.clone();
            let steps = p.undo.len();
            assert!(p.apply(&json!({"op":"batch","commands":[{"op":"set","path":"notes","value":"rollback"},{"op":"update_caption","id":id,"patch":{"style":style}}]})).is_err());
            assert_eq!(p.data, before);
            assert_eq!(p.undo.len(), steps);
        }
        assert_eq!(
            crate::allocation_test::count(|| {
                p.frame(500_000_000).unwrap();
                p.frame_extras(500_000_000).unwrap();
            }),
            0
        );
    }
    #[test]
    fn caption_reveal_preserves_exact_word_gaps_and_shared_animation_phases() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        let id=p.apply(&json!({"op":"add_caption","record":{"text":"hello 世界 👩‍💻","tl_start_ns":0,"tl_end_ns":2_000_000_000_i64,"style":{"reveal":"word","entrance":"fade","growth":"expanding","font_family":"mono"},"words":[{"text":"hello","tl_start_ns":200_000_000,"tl_end_ns":600_000_000},{"text":"世界","tl_start_ns":1_200_000_000,"tl_end_ns":1_600_000_000},{"text":"👩‍💻","tl_start_ns":1_600_000_000,"tl_end_ns":1_900_000_000}]}})).unwrap().created_ids[0].clone();
        assert!(layer(&p, &id, 199_999_999).is_none());
        let first = layer(&p, &id, 200_000_000).unwrap();
        assert_eq!(first["text"], "hello");
        assert_eq!(first["caption"]["words"][0]["opacity"], 0.0);
        assert_eq!(layer(&p, &id, 1_000_000_000).unwrap()["text"], "hello");
        let second = layer(&p, &id, 1_300_000_000).unwrap();
        assert_eq!(second["text"], "hello 世界");
        assert_eq!(second["caption"]["words"][1]["opacity"], 0.5);
        assert_eq!(second["caption"]["words"][0]["opacity"], 1.0);
        assert_eq!(
            layer(&p, &id, 1_800_000_000).unwrap()["text"],
            "hello 世界 👩‍💻"
        );
        assert!(layer(&p, &id, 2_000_000_000).is_none());
        p.apply(&json!({"op":"update_caption","id":id,"patch":{"style":{"reveal":"line","entrance":"slide"}}})).unwrap();
        let sliding = layer(&p, &id, 100_000_000).unwrap();
        assert_eq!(sliding["caption"]["line_offset_y"], 0.125);
        assert_eq!(sliding["text"], "hello 世界 👩‍💻");
        p.apply(&json!({"op":"update_caption","id":id,"patch":{"style":{"entrance":"fade"}}}))
            .unwrap();
        assert_eq!(layer(&p, &id, 100_000_000).unwrap()["opacity"], 0.5);
        let base = (1_i64 << 53) + 123;
        let mut record = p.data.canvas.captions[0].clone();
        record.tl_start_ns = base;
        record.tl_end_ns = base + 1_000;
        record.style.reveal = "word".into();
        record.style.entrance = "appear".into();
        record.text = "one two".into();
        record.words = vec![
            CaptionWord {
                text: "one".into(),
                tl_start_ns: base,
                tl_end_ns: base + 200,
            },
            CaptionWord {
                text: "two".into(),
                tl_start_ns: base + 701,
                tl_end_ns: base + 999,
            },
        ];
        assert_eq!(evaluate(&record, base + 700).unwrap().visible_text, "one");
        assert_eq!(
            evaluate(&record, base + 701).unwrap().visible_text,
            "one two"
        );
    }
    #[test]
    fn caption_word_timing_follows_speed_cut_insert_patch_history_and_invalid_batches() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        let id = add(&mut p, json!({"reveal":"word"}));
        p.apply(&json!({"op":"split","at_tl_ns":1_000_000_000}))
            .unwrap();
        let clip = p.data.timeline.clips[1].id.clone();
        p.apply(&json!({"op":"set_speed","clip_id":clip,"speed":2}))
            .unwrap();
        assert_eq!(
            p.data.canvas.captions[0].words[2].tl_start_ns,
            1_500_000_000
        );
        p.apply(
            &json!({"op":"delete_range","tl_start_ns":1_000_000_000,"tl_end_ns":1_500_000_000}),
        )
        .unwrap();
        assert_eq!(p.data.canvas.captions[0].text, "one three");
        assert_eq!(p.data.canvas.captions[0].words.len(), 2);
        p.undo().unwrap();
        assert_eq!(p.data.canvas.captions[0].words.len(), 3);
        p.apply(&json!({"op":"insert_source","src_start_ns":4_000_000_000_i64,"src_end_ns":4_500_000_000_i64,"at_tl_ns":1_000_000_000})).unwrap();
        let words = &p.data.canvas.captions[0].words;
        assert_eq!(words[0].tl_end_ns, 1_000_000_000);
        assert_eq!(words[1].tl_start_ns, 1_500_000_000);
        assert_eq!(words[2].tl_start_ns, 2_000_000_000);
        p.apply(&json!({"op":"update_caption","id":id,"patch":{"tl_start_ns":500_000_000,"tl_end_ns":3_000_000_000_i64}})).unwrap();
        assert_eq!(
            p.data.canvas.captions[0].words[1].tl_start_ns,
            2_000_000_000
        );
        let before = p.data.clone();
        for bad in [
            json!([["bad", 0, 1]]),
            json!([{"text":"bad","tl_start_ns":0,"tl_end_ns":1}]),
            json!([{"text":"one two three","tl_start_ns":2,"tl_end_ns":1}]),
        ] {
            assert!(p
                .apply(&json!({"op":"update_caption","id":id,"patch":{"words":bad}}))
                .is_err());
            assert_eq!(p.data, before);
        }
        p.apply(&json!({"op":"update_caption","id":id,"patch":{"text":"corrected words"}}))
            .unwrap();
        assert!(p.data.canvas.captions[0].words.is_empty());
        assert_eq!(layer(&p, &id, 500_000_000).unwrap()["text"], "corrected");
        p.undo().unwrap();
        assert_eq!(p.data, before);
    }
    #[test]
    fn capture_transcript_keeps_recognized_locale_and_exact_single_word_timing() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.apply(&json!({"op":"import_transcript","transcript":{"schema_version":1,"locale":"de_DE","words":[{"text":"Hallo","src_start_ns":200_000_000,"src_end_ns":800_000_000}]},"style":{"font_family":"serif","reveal":"word","entrance":"fade"}})).unwrap();
        let r = &p.data.canvas.captions[0];
        assert_eq!(r.style.language, "de_DE");
        assert_eq!(r.words[0].tl_start_ns, r.tl_start_ns);
        assert_eq!(r.words[0].tl_end_ns, r.tl_end_ns);
        p.save(&f.0).unwrap();
        assert_eq!(
            Project::open(&f.0).unwrap().data.canvas.captions,
            p.data.canvas.captions
        );
        // A cut that contains all timed words removes their caption even if its
        // originally authored range also covered surrounding silence.
        let mut r = r.clone();
        r.tl_start_ns = 0;
        r.tl_end_ns = 1_000_000_000;
        p.data.canvas.captions = vec![r];
        p.apply(&json!({"op":"delete_range","tl_start_ns":200_000_000,"tl_end_ns":800_000_000}))
            .unwrap();
        assert!(p.data.canvas.captions.is_empty());
    }
}
