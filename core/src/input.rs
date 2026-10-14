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
    pub clicks: Vec<Point>,
}
impl InputCache {
    pub fn new(events: &[Event]) -> Self {
        let mut cache = Self::default();
        let mut last = (0.0, 0.0);
        for e in events {
            if let (Some(x), Some(y)) = (e.x, e.y) {
                last = (x, y);
                cache.positions.push(Point { t: e.t, x, y });
            }
            if e.kind == "cursor" {
                if let Some(id) = e.id {
                    cache.cursors.push((e.t, id));
                }
            }
            if e.kind == "down" {
                cache.clicks.push(Point {
                    t: e.t,
                    x: e.x.unwrap_or(last.0),
                    y: e.y.unwrap_or(last.1),
                });
            }
        }
        cache
    }
    pub fn position(&self, t: i64) -> Option<Point> {
        let i = self.positions.partition_point(|p| p.t <= t);
        let previous = *self.positions.get(i.checked_sub(1)?)?;
        if let Some(next) = self.positions.get(i) {
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
    pub fn click(&self, t: i64) -> Option<Point> {
        let i = self.clicks.partition_point(|e| e.t <= t);
        self.clicks.get(i.checked_sub(1)?).copied()
    }
}
