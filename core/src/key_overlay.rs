//! Immutable captured-key and edited-timeline indexes. Construct only on cold
//! load/edit/history paths; overlay lookup is binary search over eligible keys.
use crate::{
    model::{Clip, Event, Session},
    time::ClipTimeIndex,
};
use serde_json::Value;
use std::sync::Arc;
struct SourceKey {
    t: i64,
    event: usize,
    text: String,
    shortcut: bool,
}
struct SegmentKeys {
    src_start_ns: i64,
    keys: Vec<SourceKey>,
}
#[derive(Clone, Copy)]
struct KeyAt {
    tl_ns: i64,
    segment: usize,
    key: usize,
}
pub(crate) struct KeyOverlayIndex {
    source: Arc<Vec<SegmentKeys>>,
    clips: Vec<Clip>,
    all: Vec<KeyAt>,
    shortcuts: Vec<KeyAt>,
}
impl KeyOverlayIndex {
    pub(crate) fn new(session: &Session, events: &[Vec<Event>], clips: &[Clip]) -> Arc<Self> {
        let source = session
            .segments
            .iter()
            .zip(events)
            .map(|(segment, events)| {
                let keys = events
                    .iter()
                    .enumerate()
                    .filter(|(_, e)| e.kind == "key")
                    .map(|(event, e)| {
                        let mods = e.details.get("modifiers").and_then(Value::as_array);
                        let has = |name| {
                            mods.is_some_and(|mods| mods.iter().any(|v| v.as_str() == Some(name)))
                        };
                        let mut text = String::new();
                        for (name, glyph) in
                            [("ctrl", "⌃"), ("alt", "⌥"), ("shift", "⇧"), ("cmd", "⌘")]
                        {
                            if has(name) {
                                text.push_str(glyph);
                            }
                        }
                        if let Some(key) = e.details.get("key").and_then(Value::as_str) {
                            text.push_str(key);
                        }
                        SourceKey {
                            t: e.t,
                            event,
                            text,
                            shortcut: has("ctrl") || has("alt") || has("cmd"),
                        }
                    })
                    .collect();
                SegmentKeys {
                    src_start_ns: segment.src_start_ns,
                    keys,
                }
            })
            .collect();
        Self::mapped(Arc::new(source), clips)
    }
    fn mapped(source: Arc<Vec<SegmentKeys>>, clips: &[Clip]) -> Arc<Self> {
        let time = ClipTimeIndex::new(clips);
        let mut all = Vec::new();
        for (i, clip) in clips.iter().enumerate() {
            for (segment, s) in source.iter().enumerate() {
                let a = s
                    .keys
                    .partition_point(|k| k.t < clip.src_start_ns - s.src_start_ns);
                let b = s
                    .keys
                    .partition_point(|k| k.t < clip.src_end_ns - s.src_start_ns);
                for key in a..b {
                    let src = s.src_start_ns + s.keys[key].t;
                    if let Some(tl_ns) = time.source_to_timeline(clips, i, src) {
                        all.push(KeyAt {
                            tl_ns,
                            segment,
                            key,
                        });
                    }
                }
            }
        }
        // Stable ties retain clip/segment/capture order, as the original query.
        all.sort_by_key(|k| k.tl_ns);
        let shortcuts = all
            .iter()
            .copied()
            .filter(|k| source[k.segment].keys[k.key].shortcut)
            .collect();
        Arc::new(Self {
            source,
            clips: clips.to_vec(),
            all,
            shortcuts,
        })
    }
    pub(crate) fn for_clips(self: &Arc<Self>, clips: &[Clip]) -> Arc<Self> {
        if self.clips.len() == clips.len()
            && self.clips.iter().zip(clips).all(|(a, b)| {
                a.id == b.id
                    && a.src_start_ns == b.src_start_ns
                    && a.src_end_ns == b.src_end_ns
                    && a.speed == b.speed
            })
        {
            Arc::clone(self)
        } else {
            Self::mapped(Arc::clone(&self.source), clips)
        }
    }
    pub(crate) fn latest(
        &self,
        tl_ns: i64,
        duration_ns: i64,
        shortcuts_only: bool,
    ) -> Option<&str> {
        let rows = if shortcuts_only {
            &self.shortcuts
        } else {
            &self.all
        };
        let i = rows.partition_point(|k| k.tl_ns <= tl_ns);
        let row = rows.get(i.checked_sub(1)?)?;
        if tl_ns - row.tl_ns >= duration_ns {
            return None;
        }
        Some(&self.source[row.segment].keys[row.key].text)
    }
    pub(crate) fn shortcut_catalog(&self, hidden: &[String]) -> Value {
        let mut rows = std::collections::BTreeMap::new();
        for row in &self.all {
            let key = &self.source[row.segment].keys[row.key];
            if key.text.trim().is_empty() {
                continue;
            }
            rows.entry(&key.text).or_insert_with(|| serde_json::json!({"text":key.text,"is_shortcut":key.shortcut,"hidden":hidden.contains(&key.text)}));
        }
        Value::Array(rows.into_values().collect())
    }
    /// Captured source clocks, unaffected by cuts, speed, or repeated clips.
    pub(crate) fn captured_times(&self) -> impl Iterator<Item = (usize, i64)> + '_ {
        self.source
            .iter()
            .enumerate()
            .flat_map(|(i, s)| s.keys.iter().map(move |k| (i, s.src_start_ns + k.t)))
    }
    pub(crate) fn events(&self) -> impl Iterator<Item = (usize, usize, i64, i64)> + '_ {
        self.all.iter().map(|row| {
            let segment = &self.source[row.segment];
            let key = &segment.keys[row.key];
            (
                row.segment,
                key.event,
                segment.src_start_ns + key.t,
                row.tl_ns,
            )
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        model::*,
        project::{tests::Fixture, Project},
    };
    use serde_json::json;
    fn project() -> (Fixture, Project) {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.events[0]=[
            json!({"t":100_000_000,"type":"key","key":"a","modifiers":["cmd"]}),
            json!({"t":200_000_000,"type":"key","key":"β","modifiers":["shift"]}),
            json!({"t":300_000_000,"type":"key","key":"z","modifiers":["cmd","ctrl","alt","shift","cmd"]}),
            json!({"t":300_000_000,"type":"key","key":"last","modifiers":["alt"]}),
            json!({"t":400_000_000,"type":"key"}),
        ].into_iter().map(|v|serde_json::from_value(v).unwrap()).collect();
        p.events[1].clear();
        p.rebuild_key_overlay_index();
        p.apply(&json!({"op":"batch","commands":[{"op":"set","path":"cursor.key_overlay.enabled","value":true},{"op":"set","path":"cursor.key_overlay.duration_ns","value":500_000_000}]})).unwrap();
        (f, p)
    }
    fn old_query(p: &Project) -> Value {
        let mut rows = Vec::new();
        for i in 0..p.data.timeline.clips.len() {
            for (s, events) in p.session.segments.iter().zip(&p.events) {
                for e in events.iter().filter(|e| e.kind == "key") {
                    let src = s.src_start_ns + e.t;
                    if let Some(tl) =
                        crate::time::source_to_timeline(&p.data.timeline.clips, i, src)
                    {
                        let mut row = serde_json::to_value(e).unwrap();
                        row["src_ns"] = src.into();
                        row["tl_ns"] = tl.into();
                        row["segment"] = s.index.into();
                        rows.push(row);
                    }
                }
            }
        }
        rows.sort_by_key(|row| row["tl_ns"].as_i64());
        rows.into()
    }
    #[test]
    fn hidden_chords_keep_source_keys_and_history_and_catalog_follow_edits() {
        let (fixture, mut p) = project();
        let query = json!({"q":"key_overlay_shortcuts"});
        assert_eq!(p.query(&query).unwrap().as_array().unwrap().len(), 4);
        let before = p.query(&json!({"q":"key_events"})).unwrap();
        p.apply(&json!({"op":"set","path":"cursor.key_overlay.hidden_shortcuts","value":["⌘a"]}))
            .unwrap();
        assert!(p
            .query(&json!({"q":"layers_at","tl_ns":150_000_000}))
            .unwrap()
            .as_array()
            .unwrap()
            .iter()
            .all(|r| r["id"] != "core:key-overlay"));
        assert!(p
            .query(&query)
            .unwrap()
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["text"] == "⌘a" && r["hidden"] == true));
        assert_eq!(p.query(&json!({"q":"key_events"})).unwrap(), before);
        let snapshot = p.clone();
        p.undo().unwrap();
        assert!(p
            .query(&json!({"q":"layers_at","tl_ns":150_000_000}))
            .unwrap()
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["id"] == "core:key-overlay"));
        assert!(snapshot
            .data
            .cursor
            .key_overlay
            .hidden_shortcuts
            .contains(&"⌘a".into()));
        p.redo().unwrap();
        p.save(&fixture.0).unwrap();
        assert_eq!(
            Project::open(&fixture.0)
                .unwrap()
                .data
                .cursor
                .key_overlay
                .hidden_shortcuts,
            vec!["⌘a"]
        );
        let before = p.data.clone();
        assert!(p
            .apply(&json!({"op":"set","path":"cursor.key_overlay.hidden_shortcuts","value":[""]}))
            .is_err());
        assert_eq!(p.data, before);
        p.apply(&json!({"op":"delete_range","tl_start_ns":0,"tl_end_ns":250_000_000}))
            .unwrap();
        assert!(p
            .query(&query)
            .unwrap()
            .as_array()
            .unwrap()
            .iter()
            .all(|r| r["text"] != "⌘a"));
    }
    #[test]
    fn indexed_overlay_preserves_shortcuts_expiry_empty_keys_ties_and_layers() {
        let (_f, mut p) = project();
        assert_eq!(p.query(&json!({"q":"key_events"})).unwrap(), old_query(&p));
        let index = Arc::clone(&p.key_overlay_index);
        assert_eq!(index.latest(0, 500_000_000, true), None);
        assert_eq!(index.latest(250_000_000, 500_000_000, true), Some("⌘a"));
        assert_eq!(index.latest(250_000_000, 500_000_000, false), Some("⇧β"));
        assert_eq!(index.latest(300_000_000, 500_000_000, true), Some("⌥last"));
        assert_eq!(index.latest(400_000_000, 500_000_000, false), Some(""));
        assert_eq!(index.latest(800_000_000, 500_000_000, true), None);
        assert_eq!(
            crate::allocation_test::count(|| {
                assert_eq!(index.latest(300_000_000, 500_000_000, true), Some("⌥last"));
            }),
            0
        );
        p.apply(&json!({"op":"set","path":"cursor.key_overlay.shortcuts_only","value":false}))
            .unwrap();
        assert!(Arc::ptr_eq(&index, &p.key_overlay_index));
        assert_eq!(
            p.layers_at(250_000_000)
                .unwrap()
                .as_array()
                .unwrap()
                .last()
                .unwrap()["text"],
            json!("⇧β")
        );
        assert!(!p
            .layers_at(400_000_000)
            .unwrap()
            .as_array()
            .unwrap()
            .iter()
            .any(|row| row["id"] == "core:key-overlay"));
        p.apply(&json!({"op":"set","path":"cursor.key_overlay.shortcuts_only","value":true}))
            .unwrap();
        p.apply(&json!({"op":"add_annotation","record":{"id":"annotation","text":"first","tl_start_ns":0,"tl_end_ns":1_000_000_000}})).unwrap();
        p.apply(&json!({"op":"set","path":"canvas.animation.entrance","value":"fade"}))
            .unwrap();
        let rows = p.layers_at(300_000_000).unwrap();
        let rows = rows.as_array().unwrap();
        assert_eq!(rows.last().unwrap()["id"], json!("canvas-fade"));
        assert_eq!(rows[rows.len() - 2]["id"], json!("core:key-overlay"));
        let before = Arc::clone(&p.key_overlay_index);
        p.apply(&json!({"op":"set","path":"cursor.key_overlay.duration_ns","value":100_000_000}))
            .unwrap();
        assert!(Arc::ptr_eq(&before, &p.key_overlay_index));
        assert_eq!(
            p.key_overlay_index
                .latest(450_000_000, p.data.cursor.key_overlay.duration_ns, true),
            None
        );
        let failed=p.apply(&json!({"op":"batch","commands":[{"op":"delete_range","tl_start_ns":0,"tl_end_ns":500_000_000},{"op":"set","path":"canvas.padding","value":-1}]}));
        assert!(failed.is_err());
        assert!(Arc::ptr_eq(&before, &p.key_overlay_index));
    }
    #[test]
    fn remapped_keys_match_query_oracle_across_repeats_speeds_cuts_history_and_snapshots() {
        let (f, mut p) = project();
        p.data.timeline.clips = vec![
            Clip {
                id: "first".into(),
                src_start_ns: 0,
                src_end_ns: 500_000_000,
                speed: 1.5,
                settings: Default::default(),
            },
            Clip {
                id: "repeat".into(),
                src_start_ns: 0,
                src_end_ns: 500_000_000,
                speed: 2.0,
                settings: Default::default(),
            },
        ];
        p.rebuild_key_overlay_index();
        let snapshot = p.clone();
        assert!(Arc::ptr_eq(
            &p.key_overlay_index,
            &snapshot.key_overlay_index
        ));
        let frozen = snapshot.query(&json!({"q":"key_events"})).unwrap();
        for command in [
            json!({"op":"set_speed","clip_id":"first","speed":3}),
            json!({"op":"delete_range","tl_start_ns":0,"tl_end_ns":100_000_000}),
        ] {
            p.apply(&command).unwrap();
            assert_eq!(p.query(&json!({"q":"key_events"})).unwrap(), old_query(&p));
            assert_eq!(snapshot.query(&json!({"q":"key_events"})).unwrap(), frozen);
        }
        for _ in 0..2 {
            p.undo().unwrap();
            assert_eq!(p.query(&json!({"q":"key_events"})).unwrap(), old_query(&p));
        }
        assert_eq!(p.query(&json!({"q":"key_events"})).unwrap(), frozen);
        for _ in 0..2 {
            p.redo().unwrap();
            assert_eq!(p.query(&json!({"q":"key_events"})).unwrap(), old_query(&p));
        }
        p.save(&f.0).unwrap();
        // Capture replacement explicitly rebuilds the immutable source index.
        let before = p
            .key_overlay_index
            .latest(0, 1_000_000_000, false)
            .map(str::to_owned);
        p.events[0].clear();
        p.rebuild_key_overlay_index();
        assert_eq!(p.key_overlay_index.latest(0, 1_000_000_000, false), None);
        assert!(before.is_some());
        assert_eq!(snapshot.query(&json!({"q":"key_events"})).unwrap(), frozen);
    }
}
