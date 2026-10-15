//! Stateless evaluation: preview, seek, and offline export produce identical frames.
//! The successful evaluation path performs no heap allocation or file access.
use crate::{
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
        let pixels = self.session.tracks.screen.pixel_size;
        let source_aspect = pixels[0] as f64 / pixels[1] as f64 * c.crop[2] / c.crop[3];
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
                x: c.crop[0],
                y: c.crop[1],
                w: c.crop[2],
                h: c.crop[3],
            },
            screen_dest: fit(area, source_aspect),
            screen_corner_radius: c.radius as f32,
            shadow_radius: c.shadow.evaluated().2 as f32,
            shadow_opacity: c.shadow.opacity as f32,
            shadow_offset_y: c.shadow.evaluated().1 as f32,
            inset_width: c.inset as f32,
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
        if let Some(z) = p
            .zooms
            .iter()
            .filter(|z| {
                z.enabled
                    && (z.mode != "auto" || p.zoom_settings.automatic)
                    && tl_ns
                        >= if p.zoom_settings.start_early {
                            z.tl_start_ns.saturating_sub(350_000_000).max(0)
                        } else {
                            z.tl_start_ns
                        }
                    && tl_ns < z.tl_end_ns
            })
            .max_by_key(|z| z.tl_start_ns)
        {
            let settings = &p.zoom_settings;
            let start = if settings.start_early {
                z.tl_start_ns.saturating_sub(350_000_000).max(0)
            } else {
                z.tl_start_ns
            };
            let span = z.tl_end_ns - start;
            let incoming = if settings.start_early {
                z.tl_start_ns - start
            } else if settings.physics_version == 1 {
                z.ease_in_ns.min(span / 2)
            } else {
                z.ease_in_ns
            };
            let outgoing = if settings.physics_version == 1 {
                z.ease_out_ns.min(span / 2)
            } else {
                z.ease_out_ns
            };
            let inside = if incoming == 0 {
                1.0
            } else {
                (tl_ns - start) as f64 / incoming as f64
            };
            let outside = if outgoing == 0 {
                1.0
            } else {
                (z.tl_end_ns - tl_ns) as f64 / outgoing as f64
            };
            let physics = crate::motion::zoom_spring(settings);
            let ramp_ns = if inside < outside { incoming } else { outgoing };
            let weight = if settings.physics_version == 1 {
                crate::spring::aligned_transition(
                    inside.min(outside),
                    ramp_ns as f64 / 1e9,
                    self.session.tracks.screen.max_fps as f64,
                    &physics,
                )
            } else {
                crate::spring::transition(inside.min(outside), ramp_ns as f64 / 1e9, &physics)
            };
            zoom_camera_factor = 1.0 + (p.camera.zoom_scale - 1.0) * weight.clamp(0.0, 1.0);
            let size = 1.0 / (1.0 + (z.scale - 1.0) * weight);
            let w = c.crop[2] * size;
            let h = c.crop[3] * size;
            let mut x = coordinate(
                z.target[0] - w / 2.0,
                c.crop[0],
                c.crop[0] + (c.crop[2] - w).max(0.0),
            );
            let mut y = coordinate(
                z.target[1] - h / 2.0,
                c.crop[1],
                c.crop[1] + (c.crop[3] - h).max(0.0),
            );

            if z.mode == "auto" && settings.follow_cursor && frame.screen.present != 0 {
                let seg = &self.session.segments[frame.screen.segment as usize];
                let input = &self.input[frame.screen.segment as usize];
                let local = src - seg.src_start_ns;
                let base = Rect { x, y, w, h };
                let bounds = Rect {
                    x: c.crop[0],
                    y: c.crop[1],
                    w: c.crop[2],
                    h: c.crop[3],
                };
                let normalized = |p: crate::input::Point| {
                    [
                        p.x / self.session.source.content_rect_points[2],
                        p.y / self.session.source.content_rect_points[3],
                    ]
                };
                if let Some(point) = input.position_filtered(local, p.cursor.remove_shakes) {
                    let mut next = follow_pan(base, normalized(point), settings.dead_zone, bounds);
                    if settings.animation_style != "custom" {
                        let window =
                            (100_000_000.0 * p.timeline.clips[clip_i].speed).round() as i64;
                        let cutoff = local.saturating_sub(window).max(0);
                        if let Some(initial) =
                            input.position_filtered(cutoff, p.cursor.remove_shakes)
                        {
                            let initial =
                                follow_pan(base, normalized(initial), settings.dead_zone, bounds);
                            let mut sx = initial.x;
                            let mut sy = initial.y;
                            let mut target = initial;
                            let positions = input.positions_filtered(p.cursor.remove_shakes);
                            let a = positions.partition_point(|p| p.t < cutoff);
                            let b = positions.partition_point(|p| p.t <= local);
                            for &event in &positions[a..b] {
                                let next_target =
                                    follow_pan(base, normalized(event), settings.dead_zone, bounds);
                                let seconds =
                                    (local - event.t) as f64 / 1e9 / p.timeline.clips[clip_i].speed;
                                let k = crate::spring::response(seconds, &physics);
                                sx += (next_target.x - target.x) * k;
                                sy += (next_target.y - target.y) * k;
                                target = next_target;
                            }
                            next.x =
                                coordinate(sx, bounds.x, bounds.x + (bounds.w - base.w).max(0.0));
                            next.y =
                                coordinate(sy, bounds.y, bounds.y + (bounds.h - base.h).max(0.0));
                        }
                    }
                    x = next.x;
                    y = next.y;
                }
            }
            frame.screen_crop = Rect { x, y, w, h };
        }
        let camera_aspect = if frame.camera_shape == 1 {
            1.0
        } else {
            self.session.tracks.camera.as_ref().map_or(1.0, |c| {
                c.pixel_size[0] as f64 / c.pixel_size[1].max(1) as f64
            })
        };
        let mut camera_pos = p.camera.position;
        let mut camera_size = p.camera.size;
        let mut camera_visible = p.camera.visible;
        if let Some(l) = p
            .camera
            .layouts
            .iter()
            .filter(|l| tl_ns >= l.tl_start_ns && tl_ns < l.tl_end_ns)
            .max_by_key(|l| l.tl_start_ns)
        {
            camera_pos = l.camera_position.unwrap_or(camera_pos);
            camera_size = l.camera_size.unwrap_or(camera_size);
            match l.mode.as_str() {
                "screen" => camera_visible = false,
                "camera" => {
                    if frame.camera.present != 0 {
                        frame.screen.present = 0;
                    }
                    frame.camera_dest = fit(area, camera_aspect);
                }
                "side_by_side" => {
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
                _ => {}
            }
        }
        if frame.camera_dest.w == 0.0 {
            let w = (canvas.w * camera_size * zoom_camera_factor)
                .min(canvas.w)
                .min(canvas.h * camera_aspect);
            let h = (w / camera_aspect).min(canvas.h);
            frame.camera_dest = Rect {
                x: coordinate(canvas.w * camera_pos[0] - w / 2.0, 0.0, canvas.w - w),
                y: coordinate(canvas.h * camera_pos[1] - h / 2.0, 0.0, canvas.h - h),
                w,
                h,
            };
        }
        if !camera_visible {
            frame.camera.present = 0;
            frame.camera_opacity = 0.0;
        }
        frame.mic_gain = self.audio_gain("mic", tl_ns);
        frame.system_gain = self.audio_gain("system_audio", tl_ns);
        if frame.screen.present != 0 {
            self.cursor_at(&mut frame, src, clip_i);
        }
        crate::layers::animate_frame(
            &mut frame,
            &p.canvas.animation,
            time::duration(&p.timeline.clips),
        );
        if p.cursor.stop_before_end_ns > 0 {
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
    pub fn audio_gain(&self, track: &str, tl_ns: i64) -> f32 {
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
        10.0f64.powf((base + db) / 20.0) as f32
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
        if cursor.smoothing > 0.0 && (cursor.physics_version == 0 || cursor.speed_preset != "none")
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
        if cursor.loop_to_start {
            let duration = time::duration(&self.data.timeline.clips);
            let remaining = duration - f.tl_ns;
            if remaining < cursor.loop_duration_ns {
                if let Some((_, first_src)) = time::timeline_to_source(&self.data.timeline.clips, 0)
                {
                    let sample = time::sample(&self.session, "screen", first_src);
                    let segment = &self.session.segments[sample.segment as usize];
                    if let Some(first) = self.input[sample.segment as usize]
                        .position_filtered(first_src - segment.src_start_ns, cursor.remove_shakes)
                    {
                        let k = ease(1.0 - remaining as f64 / cursor.loop_duration_ns as f64);
                        x += (first.x - x) * k;
                        y += (first.y - y) * k;
                    }
                }
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
            && !self.session.tracks.screen.cursor_in_video
            && inside
            && (!cursor.hide_when_idle || local - last_move < cursor.idle_timeout_ns);
        f.cursor_visible = visible as u8;
        f.cursor_opacity = if visible { 1.0 } else { 0.0 };
        if cursor.click_effect != "none" {
            if let Some(e) = input.click(local) {
                let click_src = seg.src_start_ns + e.t;
                if let Some(t) =
                    time::source_to_timeline(&self.data.timeline.clips, clip_i, click_src)
                {
                    let elapsed = f.tl_ns - t;
                    if elapsed >= 0 && elapsed < cursor.click_duration_ns {
                        f.click_progress = elapsed as f32 / cursor.click_duration_ns as f32;
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
            .is_err());
    }
}
