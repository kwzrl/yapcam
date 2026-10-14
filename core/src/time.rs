//! A single timeline→source map is shared by all media and input events.
//! Keep clip durations fractional until the API's integer nanosecond boundary.
use crate::model::{Clip, Session};
#[derive(Clone, Copy, Debug, Default, PartialEq)]
#[repr(C)]
pub struct Sample {
    pub present: u8,
    pub segment: u32,
    pub file_ns: i64,
    pub src_ns: i64,
}
pub fn clip_duration(c: &Clip) -> f64 {
    (c.src_end_ns - c.src_start_ns) as f64 / c.speed
}
// Rational arithmetic retains fractional nanoseconds across clip boundaries.
// Unusually large denominator combinations fall back to Q32 fractional ns, whose
// precision is much finer than the single rounding at the API boundary.
#[derive(Clone, Copy, Debug)]
struct Fraction {
    n: i128,
    d: i128,
}
fn gcd(mut a: i128, mut b: i128) -> i128 {
    a = a.abs();
    b = b.abs();
    while b != 0 {
        let r = a % b;
        a = b;
        b = r;
    }
    a.max(1)
}
impl Fraction {
    fn new(n: i128, d: i128) -> Self {
        let g = gcd(n, d);
        Self { n: n / g, d: d / g }
    }
    fn integer(n: i64) -> Self {
        Self { n: n as i128, d: 1 }
    }
    fn rate(speed: f64) -> Self {
        let mut scale = 1i128;
        for _ in 0..10 {
            let value = speed * scale as f64;
            // A decimal candidate must reproduce the input Double exactly.
            // A tolerance would erase real edits such as speed=1.000000001.
            if value.round() / scale as f64 == speed {
                return Self::new(value.round() as i128, scale);
            }
            scale *= 10;
        }
        let bits = speed.to_bits();
        let mantissa = ((bits & ((1u64 << 52) - 1)) | (1u64 << 52)) as i128;
        let exponent = ((bits >> 52) & 2047) as i32 - 1023 - 52;
        if exponent < 0 {
            Self::new(mantissa, 1i128 << (-exponent))
        } else {
            Self::new(mantissa << exponent, 1)
        }
    }
    fn ticks(self) -> i128 {
        let negative = self.n < 0;
        let n = self.n.abs();
        let whole = n / self.d;
        let mut remainder = n % self.d;
        let mut fraction = 0;
        for _ in 0..32 {
            fraction *= 2;
            if remainder >= self.d - remainder {
                remainder -= self.d - remainder;
                fraction += 1;
            } else {
                remainder *= 2;
            }
        }
        let ticks = (whole << 32) + fraction;
        if negative {
            -ticks
        } else {
            ticks
        }
    }
    fn add(self, b: Self) -> Self {
        let g = gcd(self.d, b.d);
        let left = b.d / g;
        let right = self.d / g;
        if let Some(n) = self
            .n
            .checked_mul(left)
            .and_then(|n| b.n.checked_mul(right).and_then(|m| n.checked_add(m)))
        {
            if let Some(d) = self.d.checked_mul(left) {
                return Self::new(n, d);
            }
        }
        Self::new(self.ticks() + b.ticks(), 1i128 << 32)
    }
    fn subtract(self, b: Self) -> Self {
        self.add(Self { n: -b.n, d: b.d })
    }
    fn multiply(self, b: Self) -> Self {
        let g = gcd(self.n, b.d);
        let h = gcd(b.n, self.d);
        if let (Some(n), Some(d)) = (
            (self.n / g).checked_mul(b.n / h),
            (self.d / h).checked_mul(b.d / g),
        ) {
            return Self::new(n, d);
        }
        let ticks = self.ticks();
        let scaled = (ticks / b.d) * b.n + (ticks % b.d) * b.n / b.d;
        Self::new(scaled, 1i128 << 32)
    }
    fn round(self) -> i64 {
        let n = self.n.abs();
        let value = n / self.d
            + if n % self.d >= self.d / 2 + self.d % 2 {
                1
            } else {
                0
            };
        let signed = if self.n < 0 { -value } else { value };
        signed.clamp(i64::MIN as i128, i64::MAX as i128) as i64
    }
    fn greater_than(self, t: i64) -> bool {
        let whole = self.n / self.d;
        whole > t as i128 || (whole == t as i128 && self.n % self.d > 0)
    }
}
fn exact_duration(c: &Clip) -> Fraction {
    let speed = Fraction::rate(c.speed);
    Fraction::new((c.src_end_ns - c.src_start_ns) as i128 * speed.d, speed.n)
}
fn start_of(clips: &[Clip]) -> Fraction {
    clips
        .iter()
        .fold(Fraction::integer(0), |t, c| t.add(exact_duration(c)))
}
/// A speed edit remaps timeline-attached effects without losing long-clock ns.
pub(crate) struct SpeedTimeMap {
    start: Fraction,
    end: Fraction,
    duration_delta: Fraction,
    old_rate: Fraction,
    new_inverse_rate: Fraction,
}
impl SpeedTimeMap {
    pub(crate) fn new(clips: &[Clip], index: usize, speed: f64) -> Self {
        let c = &clips[index];
        let start = start_of(&clips[..index]);
        let old = exact_duration(c);
        let old_rate = Fraction::rate(c.speed);
        let new_rate = Fraction::rate(speed);
        let new_inverse_rate = Fraction::new(new_rate.d, new_rate.n);
        let new = Fraction::integer(c.src_end_ns - c.src_start_ns).multiply(new_inverse_rate);
        Self {
            start,
            end: start.add(old),
            duration_delta: new.subtract(old),
            old_rate,
            new_inverse_rate,
        }
    }
    pub(crate) fn map(&self, t: i64) -> i64 {
        // Public clip edges are integer ns; snapped effects stay on those edges.
        if t == self.start.round() {
            return t;
        }
        if t == self.end.round() {
            return self.end.add(self.duration_delta).round();
        }
        if self.start.greater_than(t) {
            t
        } else if self.end.greater_than(t) {
            self.start
                .add(
                    Fraction::integer(t)
                        .subtract(self.start)
                        .multiply(self.old_rate)
                        .multiply(self.new_inverse_rate),
                )
                .round()
        } else {
            Fraction::integer(t).add(self.duration_delta).round()
        }
    }
}
/// Actual quantized source intervals removed by a cut, expressed on the old
/// rational timeline. Effects shift by media actually removed, not a Double sum.
pub(crate) struct CutTimeMap {
    spans: Vec<(Fraction, Fraction)>,
}
impl CutTimeMap {
    pub(crate) fn new(clips: &[Clip], removed: &[(usize, i64, i64)]) -> Self {
        let spans = removed
            .iter()
            .map(|&(i, a, b)| {
                let c = &clips[i];
                let rate = Fraction::rate(c.speed);
                let start = start_of(&clips[..i]);
                let at = |src| {
                    start.add(Fraction::new(
                        (src - c.src_start_ns) as i128 * rate.d,
                        rate.n,
                    ))
                };
                (at(a), at(b))
            })
            .collect();
        Self { spans }
    }
    pub(crate) fn map(&self, t: i64) -> i64 {
        let mut removed = Fraction::integer(0);
        for &(a, b) in &self.spans {
            if t == a.round() || t == b.round() {
                return a.subtract(removed).round();
            }
            if a.greater_than(t) {
                break;
            }
            if b.greater_than(t) {
                return a.subtract(removed).round();
            }
            removed = removed.add(b.subtract(a));
        }
        Fraction::integer(t).subtract(removed).round()
    }
}
pub fn duration(clips: &[Clip]) -> i64 {
    start_of(clips).round()
}
/// Rounded public bounds, retaining fractional nanoseconds across earlier clips.
pub fn clip_bounds(clips: &[Clip], clip_index: usize) -> Option<(i64, i64)> {
    let c = clips.get(clip_index)?;
    let start = start_of(&clips[..clip_index]);
    Some((start.round(), start.add(exact_duration(c)).round()))
}
/// Cold-path interval mapping includes the endpoint, unlike sample evaluation.
pub fn source_boundary_to_timeline(clips: &[Clip], clip_index: usize, src: i64) -> Option<i64> {
    let c = clips.get(clip_index)?;
    if src < c.src_start_ns || src > c.src_end_ns {
        return None;
    }
    let rate = Fraction::rate(c.speed);
    let delta = Fraction::new((src - c.src_start_ns) as i128 * rate.d, rate.n);
    Some(start_of(&clips[..clip_index]).add(delta).round())
}
pub fn timeline_boundary_to_source(clips: &[Clip], clip_index: usize, tl: i64) -> Option<i64> {
    let c = clips.get(clip_index)?;
    let start = start_of(&clips[..clip_index]);
    // Preserve canonical snapped edges, including the rounded duration endpoint.
    if tl <= start.round() {
        return Some(c.src_start_ns);
    }
    if tl >= start.add(exact_duration(c)).round() {
        return Some(c.src_end_ns);
    }
    let delta = Fraction::integer(tl)
        .subtract(start)
        .multiply(Fraction::rate(c.speed))
        .round();
    Some(
        c.src_start_ns
            .saturating_add(delta)
            .clamp(c.src_start_ns, c.src_end_ns),
    )
}
pub fn timeline_to_source(clips: &[Clip], tl: i64) -> Option<(usize, i64)> {
    if tl < 0 {
        return None;
    }
    let mut start = Fraction::integer(0);
    for (i, c) in clips.iter().enumerate() {
        let end = start.add(exact_duration(c));
        if end.greater_than(tl) || (i + 1 == clips.len() && tl == end.round()) {
            let delta = Fraction::integer(tl)
                .subtract(start)
                .multiply(Fraction::rate(c.speed))
                .round();
            return Some((
                i,
                c.src_start_ns
                    .saturating_add(delta)
                    .clamp(c.src_start_ns, c.src_end_ns - 1),
            ));
        }
        start = end;
    }
    None
}
/// One source sample can occur multiple times if clips repeat the recording.
pub fn source_to_timeline(clips: &[Clip], clip_index: usize, src: i64) -> Option<i64> {
    let c = clips.get(clip_index)?;
    if src < c.src_start_ns || src >= c.src_end_ns {
        return None;
    }
    source_boundary_to_timeline(clips, clip_index, src)
}
pub fn sample(session: &Session, track: &str, src: i64) -> Sample {
    let i = session.segments.partition_point(|s| s.src_start_ns <= src);
    if i == 0 {
        return Sample::default();
    }
    let s = &session.segments[i - 1];
    let local = src - s.src_start_ns;
    let offset = s.track_start_ns.get(track).copied().unwrap_or(0);
    if local < offset || local >= s.duration_ns || !s.files.contains_key(track) {
        return Sample {
            src_ns: src,
            ..Sample::default()
        };
    }
    Sample {
        present: 1,
        segment: (i - 1) as u32,
        file_ns: local - offset,
        src_ns: src,
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn tiny_speed_changes_are_not_rounded_away() {
        let length = (1_i64 << 53) + 37;
        for (speed, numerator, denominator) in [
            (1.000000001, 1_000_000_001_i128, 1_000_000_000_i128),
            (2.000000003, 2_000_000_003, 1_000_000_000),
            (0.050000001, 50_000_001, 1_000_000_000),
            (
                f64::from_bits(1.0_f64.to_bits() + 1),
                (1_i128 << 52) + 1,
                1_i128 << 52,
            ),
        ] {
            let clips = [Clip {
                id: "precise".into(),
                src_start_ns: 0,
                src_end_ns: length,
                speed,
            }];
            let oracle = ((length as i128 * denominator + numerator / 2) / numerator) as i64;
            assert_eq!(duration(&clips), oracle, "rate {speed}");
            let tl = 1_000_000_000_i64;
            let src = ((tl as i128 * numerator + denominator / 2) / denominator) as i64;
            assert_eq!(timeline_to_source(&clips, tl), Some((0, src)));
        }
    }
    #[test]
    fn pause_and_track_offset() {
        let mut s: Session = serde_json::from_str(include_str!(
            "../../Tests/Fixtures/synthetic/basic.yapcam/recording/session.json"
        ))
        .unwrap();
        s.segments[1]
            .track_start_ns
            .insert("system_audio".into(), 1_200_000);
        let screen = sample(&s, "screen", 3_002_000_000);
        let audio = sample(&s, "system_audio", 3_002_000_000);
        assert_eq!(screen.segment, 1);
        assert_eq!(screen.file_ns, 2_000_000);
        assert_eq!(audio.file_ns, 800_000);
        assert_eq!(screen.src_ns, audio.src_ns);
        assert_eq!(sample(&s, "system_audio", 3_000_000_000).present, 0);
        assert_eq!(sample(&s, "screen", 5_000_000_000).present, 0);
    }
}
