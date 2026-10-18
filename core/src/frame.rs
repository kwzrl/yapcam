//! Stateless evaluation: preview, seek, and offline export produce identical frames.
//! The successful evaluation path performs no heap allocation or file access.
use crate::{
    model::Cursor,
    project::{Error, Project, Result},
    time::{self, Sample},
};
#[derive(Clone, Copy, Debug, Default, PartialEq)]
#[repr(C)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}
#[derive(Clone, Copy, Debug, Default)]
#[repr(C)]
pub struct Frame {
    pub tl_ns: i64,
    pub canvas_w: u32,
    pub canvas_h: u32,
    pub background_kind: u32,
    pub background_color: [f32; 4],
    pub background_color2: [f32; 4],
    pub background_angle_deg: f32,
    pub background_asset: u32,
    pub background_blur: f32,
    pub screen: Sample,
    pub screen_crop: Rect,
    pub screen_dest: Rect,
    pub screen_corner_radius: f32,
    pub shadow_radius: f32,
    pub shadow_opacity: f32,
    pub shadow_offset_y: f32,
    pub inset_width: f32,
    pub inset_color: [f32; 4],
    pub motion_blur: f32,
    pub cursor_visible: u8,
    pub cursor_x: f64,
    pub cursor_y: f64,
    pub cursor_scale: f32,
    pub cursor_id: u32,
    pub cursor_opacity: f32,
    pub click_progress: f32,
    pub click_x: f64,
    pub click_y: f64,
    pub camera: Sample,
    pub camera_dest: Rect,
    pub camera_corner_radius: f32,
    pub camera_shape: u32,
    pub camera_opacity: f32,
    pub camera_mirror: u8,
    pub mic_gain: f32,
    pub system_gain: f32,
}

