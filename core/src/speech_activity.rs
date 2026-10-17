//! Immutable source analysis mapped once on cold edits; hot camera gates read ranges.
use crate::{
    model::*,
    project::{Error, Result},
    time,
};
pub(crate) fn validate(p: &ProjectData) -> Result<()> {
    let Some(a) = &p.camera.speech_activity else {
        return Ok(());
    };
    if !matches!(a.source.as_str(), "vad" | "transcript")
        || a.coverage_start_ns < 0
        || a.coverage_end_ns <= a.coverage_start_ns
        || a.ranges.iter().any(|r| {
            r.src_start_ns < a.coverage_start_ns
                || r.src_end_ns > a.coverage_end_ns
                || r.src_end_ns <= r.src_start_ns
        })
    {
        return Err(Error::new(1, "Invalid source speech activity or coverage"));
    }
    Ok(())
}
pub(crate) fn refresh(p: &mut ProjectData) -> Result<()> {
    validate(p)?;
    let Some(a) = &mut p.camera.speech_activity else {
        return Ok(());
    };
    a.ranges.sort_by_key(|r| r.src_start_ns);
    let mut voiced: Vec<SourceActivityRange> = Vec::new();
    for range in &a.ranges {
        if let Some(last) = voiced.last_mut() {
            if range.src_start_ns <= last.src_end_ns {
                last.src_end_ns = last.src_end_ns.max(range.src_end_ns);
                continue;
            }
        }
        voiced.push(range.clone());
    }
    a.ranges = voiced;
    let mut silent = Vec::new();
    let mut at = a.coverage_start_ns;
    for range in &a.ranges {
        if range.src_start_ns > at {
            silent.push((at, range.src_start_ns));
        }
        at = range.src_end_ns;
    }
    if at < a.coverage_end_ns {
        silent.push((at, a.coverage_end_ns));
    }
    let clock = time::ClipTimeIndex::new(&p.timeline.clips);
    let mut mapped = Vec::new();
    for (i, clip) in p.timeline.clips.iter().enumerate() {
        let a = silent.partition_point(|r| r.1 <= clip.src_start_ns);
        let b = silent.partition_point(|r| r.0 < clip.src_end_ns);
        for &(start, end) in &silent[a..b] {
            let start = clock
                .source_boundary_to_timeline(&p.timeline.clips, i, start.max(clip.src_start_ns))
                .unwrap();
            let end = clock
                .source_boundary_to_timeline(&p.timeline.clips, i, end.min(clip.src_end_ns))
                .unwrap();
            if end > start {
                mapped.push(ActivityRange {
                    tl_start_ns: start,
                    tl_end_ns: end,
                });
            }
        }
    }
    let mut merged: Vec<ActivityRange> = Vec::new();
    for range in mapped {
        if let Some(last) = merged.last_mut() {
            if range.tl_start_ns <= last.tl_end_ns {
                last.tl_end_ns = last.tl_end_ns.max(range.tl_end_ns);
                continue;
            }
        }
        merged.push(range);
    }
    p.camera.silence_ranges = merged;
    Ok(())
}
