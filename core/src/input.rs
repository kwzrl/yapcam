//! Immutable cold-path event indexes for allocation-free binary-search evaluation.
use crate::model::Event;
use std::sync::Arc;
#[derive(Clone, Copy, Debug)]
pub struct Point {
    pub t: i64,
    pub x: f64,
    pub y: f64,
}
#[derive(Clone, Default)]
pub struct InputCache {
    pub mouse_data: bool,
    pub positions: Arc<Vec<Point>>,
    pub cursors: Arc<Vec<(i64, u32)>>,
    pub steady_positions: Arc<Vec<Point>>,
    pub steady_move_times: Arc<Vec<i64>>,
    pub stable_cursors: Arc<Vec<(i64, u32)>>,
    pub clicks: Arc<Vec<Point>>,
    pub click_has_position: Arc<Vec<bool>>,
    pub shake_threshold: f64,
}
impl InputCache {
    #[cfg(test)]
    pub fn new(events: &[Event]) -> Self {
        Self::with_events(events, 500.0)
    }
    pub fn with_events(events: &[Event], shake_threshold: f64) -> Self {
        let mut cache = Self::default();
        let mut positions = Vec::new();
        let mut cursors = Vec::new();
        let mut clicks = Vec::new();
        let mut click_has_position = Vec::new();
        let mut last = (0.0, 0.0);
        let mut has_position = false;
        for e in events {
            cache.mouse_data |= matches!(e.kind.as_str(), "move" | "down" | "up" | "cursor");
            if let (Some(x), Some(y)) = (e.x, e.y) {
                last = (x, y);
                has_position = true;
                positions.push(Point { t: e.t, x, y });
            }
            if e.kind == "cursor" {
                if let Some(id) = e.id {
                    cursors.push((e.t, id));
                }
            }
            if e.kind == "down" {
                click_has_position.push(has_position);
                clicks.push(Point {
                    t: e.t,
                    x: e.x.unwrap_or(last.0),
                    y: e.y.unwrap_or(last.1),
                });
            }
        }
        cache.positions = Arc::new(positions);
        cache.cursors = Arc::new(cursors);
        cache.clicks = Arc::new(clicks);
        cache.click_has_position = Arc::new(click_has_position);
        let mut stable_cursors = Vec::new();
        if let Some(&(t, id)) = cache.cursors.first() {
            stable_cursors.push((t, id));
            let mut stable_id = id;
            let mut i = 1;
            while i < cache.cursors.len() {
                let (t, id) = cache.cursors[i];
                let mut next = i + 1;
                while next < cache.cursors.len() && cache.cursors[next].1 == id {
                    next += 1;
                }
                let confirm = t.saturating_add(80_000_000);
                if id != stable_id && cache.cursors.get(next).is_none_or(|e| e.0 >= confirm) {
                    stable_cursors.push((confirm, id));
                    stable_id = id;
                }
                i = next;
            }
        }
        cache.stable_cursors = Arc::new(stable_cursors);
        cache.with_threshold(shake_threshold)
    }
    /// Reuse immutable recorded indexes; rebuild only the positional deadband.
    /// Called while staging an edit/history change, never from the frame path.
    pub fn with_threshold(&self, threshold: f64) -> Self {
        let mut next = self.clone();
        if self.shake_threshold == threshold {
            return next;
        }
        let mut positions = Vec::new();
        let mut move_times = Vec::new();
        if let Some(mut anchor) = self.positions.first().copied() {
            positions.push(anchor);
            move_times.push(anchor.t);
            let mut previous = anchor;
            let threshold_squared = (threshold / 1000.0).powi(2);
            for &point in self.positions.iter() {
                let dx = point.x - anchor.x;
                let dy = point.y - anchor.y;
                if dx * dx + dy * dy >= threshold_squared {
                    // Keep the last held sample before each accepted movement:
                    // interpolation must not begin earlier than in the dense trace.
                    if positions.last().unwrap().t != previous.t {
                        positions.push(Point {
                            t: previous.t,
                            ..anchor
                        });
                        move_times.push(anchor.t);
                    }
                    anchor = point;
                    positions.push(anchor);
                    move_times.push(anchor.t);
                }
                previous = point;
            }
        }
        next.steady_positions = Arc::new(positions);
        next.steady_move_times = Arc::new(move_times);
        next.shake_threshold = threshold;
        next
    }
    pub fn position(&self, t: i64) -> Option<Point> {
        Self::position_from(&self.positions, t)
    }
    pub fn position_filtered(&self, t: i64, steady: bool) -> Option<Point> {
        if !steady {
            return self.position(t);
        }
        let mut point = Self::position_from(&self.steady_positions, t)?;
        let i = self.steady_positions.partition_point(|p| p.t <= t);
        point.t = self.steady_move_times[i - 1];
        Some(point)
    }
    pub fn positions_filtered(&self, steady: bool) -> &[Point] {
        if steady {
            &self.steady_positions
        } else {
            &self.positions
        }
    }
    fn position_from(positions: &[Point], t: i64) -> Option<Point> {
        let i = positions.partition_point(|p| p.t <= t);
        let previous = *positions.get(i.checked_sub(1)?)?;
        if let Some(next) = positions.get(i) {
            let k = (t - previous.t) as f64 / (next.t - previous.t) as f64;
            Some(Point {
                t: previous.t,
                x: previous.x + (next.x - previous.x) * k,
                y: previous.y + (next.y - previous.y) * k,
            })
        } else {
            Some(previous)
        }
    }
    pub fn cursor(&self, t: i64) -> u32 {
        let i = self.cursors.partition_point(|e| e.0 <= t);
        i.checked_sub(1).map_or(0, |i| self.cursors[i].1)
    }
    pub fn cursor_filtered(&self, t: i64, optimize: bool) -> u32 {
        if !optimize {
            return self.cursor(t);
        }
        let i = self.stable_cursors.partition_point(|e| e.0 <= t);
        i.checked_sub(1).map_or(0, |i| self.stable_cursors[i].1)
    }
    pub fn click(&self, t: i64) -> Option<Point> {
        let i = self.clicks.partition_point(|e| e.t <= t);
        self.clicks.get(i.checked_sub(1)?).copied()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn compact_deadband_matches_dense_interpolation_and_idle_clocks_at_every_boundary() {
        // Duplicate clocks, holds, reversals and threshold-equal displacements.
        let events: Vec<_> = (0..1000)
            .map(|i| Event {
                t: i / 2 * 1_000_000,
                kind: "move".into(),
                x: Some(100.0 + (i % 17) as f64 * 0.125),
                y: Some(100.0 + (i % 13) as f64 * 0.125),
                id: None,
                details: Default::default(),
            })
            .collect();
        for threshold in [100.0, 500.0, 1000.0, 1500.0, 2000.0] {
            let cache = InputCache::with_events(&events, threshold);
            let mut dense = Vec::new();
            let mut clocks = Vec::new();
            let mut anchor = *cache.positions.first().unwrap();
            for &point in cache.positions.iter() {
                if (point.x - anchor.x).hypot(point.y - anchor.y) >= threshold / 1000.0 {
                    anchor = point;
                }
                dense.push(Point {
                    x: anchor.x,
                    y: anchor.y,
                    ..point
                });
                clocks.push(anchor.t);
            }
            assert!(cache.steady_positions.len() <= dense.len());
            for t in (0..501_000_000).step_by(250_000) {
                let got = cache.position_filtered(t, true).unwrap();
                let mut expected = InputCache::position_from(&dense, t).unwrap();
                expected.t = clocks[dense.partition_point(|p| p.t <= t) - 1];
                assert!(
                    (got.x - expected.x).abs() < 1e-12 && (got.y - expected.y).abs() < 1e-12,
                    "threshold={threshold} time={t}"
                );
                assert_eq!(got.t, expected.t, "threshold={threshold} time={t}");
            }
        }
    }
}
