//! A single timeline→source map is shared by all media and input events.
//! Keep clip durations fractional until the API's integer nanosecond boundary.
use crate::model::{Clip, Session};
#[derive(Clone, Copy, Debug, Default, PartialEq)]
#[repr(C)]
pub struct Sample { pub present: u8, pub segment: u32, pub file_ns: i64, pub src_ns: i64 }
pub fn clip_duration(c: &Clip) -> f64 { (c.src_end_ns - c.src_start_ns) as f64 / c.speed }
pub fn duration(clips: &[Clip]) -> i64 {
    let mut total = 0.0; let mut correction = 0.0;
    for c in clips { let v = clip_duration(c) - correction; let n = total + v; correction = (n - total) - v; total = n; }
    total.round() as i64
}
pub fn timeline_to_source(clips: &[Clip], tl: i64) -> Option<(usize, i64)> {
    if tl < 0 { return None; }
    let mut start = 0.0;
    for (i, c) in clips.iter().enumerate() {
        let end = start + clip_duration(c);
        if (tl as f64) < end || (i + 1 == clips.len() && tl == end.round() as i64) {
            let src = c.src_start_ns + (((tl as f64 - start) * c.speed).round() as i64);
            return Some((i, src.clamp(c.src_start_ns, c.src_end_ns - 1)));
        }
        start = end;
    }
    None
}
/// One source sample can occur multiple times if clips repeat the recording.
pub fn source_to_timeline(clips: &[Clip], clip_index: usize, src: i64) -> Option<i64> {
    let c = clips.get(clip_index)?;
    if src < c.src_start_ns || src >= c.src_end_ns { return None; }
    let start: f64 = clips[..clip_index].iter().map(clip_duration).sum();
    Some((start + (src - c.src_start_ns) as f64 / c.speed).round() as i64)
}
pub fn sample(session: &Session, track: &str, src: i64) -> Sample {
    let i = session.segments.partition_point(|s| s.src_start_ns <= src);
    if i == 0 { return Sample::default(); }
    let s = &session.segments[i-1];
    let local = src - s.src_start_ns;
    let offset = s.track_start_ns.get(track).copied().unwrap_or(0);
    if local < offset || local >= s.duration_ns || !s.files.contains_key(track) { return Sample { src_ns: src, ..Sample::default() }; }
    Sample { present: 1, segment: (i-1) as u32, file_ns: local-offset, src_ns: src }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pause_and_track_offset() {
        let mut s: Session = serde_json::from_str(include_str!("../../Tests/Fixtures/synthetic/basic.yapcam/recording/session.json")).unwrap();
        s.segments[1].track_start_ns.insert("system_audio".into(), 1_200_000);
        let screen = sample(&s, "screen", 3_002_000_000); let audio = sample(&s, "system_audio", 3_002_000_000);
        assert_eq!(screen.segment, 1); assert_eq!(screen.file_ns, 2_000_000);
        assert_eq!(audio.file_ns, 800_000); assert_eq!(screen.src_ns, audio.src_ns);
        assert_eq!(sample(&s, "system_audio", 3_000_000_000).present, 0);
        assert_eq!(sample(&s, "screen", 5_000_000_000).present, 0);
    }
}