/// Ripple renders three rings whose starts are separated by 70 ms. The stored
/// click duration remains the lifetime of each ring; the evaluated frame clock
/// spans the two additional delays so the last ring can finish.
pub(crate) fn click_effect_duration_ns(defaults_revision: u32, cursor: &Cursor) -> i64 {
    if defaults_revision >= 4 && cursor.click_effect == "highlight" {
        cursor.click_duration_ns.saturating_add(140_000_000)
    } else {
        cursor.click_duration_ns
    }
}
fn fit(area: Rect, aspect: f64) -> Rect {
    let w = area.w.min(area.h * aspect).max(0.0);
    let h = (w / aspect).min(area.h);
    Rect {
        x: area.x + (area.w - w) / 2.0,
        y: area.y + (area.h - h) / 2.0,
        w,
        h,
    }
}
// Derived bounds can be inverted by one ulp (e.g. 0.1+0.7-0.7). Geometry
// clamping must never use f64::clamp's panicking min<=max precondition.
fn coordinate(value: f64, low: f64, high: f64) -> f64 {
    value.max(low).min(high.max(low))
}
fn ease(t: f64) -> f64 {
    let t = t.clamp(0.0, 1.0);
    t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
}
#[cfg(test)]
fn spring(t: f64) -> f64 {
    let t = ease(t);
    let k: f64 = 6.0;
    (1.0 - (1.0 + k * t) * (-k * t).exp()) / (1.0 - (1.0 + k) * (-k).exp())
}
fn follow_pan(mut rect: Rect, point: [f64; 2], d: f64, bounds: Rect) -> Rect {
    if point[0] < rect.x + rect.w * d {
        rect.x = point[0] - rect.w * d;
    } else if point[0] > rect.x + rect.w * (1.0 - d) {
        rect.x = point[0] - rect.w * (1.0 - d);
    }
    if point[1] < rect.y + rect.h * d {
        rect.y = point[1] - rect.h * d;
    } else if point[1] > rect.y + rect.h * (1.0 - d) {
        rect.y = point[1] - rect.h * (1.0 - d);
    }
    rect.x = coordinate(rect.x, bounds.x, bounds.x + (bounds.w - rect.w).max(0.0));
    rect.y = coordinate(rect.y, bounds.y, bounds.y + (bounds.h - rect.h).max(0.0));
    rect
}
#[derive(Clone, Copy)]
struct CameraLayoutGeometry {
    screen_dest: Rect,
    camera_dest: Rect,
    camera_corner_radius: f32,
    screen_visible: bool,
    camera_visible: bool,
    camera_opacity: f32,
}
#[derive(Clone, Copy)]
struct CameraLayoutContext {
    canvas: Rect,
    area: Rect,
    pad: f64,
    source_aspect: f64,
    camera_aspect: f64,
    zoom_camera_factor: f64,
    can_camera: bool,
    has_camera: bool,
}
fn camera_layout_geometry(
    p: &crate::model::ProjectData,
    tl: i64,
    context: &CameraLayoutContext,
) -> CameraLayoutGeometry {
    let CameraLayoutContext {
        canvas,
        area,
        pad,
        source_aspect,
        camera_aspect,
        zoom_camera_factor,
        can_camera,
        has_camera,
    } = *context;
    let (mode, settings) = crate::camera_layout::current(p, tl);
    let mut position = p.camera.position;
    let mut size = p.camera.size;
    if let Some(layout) = p
        .camera
        .layouts
        .iter()
        .filter(|layout| layout.enabled && tl >= layout.tl_start_ns && tl < layout.tl_end_ns)
        .max_by_key(|layout| layout.tl_start_ns)
    {
        position = layout.camera_position.unwrap_or(position);
        size = layout.camera_size.unwrap_or(size);
    }
    if mode == "cutout" {
        position = settings.cutout_position;
        size = settings.cutout_size;
    }
    let camera_visible = can_camera
        && has_camera
        && p.camera.visible
        && !crate::camera_layout::hidden_by_silence(p, tl)
        && mode != "screen";
    let mut screen_dest = fit(area, source_aspect);
    let mut camera_dest = Rect::default();
    match mode {
        "camera" if camera_visible => {
            camera_dest = if p.defaults_revision >= 4 {
                canvas
            } else {
                fit(area, camera_aspect)
            }
        }
        "side_by_side" if camera_visible => {
            screen_dest = fit(
                Rect {
                    w: area.w * 0.65,
                    ..area
                },
                source_aspect,
            );
            camera_dest = fit(
                Rect {
                    x: area.x + area.w * 0.68,
                    w: area.w * 0.32,
                    ..area
                },
                camera_aspect,
            );
        }
        "split" if camera_visible => {
            let region = if settings.split_padded { area } else { canvas };
            let horizontal = match settings.split_direction.as_str() {
                "horizontal" => true,
                "vertical" => false,
                _ => canvas.w >= canvas.h,
            };
            let automatic = if horizontal {
                source_aspect / (source_aspect + camera_aspect)
            } else {
                camera_aspect / (source_aspect + camera_aspect)
            };
            let ratio = settings.split_ratio.unwrap_or(automatic.clamp(0.25, 0.75));
            let (screen_region, camera_region) =
                crate::camera_layout::split_regions(region, ratio, horizontal, settings.split_flip);
            screen_dest = fit(screen_region, source_aspect);
            camera_dest = fit(camera_region, camera_aspect);
        }
        _ => {}
    }
    if camera_dest.w == 0.0 {
        let edge = settings.edge_padding_ratio * pad;
        let width = (canvas.w * size * zoom_camera_factor)
            .min((canvas.w - 2.0 * edge).max(0.0))
            .min((canvas.h - 2.0 * edge).max(0.0) * camera_aspect);
        let height = (width / camera_aspect).min(canvas.h);
        camera_dest = Rect {
            x: coordinate(
                canvas.w * position[0] - width / 2.0,
                edge,
                canvas.w - edge - width,
            ),
            y: coordinate(
                canvas.h * position[1] - height / 2.0,
                edge,
                canvas.h - edge - height,
            ),
            w: width,
            h: height,
        };
    }
    let camera_corner_radius = if mode == "cutout"
        || mode == "split" && !settings.split_padded
        || p.defaults_revision >= 4 && mode == "camera"
    {
        0.0
    } else if let Some(ratio) = settings.corner_ratio {
        (camera_dest.w.min(camera_dest.h) * ratio) as f32
    } else {
        p.camera.radius as f32
    };
    CameraLayoutGeometry {
        screen_dest,
        camera_dest,
        camera_corner_radius,
        screen_visible: !(mode == "camera" && camera_visible),
        camera_visible,
        camera_opacity: if camera_visible {
            p.camera.opacity as f32
        } else {
            0.0
        },
    }
}
fn layout_boundaries(p: &crate::model::ProjectData) -> impl Iterator<Item = i64> + '_ {
    p.camera
        .layouts
        .iter()
        .filter(|layout| layout.enabled)
        .flat_map(|layout| [layout.tl_start_ns, layout.tl_end_ns])
        .chain(
            p.camera
                .silence_ranges
                .iter()
                .filter(|_| p.camera.hide_during_silence)
                .flat_map(|range| [range.tl_start_ns, range.tl_end_ns]),
        )
}
fn layout_transition(p: &crate::model::ProjectData, tl: i64, duration: i64) -> Option<(i64, f64)> {
    if p.defaults_revision < 4 {
        return None;
    }
    let mut selected = None;
    for boundary in layout_boundaries(p).filter(|t| *t > 0 && *t < duration) {
        let previous = layout_boundaries(p)
            .filter(|other| *other < boundary)
            .max()
            .unwrap_or(0);
        let next = layout_boundaries(p)
            .filter(|other| *other > boundary)
            .min()
            .unwrap_or(duration);
        let cut = p.timeline.clips.iter().enumerate().skip(1).any(|(i, _)| {
            crate::time::clip_bounds(&p.timeline.clips, i)
                .is_some_and(|bounds| bounds.0 == boundary)
        });
        let left = if cut {
            0
        } else {
            175_000_000_i64.min((boundary - previous) / 2)
        };
        let right = if cut {
            350_000_000_i64.min((next - boundary) / 2)
        } else {
            175_000_000_i64.min((next - boundary) / 2)
        };
        if (!cut && tl <= boundary - left) || tl >= boundary + right || left + right == 0 {
            continue;
        }
        let progress = ease((tl - (boundary - left)) as f64 / (left + right) as f64);
        if selected.is_none_or(|(old, _)| tl.abs_diff(boundary) < tl.abs_diff(old)) {
            selected = Some((boundary, progress));
        }
    }
    selected
}
fn blend_rect(a: Rect, b: Rect, amount: f64) -> Rect {
    Rect {
        x: a.x + (b.x - a.x) * amount,
        y: a.y + (b.y - a.y) * amount,
        w: a.w + (b.w - a.w) * amount,
        h: a.h + (b.h - a.h) * amount,
    }
}
fn scaled_rect(rect: Rect, scale: f64) -> Rect {
    Rect {
        x: rect.x + rect.w * (1.0 - scale) / 2.0,
        y: rect.y + rect.h * (1.0 - scale) / 2.0,
        w: rect.w * scale,
        h: rect.h * scale,
    }
}
pub(crate) fn camera_layout_transition_effects(project: &Project, tl: i64) -> (f64, f64) {
    let p = &project.data;
    let visibility = |t| {
        let mode = crate::camera_layout::current(p, t).0;
        let camera = project.capabilities().can_camera
            && project.session.tracks.camera.is_some()
            && p.camera.visible
            && !crate::camera_layout::hidden_by_silence(p, t)
            && mode != "screen";
        let screen = !(mode == "camera" && camera);
        (screen, camera)
    };
    let duration = crate::time::duration(&p.timeline.clips);
    if let Some((boundary, amount)) = layout_transition(p, tl, duration) {
        let before = visibility(boundary - 1);
        let after = visibility(boundary);
        let screen =
            before.0 as u8 as f64 + (after.0 as u8 as f64 - before.0 as u8 as f64) * amount;
        let blur_before = (!before.1) as u8 as f64;
        let blur_after = (!after.1) as u8 as f64;
        return (screen, blur_before + (blur_after - blur_before) * amount);
    }
    let current = visibility(tl);
    (current.0 as u8 as f64, (!current.1) as u8 as f64)
}
impl Project {
    pub fn frame(&self, tl_ns: i64) -> Result<Frame> {
        let mut frame = self.frame_geometry(tl_ns)?;
        let c = &self.data.canvas;
        if tl_ns > 0
            && (c.motion_blur_settings.zoom.unwrap_or(c.motion_blur) > 0.0
                || c.motion_blur_settings.pan.unwrap_or(c.motion_blur) > 0.0)
            && self.same_motion_clip(tl_ns)
        {
            let prior = self.frame_geometry(tl_ns.saturating_sub(16_666_667).max(0))?;
            let (zoom, pan) = crate::motion::screen_blurs(c, &frame, &prior);
            frame.motion_blur = zoom.max(pan);
        } else {
            frame.motion_blur = 0.0;
        }
        Ok(frame)
    }
    pub(crate) fn frame_geometry(&self, tl_ns: i64) -> Result<Frame> {
        let (clip_i, src) = time::timeline_to_source(&self.data.timeline.clips, tl_ns)
            .ok_or_else(|| Error::new(1, "Frame time outside timeline"))?;
        let p = &self.data;
        let c = &p.canvas;
        let capabilities = self.capabilities();
        let crop = if capabilities.can_crop {
            c.crop
        } else {
            [0.0, 0.0, 1.0, 1.0]
        };
        let pixels = self.session.tracks.screen.pixel_size;
        let source_aspect = pixels[0] as f64 / pixels[1] as f64 * crop[2] / crop[3];
        let aspect = match c.aspect.as_str() {
            "source" => source_aspect,
            "custom" => c.output_size[0] as f64 / c.output_size[1] as f64,
            s => {
                let mut parts = s.split(':');
                let w: f64 = parts.next().and_then(|v| v.parse().ok()).unwrap_or(16.0);
                let h: f64 = parts.next().and_then(|v| v.parse().ok()).unwrap_or(9.0);
                w / h
            }
        };
        let height = c.output_size[1];
        let width = (height as f64 * aspect).round().clamp(1.0, 16384.0) as u32;
        let canvas = Rect {
            x: 0.0,
            y: 0.0,
            w: width as f64,
            h: height as f64,
        };
        let pad = c
            .padding_ratio
            .map_or(c.padding, |ratio| ratio * canvas.w.min(canvas.h))
            .min((canvas.w.min(canvas.h) - 2.0).max(0.0) / 2.0);
        let area = Rect {
            x: pad,
            y: pad,
            w: canvas.w - 2.0 * pad,
            h: canvas.h - 2.0 * pad,
        };
        let mut frame = Frame {
            tl_ns,
            canvas_w: width,
            canvas_h: height,
            background_kind: match c.background.kind.as_str() {
                "gradient" => 1,
                "image" => 2,
                "blurred_screen" => 3,
                _ => 0,
            },
            background_color: c.background.color,
            background_color2: c.background.color2,
            background_angle_deg: c.background.angle_deg.rem_euclid(360.0) as f32,
            background_asset: c.background.asset,
            background_blur: c.background.blur as f32,
            screen: time::sample(&self.session, "screen", src),
            screen_crop: Rect {
                x: crop[0],
                y: crop[1],
                w: crop[2],
                h: crop[3],
            },
            screen_dest: fit(area, source_aspect),
            screen_corner_radius: if capabilities.can_round_corners {
                c.radius as f32
            } else {
                0.0
            },
            shadow_radius: c.shadow.evaluated().2 as f32,
            shadow_opacity: c.shadow.opacity as f32,
            shadow_offset_y: c.shadow.evaluated().1 as f32,
            inset_width: if capabilities.can_inset {
                c.inset as f32
            } else {
                0.0
            },
            inset_color: c.inset_color,
            click_progress: -1.0,
            camera: time::sample(&self.session, "camera", src),
            camera_corner_radius: p.camera.radius as f32,
            camera_shape: match p.camera.shape.as_str() {
                "circle" => 1,
                "squircle" => 2,
                _ => 0,
            },
            camera_opacity: p.camera.opacity as f32,
            camera_mirror: p.camera.mirrored as u8,
            mic_gain: if p.audio.mic_muted {
                0.0
            } else {
                10.0f64.powf(p.audio.mic_gain_db / 20.0) as f32
            },
            system_gain: if p.audio.system_muted {
                0.0
            } else {
                10.0f64.powf(p.audio.system_gain_db / 20.0) as f32
            },
            ..Frame::default()
        };
        let mut zoom_camera_factor = 1.0;
        if let Some(z) = crate::zoom_lens::active(self, tl_ns, capabilities.can_auto_zoom) {
            let settings = &p.zoom_settings;
            let weight = crate::zoom_lens::weight(self, z, tl_ns);
            zoom_camera_factor = 1.0 + (p.camera.zoom_scale - 1.0) * weight.clamp(0.0, 1.0);
            if z.style == "classic" {
                let physics = crate::motion::zoom_spring(settings);
                let size = 1.0 / (1.0 + (z.scale - 1.0) * weight);
                let w = crop[2] * size;
                let h = crop[3] * size;
                let mut x = coordinate(
                    z.target[0] - w / 2.0,
                    crop[0],
                    crop[0] + (crop[2] - w).max(0.0),
                );
                let mut y = coordinate(
                    z.target[1] - h / 2.0,
                    crop[1],
                    crop[1] + (crop[3] - h).max(0.0),
                );

                if z.mode == "auto" && settings.follow_cursor && frame.screen.present != 0 {
                    let seg = &self.session.segments[frame.screen.segment as usize];
                    let input = &self.input[frame.screen.segment as usize];
                    let local = src - seg.src_start_ns;
                    let base = Rect { x, y, w, h };
                    let bounds = Rect {
                        x: crop[0],
                        y: crop[1],
                        w: crop[2],
                        h: crop[3],
                    };
                    let normalized = |p: crate::input::Point| {
                        [
                            p.x / self.session.source.content_rect_points[2],
                            p.y / self.session.source.content_rect_points[3],
                        ]
                    };
                    if let Some(point) = input.position_filtered(local, p.cursor.remove_shakes) {
                        let mut next =
                            follow_pan(base, normalized(point), settings.dead_zone, bounds);
                        if settings.animation_style != "none" {
                            let settle_seconds = (20.0 * physics.mass / physics.friction)
                                .max(20.0 * physics.friction / physics.tension)
                                .max(2.0);
                            let window = (settle_seconds * 1e9 * p.timeline.clips[clip_i].speed)
                                .round() as i64;
                            let cutoff = local.saturating_sub(window).max(0);
                            if let Some(initial) =
                                input.position_filtered(cutoff, p.cursor.remove_shakes)
                            {
                                let initial = follow_pan(
                                    base,
                                    normalized(initial),
                                    settings.dead_zone,
                                    bounds,
                                );
                                let mut sx = initial.x;
                                let mut sy = initial.y;
                                let mut target = initial;
                                let positions = input.positions_filtered(p.cursor.remove_shakes);
                                let a = positions.partition_point(|p| p.t < cutoff);
                                let b = positions.partition_point(|p| p.t <= local);
                                for &event in &positions[a..b] {
                                    let next_target = follow_pan(
                                        base,
                                        normalized(event),
                                        settings.dead_zone,
                                        bounds,
                                    );
                                    let seconds = (local - event.t) as f64
                                        / 1e9
                                        / p.timeline.clips[clip_i].speed;
                                    let k = crate::spring::response(seconds, &physics);
                                    sx += (next_target.x - target.x) * k;
                                    sy += (next_target.y - target.y) * k;
                                    target = next_target;
                                }
                                next.x = coordinate(
                                    sx,
                                    bounds.x,
                                    bounds.x + (bounds.w - base.w).max(0.0),
                                );
                                next.y = coordinate(
                                    sy,
                                    bounds.y,
                                    bounds.y + (bounds.h - base.h).max(0.0),
                                );
                            }
                        }
                        x = next.x;
                        y = next.y;
                    }
                }
                frame.screen_crop = Rect { x, y, w, h };
            }
        }
        let (layout_mode, layout_settings) = crate::camera_layout::current(p, tl_ns);
        if layout_mode == "cutout" {
            frame.camera_shape = 0;
        }
        let camera_aspect = if frame.camera_shape == 1 {
            1.0
        } else {
            layout_settings.aspect.unwrap_or_else(|| {
                self.session.tracks.camera.as_ref().map_or(1.0, |c| {
                    c.pixel_size[0] as f64 / c.pixel_size[1].max(1) as f64 * p.camera.style.crop[2]
                        / p.camera.style.crop[3]
                })
            })
        };
        // A legal positive crop can have a subnormal width/height. Keep its
        // fitted aspect representable even if the ratio under/overflows.
        let camera_aspect = camera_aspect.clamp(1.0 / 16384.0, 16384.0);
        let mut camera_pos = p.camera.position;
        let mut camera_size = p.camera.size;
        let camera_visible = capabilities.can_camera
            && p.camera.visible
            && !crate::camera_layout::hidden_by_silence(p, tl_ns)
            && layout_mode != "screen";
        if let Some(l) = p
            .camera
            .layouts
            .iter()
            .filter(|l| l.enabled && tl_ns >= l.tl_start_ns && tl_ns < l.tl_end_ns)
            .max_by_key(|l| l.tl_start_ns)
        {
            camera_pos = l.camera_position.unwrap_or(camera_pos);
            camera_size = l.camera_size.unwrap_or(camera_size);
        }
        let mut allocated_screen = area;
        match layout_mode {
            "camera" => {
                if frame.camera.present != 0 && camera_visible {
                    frame.screen.present = 0;
                }
                frame.camera_dest = if p.defaults_revision >= 4 {
                    canvas
                } else {
                    fit(area, camera_aspect)
                };
                if p.defaults_revision >= 4 {
                    frame.camera_corner_radius = 0.0;
                }
            }
            "side_by_side" if frame.camera.present != 0 && camera_visible => {
                frame.screen_dest = fit(
                    Rect {
                        w: area.w * 0.65,
                        ..area
                    },
                    source_aspect,
                );
                frame.camera_dest = fit(
                    Rect {
                        x: area.x + area.w * 0.68,
                        w: area.w * 0.32,
                        ..area
                    },
                    camera_aspect,
                );
            }
            "split" if frame.camera.present != 0 && camera_visible => {
                let region = if layout_settings.split_padded {
                    area
                } else {
                    canvas
                };
                let horizontal = match layout_settings.split_direction.as_str() {
                    "horizontal" => true,
                    "vertical" => false,
                    _ => canvas.w >= canvas.h,
                };
                let auto = if horizontal {
                    source_aspect / (source_aspect + camera_aspect)
                } else {
                    camera_aspect / (source_aspect + camera_aspect)
                };
                let ratio = layout_settings
                    .split_ratio
                    .unwrap_or(auto.clamp(0.25, 0.75));
                let (screen_region, camera_region) = crate::camera_layout::split_regions(
                    region,
                    ratio,
                    horizontal,
                    layout_settings.split_flip,
                );
                allocated_screen = screen_region;
                frame.screen_dest = fit(screen_region, source_aspect);
                frame.camera_dest = fit(camera_region, camera_aspect);
            }
            "cutout" => {
                camera_pos = layout_settings.cutout_position;
                camera_size = layout_settings.cutout_size;
            }
            _ => {}
        }
        if frame.camera_dest.w == 0.0 {
            let edge = layout_settings.edge_padding_ratio * pad;
            let w = (canvas.w * camera_size * zoom_camera_factor)
                .min((canvas.w - 2.0 * edge).max(0.0))
                .min((canvas.h - 2.0 * edge).max(0.0) * camera_aspect);
            let h = (w / camera_aspect).min(canvas.h);
            frame.camera_dest = Rect {
                x: coordinate(
                    canvas.w * camera_pos[0] - w / 2.0,
                    edge,
                    canvas.w - edge - w,
                ),
                y: coordinate(
                    canvas.h * camera_pos[1] - h / 2.0,
                    edge,
                    canvas.h - edge - h,
                ),
                w,
                h,
            };
        }
        if layout_mode == "cutout"
            || layout_mode == "split" && !layout_settings.split_padded
            || p.defaults_revision >= 4 && layout_mode == "camera"
        {
            frame.camera_corner_radius = 0.0;
        } else if let Some(ratio) = layout_settings.corner_ratio {
            frame.camera_corner_radius =
                (frame.camera_dest.w.min(frame.camera_dest.h) * ratio) as f32;
        }
        if !camera_visible {
            frame.camera.present = 0;
            frame.camera_opacity = 0.0;
        }
        let duration = time::duration(&p.timeline.clips);
        if let Some((boundary, amount)) = layout_transition(p, tl_ns, duration) {
            let context = CameraLayoutContext {
                canvas,
                area,
                pad,
                source_aspect,
                camera_aspect,
                zoom_camera_factor,
                can_camera: capabilities.can_camera,
                has_camera: self.session.tracks.camera.is_some(),
            };
            let mut before = camera_layout_geometry(p, boundary - 1, &context);
            let mut after = camera_layout_geometry(p, boundary, &context);
            if before.camera_visible && !after.camera_visible {
                after.camera_dest = scaled_rect(before.camera_dest, 0.85);
            } else if !before.camera_visible && after.camera_visible {
                before.camera_dest = scaled_rect(after.camera_dest, 0.85);
            }
            frame.screen_dest = blend_rect(before.screen_dest, after.screen_dest, amount);
            frame.camera_dest = blend_rect(before.camera_dest, after.camera_dest, amount);
            frame.camera_corner_radius = (before.camera_corner_radius as f64
                + (after.camera_corner_radius - before.camera_corner_radius) as f64 * amount)
                as f32;
            frame.camera_opacity = (before.camera_opacity as f64
                + (after.camera_opacity - before.camera_opacity) as f64 * amount)
                as f32;
            if before.screen_visible || after.screen_visible {
                frame.screen.present = 1;
            }
            if before.camera_visible || after.camera_visible {
                frame.camera.present = 1;
            }
        }
        frame.mic_gain = self.audio_gain_for_clip("mic", tl_ns, Some(clip_i));
        frame.system_gain = self.audio_gain_for_clip("system_audio", tl_ns, Some(clip_i));
        crate::adaptive::fill_zoom_region(self, &mut frame, allocated_screen);
        if frame.screen.present != 0 && capabilities.can_cursor {
            self.cursor_at(&mut frame, src, clip_i);
            if crate::adaptive::smart_framing(self, &mut frame, true) {
                self.cursor_at(&mut frame, src, clip_i);
            }
        }
        crate::layers::animate_frame(
            &mut frame,
            &p.canvas.animation,
            time::duration(&p.timeline.clips),
        );
        if p.cursor.loop_to_start && tl_ns > 0 {
            let duration = time::duration(&p.timeline.clips);
            let window = p.cursor.loop_duration_ns.min(duration);
            let remaining = duration - tl_ns;
            if remaining < window && frame.screen.present != 0 {
                // Re-evaluate only frame zero (which never enters this branch).
                // Return to the actual canvas hotspot, not a source coordinate
                // interpreted through a different final crop or layout.
                let first = self.frame_geometry(0)?;
                let k = ease(1.0 - remaining as f64 / window as f64);
                frame.cursor_x += (first.cursor_x - frame.cursor_x) * k;
                frame.cursor_y += (first.cursor_y - frame.cursor_y) * k;
                // Looping has already chosen the canvas hotspot. Move only the
                // camera if needed; reprojecting the crop would break the loop.
                crate::adaptive::smart_framing(self, &mut frame, false);
            }
        }
        if !p.cursor.loop_to_start && p.cursor.stop_before_end_ns > 0 {
            let stop = time::duration(&p.timeline.clips)
                .saturating_sub(p.cursor.stop_before_end_ns)
                .max(0);
            if tl_ns > stop && frame.screen.present != 0 {
                let frozen = self.frame_geometry(stop)?;
                if frozen.screen.present != 0 {
                    frame.cursor_x = frozen.cursor_x;
                    frame.cursor_y = frozen.cursor_y;
                }
            }
        }
        Ok(frame)
    }
    pub(crate) fn audio_gain_for_clip(&self, track: &str, tl_ns: i64, clip: Option<usize>) -> f32 {
        let a = &self.data.audio;
        let (base, muted) = if track == "mic" {
            (a.mic_gain_db, a.mic_muted)
        } else {
            (a.system_gain_db, a.system_muted)
        };
        if muted {
            return 0.0;
        }
        let envelope = a
            .ranges
            .iter()
            .filter(|r| r.track == track && tl_ns >= r.tl_start_ns && tl_ns < r.tl_end_ns)
            .max_by_key(|r| r.tl_start_ns);
        let db = envelope.map_or(0.0, |r| {
            let k = (tl_ns - r.tl_start_ns) as f64 / (r.tl_end_ns - r.tl_start_ns) as f64;
            r.start_gain_db + (r.end_gain_db - r.start_gain_db) * k
        });
        let gain = clip.map_or(1.0, |i| {
            let s = &self.data.timeline.clips[i].settings;
            if track == "mic" {
                s.mic_gain
            } else {
                s.system_gain
            }
        });
        (10.0f64.powf((base + db) / 20.0) * gain) as f32
    }
    fn cursor_at(&self, f: &mut Frame, src: i64, clip_i: usize) {
        let seg = &self.session.segments[f.screen.segment as usize];
        let input = &self.input[f.screen.segment as usize];
        let local = src - seg.src_start_ns;
        let cursor = &self.data.cursor;
        let coordinate = |t| {
            input
                .position_filtered(t, cursor.remove_shakes)
                .map(|p| (p.x, p.y, p.t))
        };
        let Some((actual_x, actual_y, last_move)) = coordinate(local) else {
            return;
        };
        let physics = crate::spring::cursor_preset(
            &cursor.speed_preset,
            &cursor.spring,
            cursor.physics_version,
        );
        let mut x = actual_x;
        let mut y = actual_y;
        if !self.data.timeline.clips[clip_i].settings.disable_smoothing
            && cursor.smoothing > 0.0
            && (cursor.physics_version == 0 || cursor.speed_preset != "none")
        {
            let window = (20.0 * physics.mass / physics.friction)
                .max(20.0 * physics.friction / physics.tension)
                .max(2.0);
            let cutoff = (local - (window * 1e9) as i64).max(0);
            if let Some((initial_x, initial_y, _)) = coordinate(cutoff) {
                let mut sx = initial_x;
                let mut sy = initial_y;
                let mut previous = (initial_x, initial_y);
                let positions = input.positions_filtered(cursor.remove_shakes);
                let a = positions.partition_point(|p| p.t < cutoff);
                let b = positions.partition_point(|p| p.t <= local);
                for e in &positions[a..b] {
                    let k = crate::spring::response((local - e.t) as f64 / 1e9, &physics);
                    sx += (e.x - previous.0) * k;
                    sy += (e.y - previous.1) * k;
                    previous = (e.x, e.y);
                }
                x = x * (1.0 - cursor.smoothing) + sx * cursor.smoothing;
                y = y * (1.0 - cursor.smoothing) + sy * cursor.smoothing;
            }
        }
        let points = self.session.source.content_rect_points;
        let transform = |x: f64, y: f64| {
            (
                f.screen_dest.x
                    + (x / points[2] - f.screen_crop.x) / f.screen_crop.w * f.screen_dest.w,
                f.screen_dest.y
                    + (y / points[3] - f.screen_crop.y) / f.screen_crop.h * f.screen_dest.h,
            )
        };
        let (cx, cy) = transform(x, y);
        f.cursor_x = cx;
        f.cursor_y = cy;
        // Authored cursors use a 32pt canvas. Logical sizing is independent of
        // Retina raster density; legacy multipliers keep their old pixel basis.
        let source_scale = cursor.size_points.map_or_else(
            || cursor.size / pixels_width(self),
            |points| points / 32.0 / self.session.source.content_rect_points[2],
        );
        f.cursor_scale = (source_scale * f.screen_dest.w / f.screen_crop.w) as f32;
        f.cursor_id = if cursor.always_default {
            0
        } else {
            input.cursor_filtered(local, cursor.optimize_types)
        };
        let inside = cx >= f.screen_dest.x
            && cx <= f.screen_dest.x + f.screen_dest.w
            && cy >= f.screen_dest.y
            && cy <= f.screen_dest.y + f.screen_dest.h;
        let range_visible = cursor
            .ranges
            .iter()
            .filter(|r| f.tl_ns >= r.tl_start_ns && f.tl_ns < r.tl_end_ns)
            .max_by_key(|r| r.tl_start_ns)
            .map_or(cursor.visible, |r| r.visible);
        let visible = range_visible
            && !self.data.timeline.clips[clip_i].settings.hide_cursor
            && !self.session.tracks.screen.cursor_in_video
            && inside
            && (!cursor.hide_when_idle || local - last_move < cursor.idle_timeout_ns);
        f.cursor_visible = visible as u8;
        f.cursor_opacity = if visible { 1.0 } else { 0.0 };
        if cursor.click_effect != "none" {
            let effect_duration_ns = click_effect_duration_ns(self.data.defaults_revision, cursor);
            if let Some(e) = input.click(local) {
                let click_src = seg.src_start_ns + e.t;
                if let Some(t) =
                    time::source_to_timeline(&self.data.timeline.clips, clip_i, click_src)
                {
                    let elapsed = f.tl_ns - t;
                    if elapsed >= 0 && elapsed < effect_duration_ns {
                        f.click_progress = elapsed as f32 / effect_duration_ns as f32;
                        let (x, y) = transform(e.x, e.y);
                        f.click_x = x;
                        f.click_y = y;
                    }
                }
            }
        }
    }
}
fn pixels_width(p: &Project) -> f64 {
    p.session.tracks.screen.pixel_size[0] as f64 / p.session.source.scale
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        model::{Layout, Zoom},
        project::tests::Fixture,
    };
    fn near(a: f64, b: f64) {
        assert!((a - b).abs() < 1e-5, "{a} != {b}");
    }
    #[test]
    fn cropped_zoom_start_pan_and_height_limited_camera_never_panic() {
        let fixture = Fixture::new();
        let mut p = Project::create(&fixture.0).unwrap();
        p.data.autosave = false;
        p.data.canvas.crop = [0.1, 0.1, 0.7, 0.7];
        for mode in ["manual", "auto"] {
            for start in [0, 1_000_000_000] {
                p.data.zooms = vec![Zoom {
                    style: "classic".into(),
                    lens: Default::default(),
                    id: "rounding".into(),
                    tl_start_ns: start,
                    tl_end_ns: start + 1_000_000_000,
                    mode: mode.into(),
                    target: [0.5, 0.5],
                    scale: 2.0,
                    ease_in_ns: 300_000_000,
                    ease_out_ns: 300_000_000,
                    enabled: true,
                }];
                for t in [start, start + 1, start + 150_000_000, start + 999_999_999] {
                    let f = p.frame(t).unwrap();
                    assert!(f.screen_crop.x.is_finite() && f.screen_crop.y.is_finite());
                    assert!(f.screen_crop.x >= 0.1 && f.screen_crop.y >= 0.1);
                    assert!(f.screen_crop.x + f.screen_crop.w <= 0.8 + 1e-15);
                    assert!(f.screen_crop.y + f.screen_crop.h <= 0.8 + 1e-15);
                }
            }
        }
        let rect = Rect {
            x: 0.1,
            y: 0.1,
            w: 0.7,
            h: 0.7,
        };
        let pan = follow_pan(rect, [0.8, 0.8], 0.15, rect);
        assert_eq!((pan.x, pan.y), (0.1, 0.1));
        p.session.tracks.camera = Some(crate::model::CameraTrack {
            device_name: "synthetic".into(),
            pixel_size: [1280, 800],
            fps: 30.0,
            mirrored: false,
        });
        p.session.segments[0]
            .files
            .insert("camera".into(), "seg-000/screen.mov".into());
        p.data.canvas.output_size = [1920, 768];
        p.data.canvas.aspect = "custom".into();
        p.data.camera.size = 1.0;
        for position in [[0.0, 0.0], [1.0, 1.0], [0.5, 0.5]] {
            p.data.camera.position = position;
            let f = p.frame(0).unwrap();
            assert!(f.camera_dest.x >= 0.0 && f.camera_dest.y >= 0.0);
            assert!(f.camera_dest.y + f.camera_dest.h <= 768.0);
        }
        assert_eq!(coordinate(0.5, 0.1, 0.09999999999999998), 0.1);
    }
    #[test]
    fn golden_fixture_and_no_allocations() {
        let fixture = Fixture::new();
        let mut p = Project::create(&fixture.0).unwrap();
        // Explicit legacy geometry keeps this evaluator golden independent of new-project defaults.
        p.data.canvas = crate::model::Canvas::default();
        p.data.cursor = crate::model::Cursor::default();
        p.data.cursor.smoothing = 0.0;
        let f = p.frame(0).unwrap();
        assert_eq!((f.canvas_w, f.canvas_h), (1920, 1080));
        near(f.screen_dest.x, 172.8);
        near(f.screen_dest.y, 48.0);
        near(f.screen_dest.w, 1574.4);
        near(f.screen_dest.h, 984.0);
        near(f.cursor_x, 369.6);
        near(f.cursor_y, 244.8);
        assert_eq!(f.cursor_id, 1);
        assert_eq!(f.camera.present, 0);
        assert_eq!(f.click_progress, -1.0);
        let click = p.frame(1_800_000_000).unwrap();
        near(click.click_progress as f64, 0.25);
        let seg = p.frame(3_200_000_000).unwrap();
        assert_eq!(seg.screen.segment, 1);
        assert_eq!(seg.screen.file_ns, 200_000_000);
        p.data.zooms.push(Zoom {
            style: "classic".into(),
            lens: Default::default(),
            id: "z".into(),
            tl_start_ns: 0,
            tl_end_ns: 2_000_000_000,
            mode: "manual".into(),
            target: [0.5, 0.5],
            scale: 2.0,
            ease_in_ns: 0,
            ease_out_ns: 0,
            enabled: true,
        });
        let zoom = p.frame(1_000_000_000).unwrap();
        near(zoom.screen_crop.x, 0.25);
        near(zoom.screen_crop.w, 0.5);
        p.data.cursor.smoothing = 0.5;
        let n = crate::allocation_test::count(|| {
            for t in [0, 1_000_000_000, 1_800_000_000, 3_200_000_000] {
                std::hint::black_box(p.frame(t).unwrap());
            }
        });
        assert_eq!(n, 0);
        assert!(p.frame(-1).is_err());
        assert!(p.frame(5_000_000_001).is_err());
    }
    #[test]
    fn easing_layout_and_aspect() {
        let fixture = Fixture::new();
        let mut p = Project::create(&fixture.0).unwrap();
        p.data.canvas.aspect = "9:16".into();
        assert_eq!(p.frame(0).unwrap().canvas_w, 608);
        p.data.camera.layouts.push(Layout {
            enabled: true,
            settings: None,
            camera_background_removal: None,
            camera_face_framing: None,
            camera_shadow_radius: None,
            id: "l".into(),
            tl_start_ns: 1_000_000_000,
            tl_end_ns: 2_000_000_000,
            mode: "camera".into(),
            camera_position: None,
            camera_size: None,
        });
        assert_eq!(p.frame(1_500_000_000).unwrap().screen.present, 1);
        assert_eq!(p.frame(2_000_000_000).unwrap().screen.present, 1);
        for n in 0..100 {
            let a = spring(n as f64 / 100.0);
            let b = spring((n + 1) as f64 / 100.0);
            assert!(a <= b && (0.0..=1.000001).contains(&b));
        }
        near(spring(0.0), 0.0);
        near(spring(1.0), 1.0);
    }
}
#[cfg(test)]
mod m2_tests {
    use super::*;
    use crate::{model::*, project::tests::Fixture};
    use serde_json::json;
    #[test]
    fn crop_cursor_ranges_idle_loop_and_audio_envelope() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        // Explicit legacy geometry keeps this evaluator golden independent of new-project defaults.
        p.data.canvas = crate::model::Canvas::default();
        p.data.cursor = crate::model::Cursor::default();
        p.data.cursor.smoothing = 0.0;
        p.apply(&json!({"op":"set","path":"cursor.ranges","value":[{"tl_start_ns":0,"tl_end_ns":500_000_000,"visible":false}]})).unwrap();
        assert_eq!(p.frame(0).unwrap().cursor_visible, 0);
        assert_eq!(p.frame(600_000_000).unwrap().cursor_visible, 1);
        p.data.cursor.hide_when_idle = true;
        p.data.cursor.idle_timeout_ns = 100_000_000;
        assert_eq!(p.frame(2_500_000_000).unwrap().cursor_visible, 0);
        p.data.cursor.loop_to_start = true;
        let end = p.frame(5_000_000_000).unwrap();
        assert!((end.cursor_x - 369.6).abs() < 1e-5);
        p.apply(&json!({"op":"set","path":"canvas.crop","value":[0.25,0.25,0.5,0.5]}))
            .unwrap();
        assert_eq!(p.frame(0).unwrap().screen_crop.w, 0.5);
        p.apply(&json!({"op":"set","path":"audio.ranges","value":[{"id":"fade","track":"system_audio","tl_start_ns":0,"tl_end_ns":2_000_000_000,"start_gain_db":-20,"end_gain_db":0}]})).unwrap();
        assert!((p.frame(1_000_000_000).unwrap().system_gain - 0.31622776).abs() < 1e-6);
        p.data.audio.system_muted = true;
        assert_eq!(p.frame(1_000_000_000).unwrap().system_gain, 0.0);
    }
    #[test]
    fn camera_geometry_and_dynamic_layout() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.data.camera.layout_settings.aspect = None; // Exercise recorded camera aspect, not factory square.
        p.session.tracks.camera = Some(CameraTrack {
            device_name: "synthetic".into(),
            pixel_size: [640, 480],
            fps: 30.0,
            mirrored: false,
        });
        p.session.segments[0]
            .files
            .insert("camera".into(), "seg-000/screen.mov".into());
        let overlay = p.frame(0).unwrap();
        assert_eq!(overlay.camera.present, 1);
        assert!((overlay.camera_dest.w / overlay.camera_dest.h - 4.0 / 3.0).abs() < 1e-6);
        p.data.camera.layouts.push(Layout {
            enabled: true,
            settings: None,
            camera_background_removal: None,
            camera_face_framing: None,
            camera_shadow_radius: None,
            id: "full".into(),
            tl_start_ns: 1_000_000_000,
            tl_end_ns: 2_000_000_000,
            mode: "camera".into(),
            camera_position: None,
            camera_size: None,
        });
        let full = p.frame(1_500_000_000).unwrap();
        assert_eq!(full.screen.present, 0);
        assert!(full.camera_dest.w > overlay.camera_dest.w);
        assert_eq!(p.frame(2_000_000_000).unwrap().screen.present, 1);
        p.data.camera.shape = "circle".into();
        let circle = p.frame(0).unwrap();
        assert_eq!(circle.camera_shape, 1);
        assert_eq!(circle.camera_dest.w, circle.camera_dest.h);
    }
    #[test]
    fn presets_only_change_settings() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        let original = p.data.clone();
        p.apply(&json!({"op":"apply_preset","preset":{"canvas":{"aspect":"1:1","padding":12}}}))
            .unwrap();
        assert_eq!(p.frame(0).unwrap().canvas_w, 1080);
        assert_eq!(p.data.timeline, original.timeline);
        p.undo().unwrap();
        assert_eq!(p.data, original);
        assert!(p
            .apply(&json!({"op":"apply_preset","preset":{"recording":"../elsewhere"}}))
            .unwrap()
            .changed
            .is_empty());
        assert_eq!(p.data, original);
    }
}
