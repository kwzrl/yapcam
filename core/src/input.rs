//! Immutable cold-path event indexes for allocation-free binary-search evaluation.
use crate::model::Event;
#[derive(Clone, Copy, Debug)]
pub struct Point {
    pub t: i64,
    pub x: f64,
    pub y: f64,
}
#[derive(Clone, Default)]
pub struct InputCache {
    pub positions: Vec<Point>,
    pub cursors: Vec<(i64, u32)>,
    pub steady_positions: Vec<Point>,
    pub steady_move_times: Vec<i64>,
    pub stable_cursors: Vec<(i64, u32)>,
    pub clicks: Vec<Point>,
    pub click_has_position: Vec<bool>,
}
impl InputCache {
    pub fn new(events: &[Event]) -> Self {
        let mut cache = Self::default();
        let mut last = (0.0, 0.0);
        let mut has_position = false;
        for e in events {
            if let (Some(x), Some(y)) = (e.x, e.y) {
                last = (x, y);
                has_position = true;
                cache.positions.push(Point { t: e.t, x, y });
            }
            if e.kind == "cursor" {
                if let Some(id) = e.id {
                    cache.cursors.push((e.t, id));
                }
            }
            if e.kind == "down" {
                cache.click_has_position.push(has_position);
                cache.clicks.push(Point {
                    t: e.t,
                    x: e.x.unwrap_or(last.0),
                    y: e.y.unwrap_or(last.1),
                });
            }
        }
        if let Some(first) = cache.positions.first().copied() {
            let mut anchor = first;
            for &point in &cache.positions {
                if (point.x - anchor.x).hypot(point.y - anchor.y) >= 1.0 {
                    anchor = point;
                }
                cache.steady_positions.push(Point {
                    x: anchor.x,
                    y: anchor.y,
                    ..point
                });
                cache.steady_move_times.push(anchor.t);
            }
        }
        if let Some(&(t, id)) = cache.cursors.first() {
            cache.stable_cursors.push((t, id));
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
                    cache.stable_cursors.push((confirm, id));
                    stable_id = id;
                }
                i = next;
            }
        }
        cache
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
