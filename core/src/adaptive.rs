//! Pure composition policies. No seek state, IO, allocations or source-crop expansion.
use crate::{
    frame::{Frame, Rect},
    model::ProjectData,
    project::Project,
};
fn clamp(v: f64, low: f64, high: f64) -> f64 {
    v.max(low).min(high.max(low))
}
fn contains(r: Rect, x: f64, y: f64, margin: f64) -> bool {
    x >= r.x - margin && y >= r.y - margin && x <= r.x + r.w + margin && y <= r.y + r.h + margin
}
fn overlaps(a: Rect, b: Rect) -> bool {
    a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

pub(crate) fn fill_zoom_region(p: &Project, f: &mut Frame, region: Rect) {
    if !p.data.canvas.avoid_empty_zoom_area || f.screen.present == 0 {
        return;
    }
    let Some(z) = crate::zoom_lens::active(p, f.tl_ns, p.capabilities().can_auto_zoom)
        .filter(|z| z.style == "classic")
    else {
        return;
    };
    let k = crate::zoom_lens::weight(p, z, f.tl_ns).clamp(0.0, 1.0);
    let d = f.screen_dest;
    let dest = Rect {
        x: d.x + (region.x - d.x) * k,
        y: d.y + (region.y - d.y) * k,
        w: d.w + (region.w - d.w) * k,
        h: d.h + (region.h - d.h) * k,
    };
    if dest.w <= 0.0 || dest.h <= 0.0 {
        return;
    }
    let source = p.session.tracks.screen.pixel_size;
    let ratio = dest.w / dest.h / (source[0] as f64 / source[1] as f64);
    let old = f.screen_crop;
    let w = old.w.min(old.h * ratio);
    let h = old.h.min(w / ratio);
    f.screen_crop = Rect {
        x: old.x + (old.w - w) / 2.0,
        y: old.y + (old.h - h) / 2.0,
        w,
        h,
    };
    f.screen_dest = dest;
}

/// Return true only when the crop changed and cursor projection needs recomputing.
pub(crate) fn smart_framing(p: &Project, f: &mut Frame, permit_crop: bool) -> bool {
    if !p.data.zoom_settings.smart_framing
        || f.screen.present == 0
        || f.camera.present == 0
        || f.camera_opacity <= 0.0
        || f.cursor_visible == 0
    {
        return false;
    }
    let (mode, _) = crate::camera_layout::current(&p.data, f.tl_ns);
    if !matches!(mode, "overlay" | "cutout") {
        return false;
    }
    let Some(z) = crate::zoom_lens::active(p, f.tl_ns, p.capabilities().can_auto_zoom)
        .filter(|z| z.mode == "auto")
    else {
        return false;
    };
    let margin = 12.0_f64.min(f.screen_dest.w.min(f.screen_dest.h) / 16.0);
    let camera = f.camera_dest;
    if !contains(camera, f.cursor_x, f.cursor_y, margin) {
        return false;
    }
    if permit_crop && z.style == "classic" {
        let crop = f.screen_crop;
        let d = f.screen_dest;
        let point = [
            crop.x + (f.cursor_x - d.x) / d.w * crop.w,
            crop.y + (f.cursor_y - d.y) / d.h * crop.h,
        ];
        let bounds = if p.capabilities().can_crop {
            p.data.canvas.crop
        } else {
            [0.0, 0.0, 1.0, 1.0]
        };
        let mut best = None;
        let mut score = f64::INFINITY;
        for (cx, cy) in [
            (camera.x - margin - 1.0, f.cursor_y),
            (camera.x + camera.w + margin + 1.0, f.cursor_y),
            (f.cursor_x, camera.y - margin - 1.0),
            (f.cursor_x, camera.y + camera.h + margin + 1.0),
        ] {
            let x = clamp(
                point[0] - (cx - d.x) / d.w * crop.w,
                bounds[0],
                bounds[0] + bounds[2] - crop.w,
            );
            let y = clamp(
                point[1] - (cy - d.y) / d.h * crop.h,
                bounds[1],
                bounds[1] + bounds[3] - crop.h,
            );
            let px = d.x + (point[0] - x) / crop.w * d.w;
            let py = d.y + (point[1] - y) / crop.h * d.h;
            let cost = (x - crop.x).powi(2) + (y - crop.y).powi(2);
            if contains(d, px, py, -margin) && !contains(camera, px, py, margin) && cost < score {
                score = cost;
                best = Some((x, y));
            }
        }
        if let Some((x, y)) = best {
            f.screen_crop.x = x;
            f.screen_crop.y = y;
            return true;
        }
    }
    // At a source edge a crop shift cannot help. Keep the camera on the canvas,
    // choosing the closest clear corner. Oversized custom cameras shrink last.
    let width = f.canvas_w as f64;
    let height = f.canvas_h as f64;
    let gap = camera
        .x
        .min(camera.y)
        .min(width - camera.x - camera.w)
        .min(height - camera.y - camera.h)
        .max(0.0);
    for scale in [1.0, 0.75, 0.5, 0.25] {
        let w = camera.w * scale;
        let h = camera.h * scale;
        let mut best = None;
        let mut score = f64::INFINITY;
        for (x, y) in [
            (gap, gap),
            (width - gap - w, gap),
            (gap, height - gap - h),
            (width - gap - w, height - gap - h),
        ] {
            let r = Rect { x, y, w, h };
            let cost = (camera.x - x).powi(2) + (camera.y - y).powi(2);
            if !contains(r, f.cursor_x, f.cursor_y, margin) && cost < score {
                score = cost;
                best = Some(r);
            }
        }
        if let Some(r) = best {
            f.camera_dest = r;
            f.camera_corner_radius *= scale as f32;
            break;
        }
    }
    false
}

fn place_text(p: &ProjectData, mut r: Rect, f: &Frame, shortcut: bool) -> Rect {
    if !p.canvas.auto_layout {
        return r;
    }
    let w = f.canvas_w as f64;
    let h = f.canvas_h as f64;
    let gap = 12.0_f64.min(w / 30.0);
    if w < h {
        r.w = if shortcut { w * 0.8 } else { w * 0.88 };
        r.x = (w - r.w) / 2.0;
        r.h = r.h.min(h * 0.2);
        r.y = if shortcut {
            h * 0.88
        } else {
            r.y.min(h * 0.76)
        };
    }
    r.w = r.w.max(1.0).min(w - 2.0 * gap);
    r.h = r.h.max(1.0).min(h - 2.0 * gap);
    r.x = clamp(r.x, gap, w - gap - r.w);
    r.y = clamp(r.y, gap, h - gap - r.h);
    if f.camera.present == 0 || f.camera_opacity <= 0.0 || !overlaps(r, f.camera_dest) {
        return r;
    }
    let c = f.camera_dest;
    let spaces = [
        Rect {
            x: gap,
            y: gap,
            w: c.x - 2.0 * gap,
            h: h - 2.0 * gap,
        },
        Rect {
            x: c.x + c.w + gap,
            y: gap,
            w: w - c.x - c.w - 2.0 * gap,
            h: h - 2.0 * gap,
        },
        Rect {
            x: gap,
            y: gap,
            w: w - 2.0 * gap,
            h: c.y - 2.0 * gap,
        },
        Rect {
            x: gap,
            y: c.y + c.h + gap,
            w: w - 2.0 * gap,
            h: h - c.y - c.h - 2.0 * gap,
        },
    ];
    let mut best = r;
    let mut score = f64::INFINITY;
    for area in spaces {
        if area.w < 80.0_f64.min(w * 0.25) || area.h < r.h {
            continue;
        }
        let width = r.w.min(area.w);
        let candidate = Rect {
            x: clamp(r.x, area.x, area.x + area.w - width),
            y: clamp(r.y, area.y, area.y + area.h - r.h),
            w: width,
            h: r.h,
        };
        let cost = (candidate.x - r.x).powi(2)
            + (candidate.y - r.y).powi(2)
            + (candidate.w - r.w).powi(2) * 0.25;
        if cost < score {
            score = cost;
            best = candidate;
        }
    }
    best
}
pub(crate) fn text_rect(p: &ProjectData, rect: Rect, f: &Frame, shortcut: bool) -> Rect {
    let r = place_text(p, rect, f, shortcut);
    if !shortcut || !p.canvas.auto_layout {
        return r;
    }
    let w = f.canvas_w as f64;
    let h = f.canvas_h as f64;
    let gap = 12.0_f64.min(w / 30.0);
    let active = |caption: &&crate::model::TextRecord| {
        caption.space == "canvas" && f.tl_ns >= caption.tl_start_ns && f.tl_ns < caption.tl_end_ns
    };
    let caption_rect = |caption: &crate::model::TextRecord| {
        let a = caption.rect;
        place_text(
            p,
            Rect {
                x: a[0] * w,
                y: a[1] * h,
                w: a[2] * w,
                h: a[3] * h,
            },
            f,
            false,
        )
    };
    // Choosing a position around a caption must also respect the camera; moving
    // straight upward can reintroduce the overlap place_text already removed.
    let clear = |candidate: Rect| {
        (f.camera.present == 0 || f.camera_opacity <= 0.0 || !overlaps(candidate, f.camera_dest))
            && p.canvas
                .captions
                .iter()
                .filter(active)
                .all(|c| !overlaps(candidate, caption_rect(c)))
    };
    if clear(r) {
        return r;
    }
    let mut best = r;
    let mut score = f64::INFINITY;
    for caption in p.canvas.captions.iter().filter(active) {
        let occupied = caption_rect(caption);
        let camera = f.camera_dest;
        let xs = [
            r.x,
            gap,
            w - gap - r.w,
            camera.x - gap - r.w,
            camera.x + camera.w + gap,
            occupied.x - gap - r.w,
            occupied.x + occupied.w + gap,
        ];
        let ys = [
            r.y,
            gap,
            h - gap - r.h,
            camera.y - gap - r.h,
            camera.y + camera.h + gap,
            occupied.y - gap - r.h,
            occupied.y + occupied.h + gap,
        ];
        for x in xs {
            for y in ys {
                let candidate = Rect {
                    x: clamp(x, gap, w - gap - r.w),
                    y: clamp(y, gap, h - gap - r.h),
                    ..r
                };
                let cost = (candidate.x - r.x).powi(2) + (candidate.y - r.y).powi(2);
                if cost < score && clear(candidate) {
                    score = cost;
                    best = candidate;
                }
            }
        }
    }
    best
}
