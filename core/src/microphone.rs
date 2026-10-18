//! Explicit package-owned microphone derivatives. Only selection fingerprints
//! files; evaluation/query paths compare registered identities in memory.
use crate::{
    commands::ChangeSet,
    model::{Media, MicrophoneReplacement, ProjectData, Session},
    project::{fingerprint, relative_path, Error, Project, Result},
};
use serde_json::{json, Value};
use std::{collections::BTreeMap, path::Component};

fn is_microphone(session: &Session, path: &str) -> bool {
    session.segments.iter().any(|s| {
        s.files
            .get("mic")
            .is_some_and(|file| path.strip_prefix("recording/") == Some(file.as_str()))
    })
}
fn asset_path(path: &str) -> bool {
    path.starts_with("assets/")
        && std::path::Path::new(path)
            .components()
            .all(|c| matches!(c, Component::Normal(_)))
}
pub(crate) fn validate(data: &ProjectData, session: &Session) -> Result<()> {
    let mut originals = std::collections::HashSet::new();
    for binding in &data.audio.mic_replacements {
        if !is_microphone(session, &binding.original.path)
            || !originals.insert(&binding.original.path)
            || !asset_path(&binding.enhanced.path)
            || [&binding.original, &binding.enhanced]
                .iter()
                .any(|identity| {
                    identity.head_hash.is_empty()
                        || !data.media.iter().any(|m| m.path == identity.path)
                })
        {
            return Err(Error::new(1, "Invalid microphone replacement"));
        }
    }
    Ok(())
}

/// (effective path, enhanced selected, stored binding is stale).
pub(crate) fn effective<'a>(data: &'a ProjectData, original: &'a str) -> (&'a str, bool, bool) {
    let Some(binding) = data
        .audio
        .mic_replacements
        .iter()
        .find(|b| b.original.path == original)
    else {
        return (original, false, false);
    };
    if [&binding.original, &binding.enhanced]
        .iter()
        .all(|identity| data.media.iter().any(|m| m == *identity))
    {
        (&binding.enhanced.path, true, false)
    } else {
        (original, false, true)
    }
}

pub(crate) fn query(project: &Project) -> Result<Value> {
    let mut originals = BTreeMap::new();
    for segment in &project.session.segments {
        let Some(file) = segment.files.get("mic") else {
            continue;
        };
        let start = segment.src_start_ns + segment.track_start_ns.get("mic").copied().unwrap_or(0);
        let end = segment.src_start_ns + segment.duration_ns;
        if start >= end
            || !project
                .data
                .timeline
                .clips
                .iter()
                .any(|c| c.src_start_ns < end && c.src_end_ns > start)
        {
            continue;
        }
        let path = format!("recording/{file}");
        let index = media_index(&project.data, &path)?;
        originals.insert(path, index);
    }
    let mut rows = Vec::with_capacity(originals.len());
    for (original, original_index) in originals {
        let (path, enhanced, stale) = effective(&project.data, &original);
        rows.push(json!({"original":project.data.media[original_index as usize],"original_path":original,"original_media_index":original_index,
            "path":path,"media_index":media_index(&project.data,path)?,"enhanced":enhanced,"stale":stale}));
    }
    Ok(rows.into())
}
fn media_index(data: &ProjectData, path: &str) -> Result<u32> {
    let index = data
        .media
        .iter()
        .position(|m| m.path == path)
        .ok_or_else(|| Error::new(5, serde_json::to_string(&[path]).unwrap()))?;
    u32::try_from(index).map_err(|_| Error::new(1, "Microphone media index overflow"))
}

pub(crate) fn select(
    data: &mut ProjectData,
    command: &Value,
    changes: &mut ChangeSet,
    project: &Project,
) -> Result<()> {
    let original: Media = serde_json::from_value(
        command
            .get("original")
            .cloned()
            .ok_or_else(|| Error::new(1, "Missing original microphone identity"))?,
    )?;
    if !is_microphone(&project.session, &original.path) || !data.media.contains(&original) {
        return Err(Error::new(
            1,
            "Microphone source changed or is not registered",
        ));
    }
    let selected = command
        .get("path")
        .ok_or_else(|| Error::new(1, "Missing microphone selection path"))?;
    let binding = if selected.is_null() {
        None
    } else {
        let path = selected
            .as_str()
            .filter(|p| asset_path(p))
            .ok_or_else(|| Error::new(1, "Enhanced microphone must be an assets file"))?;
        let mut found = fingerprint(&relative_path(&project.package, &original.path)?)?;
        found.path = original.path.clone();
        if found != original {
            return Err(Error::new(5, serde_json::to_string(&[&original.path])?));
        }
        let mut enhanced = fingerprint(&relative_path(&project.package, path)?)?;
        enhanced.path = path.into();
        if let Some(registered) = data.media.iter().find(|m| m.path == path) {
            if registered != &enhanced {
                return Err(Error::new(5, serde_json::to_string(&[path])?));
            }
        } else {
            data.media.push(enhanced.clone());
            changes.changed.push("media".into());
        }
        Some(MicrophoneReplacement {
            original: original.clone(),
            enhanced,
        })
    };
    data.audio
        .mic_replacements
        .retain(|b| b.original.path != original.path);
    if let Some(binding) = binding {
        data.audio.mic_replacements.push(binding);
    }
    changes.changed.push("audio.mic_replacements".into());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::tests::Fixture;
    use std::fs;

    fn fixture() -> (Fixture, Project, Media) {
        let f = Fixture::new();
        let session_path = f.0.join("recording/session.json");
        let mut session: Session =
            serde_json::from_slice(&fs::read(&session_path).unwrap()).unwrap();
        session.tracks.mic = Some(crate::model::AudioTrack {
            device_name: None,
            sample_rate: 48000,
            channels: 1,
            speech_enhancement: None,
            stereo_mic: None,
        });
        session.segments[0]
            .files
            .insert("mic".into(), "seg-000/mic.wav".into());
        session.segments[0]
            .track_start_ns
            .insert("mic".into(), 137_000_000);
        fs::write(&session_path, serde_json::to_vec(&session).unwrap()).unwrap();
        fs::write(
            f.0.join("recording/seg-000/mic.wav"),
            b"model-test-original",
        )
        .unwrap();
        fs::create_dir(f.0.join("assets")).unwrap();
        fs::write(f.0.join("assets/mic.caf"), b"model-test-processed").unwrap();
        let p = Project::create(&f.0).unwrap();
        let original = p
            .data
            .media
            .iter()
            .find(|m| m.path.ends_with("mic.wav"))
            .unwrap()
            .clone();
        (f, p, original)
    }
    fn choose(p: &mut Project, original: &Media) {
        p.apply(&json!({"op":"select_mic","original":original,"path":"assets/mic.caf"}))
            .unwrap();
    }
    fn audio(p: &Project) -> Value {
        p.query(&json!({"q":"audio_ranges"})).unwrap()
    }

    #[test]
    fn selection_preserves_edited_mapping_gains_and_snapshot_history() {
        let (f, mut p, original) = fixture();
        p.apply(&json!({"op":"split","at_tl_ns":1_000_000_000}))
            .unwrap();
        let id = p.data.timeline.clips[0].id.clone();
        p.apply(&json!({"op":"set_speed","clip_id":id,"speed":1.4}))
            .unwrap();
        p.apply(&json!({"op":"set_clip_settings","clip_id":id,"patch":{"mic_gain":0.5}}))
            .unwrap();
        p.apply(
            &json!({"op":"insert_source","src_start_ns":0,"src_end_ns":700_000_000,"at_tl_ns":0}),
        )
        .unwrap();
        let before = audio(&p);
        let snap = p.clone();
        let session_bytes = fs::read(f.0.join("recording/session.json")).unwrap();
        let original_bytes = fs::read(f.0.join(&original.path)).unwrap();
        choose(&mut p, &original);
        let mut expected = before.clone();
        for row in expected.as_array_mut().unwrap() {
            if row["track"] == "mic" {
                row["path"] = "assets/mic.caf".into();
            }
        }
        assert_eq!(audio(&p), expected);
        assert_eq!(audio(&snap), before);
        let rows = query(&p).unwrap();
        assert_eq!(rows.as_array().unwrap().len(), 1);
        assert_eq!(rows[0]["enhanced"], true);
        assert_eq!(
            rows[0]["original"],
            serde_json::to_value(&original).unwrap()
        );
        assert_eq!(
            p.query(&json!({"q":"speech_enhancement"})).unwrap()["media"],
            rows
        );
        let request = json!({"q":"map_audio_ranges","track":"mic","path":"assets/mic.caf","ranges":[{"file_start_ns":0,"file_end_ns":500_000_000}]});
        let mut original_request = request.clone();
        original_request["path"] = original.path.clone().into();
        assert_eq!(
            p.query(&request).unwrap(),
            p.query(&original_request).unwrap()
        );
        p.undo().unwrap();
        assert_eq!(audio(&p), before);
        p.redo().unwrap();
        assert_eq!(audio(&p), expected);
        p.save(&f.0).unwrap();
        assert_eq!(audio(&Project::open(&f.0).unwrap()), expected);
        p.apply(&json!({"op":"select_mic","original":original,"path":null}))
            .unwrap();
        assert_eq!(audio(&p), before);
        assert_eq!(
            fs::read(f.0.join("recording/session.json")).unwrap(),
            session_bytes
        );
        assert_eq!(fs::read(f.0.join(&original.path)).unwrap(), original_bytes);
        assert!(f.0.join("assets/mic.caf").exists());
    }

    #[test]
    fn relink_invalidates_selection_and_late_processing_result_is_rejected() {
        let (f, mut p, original) = fixture();
        choose(&mut p, &original);
        let snap = p.clone();
        fs::write(f.0.join(&original.path), b"a-new-microphone-file").unwrap();
        let data = serde_json::to_value(&p.data).unwrap();
        p.apply(&json!({"op":"relink_project","project":data,"paths":[original.path]}))
            .unwrap();
        assert_eq!(query(&p).unwrap()[0]["stale"], true);
        assert_eq!(query(&p).unwrap()[0]["path"], original.path);
        assert_eq!(query(&snap).unwrap()[0]["enhanced"], true);
        let before = p.data.clone();
        assert!(p
            .apply(&json!({"op":"select_mic","original":original,"path":"assets/mic.caf"}))
            .is_err());
        assert_eq!(p.data, before);
        p.save(&f.0).unwrap();
        assert_eq!(
            query(&Project::open(&f.0).unwrap()).unwrap()[0]["stale"],
            true
        );

        // Relinking the derivative also invalidates its prior decoded identity.
        let (f, mut p, original) = fixture();
        choose(&mut p, &original);
        fs::write(f.0.join("assets/mic.caf"), b"new-processed-file").unwrap();
        p.apply(&json!({"op":"relink_project","project":p.data,"paths":["assets/mic.caf"]}))
            .unwrap();
        assert_eq!(query(&p).unwrap()[0]["stale"], true);
        assert_eq!(query(&p).unwrap()[0]["path"], original.path);
    }

    #[test]
    fn shared_derivative_is_prepared_once_and_selections_remain_independent() {
        let (f, mut p, original) = fixture();
        let second_path = "recording/seg-001/mic.wav";
        fs::write(f.0.join(second_path), b"second-model-original").unwrap();
        let mut second = fingerprint(&f.0.join(second_path)).unwrap();
        second.path = second_path.into();
        p.data.media.push(second.clone());
        p.session.segments[1]
            .files
            .insert("mic".into(), "seg-001/mic.wav".into());
        choose(&mut p, &original);
        choose(&mut p, &second);
        assert_eq!(query(&p).unwrap().as_array().unwrap().len(), 2);
        assert_eq!(
            p.query(&json!({"q":"speech_enhancement"})).unwrap()["media"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        p.apply(&json!({"op":"select_mic","original":original,"path":null}))
            .unwrap();
        assert!(!effective(&p.data, &original.path).1);
        assert!(effective(&p.data, &second.path).1);
        assert_eq!(
            p.query(&json!({"q":"speech_enhancement"})).unwrap()["media"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        p.data.timeline.clips.clear();
        assert_eq!(query(&p).unwrap(), json!([]));
    }

    #[test]
    fn invalid_selection_is_atomic_and_presets_never_carry_source_bindings() {
        let (f, mut p, original) = fixture();
        let before = p.data.clone();
        for path in [
            json!("recording/seg-000/mic.wav"),
            json!("assets/../escape"),
            json!(4),
        ] {
            assert!(p.apply(&json!({"op":"batch","commands":[{"op":"set","path":"notes","value":"rollback"},{"op":"select_mic","original":original,"path":path}]})).is_err());
            assert_eq!(p.data, before);
        }
        assert!(p
            .apply(&json!({"op":"select_mic","original":original}))
            .is_err());
        fs::write(f.0.join(&original.path), b"changed-without-relink").unwrap();
        assert!(p
            .apply(&json!({"op":"select_mic","original":original,"path":"assets/mic.caf"}))
            .is_err());
        assert_eq!(p.data, before);
        let (_f, mut p, original) = fixture();
        choose(&mut p, &original);
        let preset = p.query(&json!({"q":"preset"})).unwrap();
        assert!(preset["audio"].get("mic_replacements").is_none());
        let binding = p.data.audio.mic_replacements[0].clone();
        for value in [
            json!([binding, binding]),
            json!([{"original":original,"enhanced":{"path":"../escape","size":1,"head_hash":"bad"}}]),
        ] {
            let before = p.data.clone();
            assert!(p
                .apply(&json!({"op":"set","path":"audio.mic_replacements","value":value}))
                .is_err());
            assert_eq!(p.data, before);
        }
        let (_target_fixture, mut target, _) = fixture();
        target.apply(&json!({"op":"apply_preset","preset":{"audio":{"mic_replacements":p.data.audio.mic_replacements,"mic_gain_db":-6}}})).unwrap();
        assert!(target.data.audio.mic_replacements.is_empty());
        assert_eq!(target.data.audio.mic_gain_db, -6.0);
        let mut legacy = serde_json::to_value(&before).unwrap();
        legacy["audio"]
            .as_object_mut()
            .unwrap()
            .remove("mic_replacements");
        assert!(
            crate::project::decode_project(&serde_json::to_vec(&legacy).unwrap())
                .unwrap()
                .audio
                .mic_replacements
                .is_empty()
        );
    }
}
