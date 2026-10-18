//! Guide motion options, evaluated analytically from immutable indexed events.
use crate::{
    frame::Frame,
    model::{Canvas, Spring, ZoomSettings},
    project::{Project, Result},
    time,
};
use serde::Serialize;
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize)]
#[repr(C)]
pub struct FrameMotion {
    pub tl_ns: i64,
    pub cursor_rotation_rad: f32,
    pub cursor_motion_blur: f32,
    pub zoom_motion_blur: f32,
    pub pan_motion_blur: f32,
}
pub(crate) fn zoom_spring(settings: &ZoomSettings) -> Spring {
    if settings.physics_version >= 1 {
        let (tension, friction, mass) = match settings.animation_style.as_str() {
            "focused" => (250.0, 40.0, 2.25),
            "smooth" => (170.0, 50.0, 3.0),
            _ => return crate::spring::preset(&settings.speed_preset, &settings.spring),
        };
        return Spring {
            tension,
            friction,
            mass,
            allow_overshoot: false,
        };
    }
    match settings.animation_style.as_str() {
        "focused" => Spring {
            tension: 500.0,
            friction: 45.0,
            mass: 1.0,
            allow_overshoot: false,
        },
        "smooth" => Spring {
            tension: 160.0,
            friction: 22.0,
            mass: 1.0,
            allow_overshoot: false,
        },
        _ => crate::spring::preset(&settings.speed_preset, &settings.spring),
    }
}
pub(crate) fn screen_blurs(canvas: &Canvas, current: &Frame, prior: &Frame) -> (f32, f32) {
    let global = canvas.global_motion_blur.unwrap_or(1.0) as f32;
    if current.screen.present == 0 || prior.screen.present == 0 {
        return (0.0, 0.0);
    }
    let a = current.screen_crop;
    let b = prior.screen_crop;
    let d = current.screen_dest;
    let e = prior.screen_dest;
    let zooming = (a.w - b.w).abs() + (a.h - b.h).abs() > 1e-12
        || (d.w - e.w).abs() + (d.h - e.h).abs() > 1e-9;
    let panning = (a.x + a.w / 2.0 - b.x - b.w / 2.0).abs()
        + (a.y + a.h / 2.0 - b.y - b.h / 2.0).abs()
        > 1e-12
        || (d.x + d.w / 2.0 - e.x - e.w / 2.0).abs() + (d.y + d.h / 2.0 - e.y - e.h / 2.0).abs()
            > 1e-9;
    (
        if zooming {
            canvas
                .motion_blur_settings
                .zoom
                .unwrap_or(canvas.motion_blur) as f32
                * global
        } else {
            0.0
        },
        if panning {
            canvas
                .motion_blur_settings
                .pan
                .unwrap_or(canvas.motion_blur) as f32
                * global
        } else {
            0.0
        },
    )
}
impl Project {
    pub(crate) fn same_motion_clip(&self, tl_ns: i64) -> bool {
        let duration = time::duration(&self.data.timeline.clips);
        let index = |t: i64| {
            time::timeline_to_source(
                &self.data.timeline.clips,
                if duration > 0 { t.min(duration - 1) } else { t },
            )
            .map(|(i, _)| i)
        };
        index(tl_ns) == index(tl_ns.saturating_sub(16_666_667).max(0))
    }
    /// No allocation, file IO or mutation. Sampling a preceding timeline clock
    /// shares source/cut/speed mapping and seek behavior with legacy frames.
    pub fn frame_motion(&self, tl_ns: i64) -> Result<FrameMotion> {
        let current = self.frame_geometry(tl_ns)?;
        let cursor = &self.data.cursor;
        let following = cursor.rotation_mode == "follow";
        let tilting = !following && (cursor.rotation_mode == "tilt" || cursor.rotate_on_move);
        let mut motion = FrameMotion {
            tl_ns,
            cursor_rotation_rad: if (!tilting || self.data.defaults_revision >= 2)
                && current.cursor_visible != 0
            {
                cursor.rotation_degrees.to_radians() as f32
            } else {
                0.0
            },
            ..FrameMotion::default()
        };
        if tl_ns == 0 {
            return Ok(motion);
        }
        let prior_ns = tl_ns.saturating_sub(16_666_667).max(0);
        let prior = self.frame_geometry(prior_ns)?;
        let duration = time::duration(&self.data.timeline.clips);
        let stopped = !cursor.loop_to_start
            && cursor.stop_before_end_ns > 0
            && tl_ns >= duration.saturating_sub(cursor.stop_before_end_ns).max(0);
        if !self.same_motion_clip(tl_ns) {
            return Ok(motion);
        }
        // Type changes/hidden media cannot manufacture a velocity or blur trail.
        if current.cursor_visible != 0
            && prior.cursor_visible != 0
            && !stopped
            && current.screen.segment == prior.screen.segment
        {
            let dx = current.cursor_x - prior.cursor_x;
            let dy = current.cursor_y - prior.cursor_y;
            if dx.hypot(dy) > 1e-9 {
                motion.cursor_motion_blur = (cursor.motion_blur
                    * self.data.canvas.global_motion_blur.unwrap_or(1.0))
                    as f32;
                if following {
                    let heading = dy.atan2(dx)
                        + 3.0 * std::f64::consts::FRAC_PI_4
                        + motion.cursor_rotation_rad as f64;
                    motion.cursor_rotation_rad =
                        ((heading + std::f64::consts::PI).rem_euclid(2.0 * std::f64::consts::PI)
                            - std::f64::consts::PI) as f32;
                } else if tilting {
                    let seconds = (tl_ns - prior_ns) as f64 / 1e9;
                    motion.cursor_rotation_rad += ((dx / seconds / 600.0).clamp(-1.0, 1.0)
                        * 15_f64.to_radians()
                        * cursor.tilt_amount)
                        as f32;
                }
            }
        }
        (motion.zoom_motion_blur, motion.pan_motion_blur) =
            screen_blurs(&self.data.canvas, &current, &prior);
        Ok(motion)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        input::InputCache,
        model::{CameraTrack, Event},
        project::tests::Fixture,
    };
    use serde_json::json;
    fn event(t: i64, x: f64) -> Event {
        Event {
            t,
            kind: "move".into(),
            x: Some(x),
            y: Some(100.0),
            id: None,
            details: Default::default(),
        }
    }
    fn cursor(t: i64, id: u32) -> Event {
        Event {
            t,
            kind: "cursor".into(),
            x: None,
            y: None,
            id: Some(id),
            details: Default::default(),
        }
    }
    fn make() -> (Fixture, Project) {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        // Physics goldens explicitly retain the pre-R5 baseline; factory defaults
        // are covered independently in parity_tests.
        p.data.cursor.smoothing = 0.0;
        p.data.cursor.rotation_mode = "static".into();
        p.data.cursor.rotate_on_move = false;
        p.data.cursor.tilt_amount = 1.0;
        p.data.cursor.remove_shakes = false;
        p.data.cursor.optimize_types = false;
        p.data.camera = crate::model::Camera::default();
        p.events[0] = vec![
            cursor(0, 5),
            event(0, 100.0),
            event(100_000_000, 100.25),
            event(200_000_000, 99.75),
            event(300_000_000, 100.2),
            event(400_000_000, 200.0),
            event(500_000_000, 200.0),
            cursor(550_000_000, 6),
            cursor(570_000_000, 5),
            cursor(600_000_000, 7),
            cursor(700_000_000, 7),
        ];
        p.input[0] = InputCache::new(&p.events[0]);
        (f, p)
    }
    #[test]
    fn follow_rotation_uses_heading_and_base_with_idle_cut_hidden_and_legacy_tilt_guards() {
        let (fixture, mut p) = make();
        p.apply(&json!({"op":"batch","commands":[
            {"op":"set","path":"cursor.rotation_mode","value":"follow"},
            {"op":"set","path":"cursor.rotation_degrees","value":15},
            {"op":"set","path":"cursor.tilt_amount","value":0}]}))
            .unwrap();
        assert!(p.data.cursor.rotate_on_move);
        let angle = p.frame_motion(350_000_000).unwrap().cursor_rotation_rad;
        assert!((angle - 150_f32.to_radians()).abs() < 1e-6);
        for t in [0, 500_000_000] {
            assert!(
                (p.frame_motion(t).unwrap().cursor_rotation_rad - 15_f32.to_radians()).abs() < 1e-6
            );
        }
        assert_eq!(
            crate::allocation_test::count(|| {
                p.frame_motion(350_000_000).unwrap();
            }),
            0
        );
        p.save(&fixture.0).unwrap();
        assert_eq!(
            Project::open(&fixture.0).unwrap().data.cursor.rotation_mode,
            "follow"
        );
        p.apply(&json!({"op":"split","at_tl_ns":350_000_000}))
            .unwrap();
        assert!(
            (p.frame_motion(350_000_000).unwrap().cursor_rotation_rad - 15_f32.to_radians()).abs()
                < 1e-6
        );
        p.apply(&json!({"op":"set","path":"cursor.visible","value":false}))
            .unwrap();
        assert_eq!(
            p.frame_motion(350_000_000).unwrap().cursor_rotation_rad,
            0.0
        );
        p.undo().unwrap();
        p.undo().unwrap();
        p.apply(&json!({"op":"set","path":"cursor.rotate_on_move","value":true}))
            .unwrap();
        assert_eq!(p.data.cursor.rotation_mode, "tilt");
        assert!(
            (p.frame_motion(350_000_000).unwrap().cursor_rotation_rad - 15_f32.to_radians()).abs()
                < 1e-6
        );
        p.data.defaults_revision = 1;
        assert_eq!(
            p.frame_motion(350_000_000).unwrap().cursor_rotation_rad,
            0.0
        );
    }
    #[test]
    fn static_and_scaled_tilt_goldens_use_existing_motion_abi_at_start_idle_and_cuts() {
        let (_f, mut p) = make();
        p.data.autosave = false;
        assert_eq!(p.data.cursor.rotation_mode, "static");
        assert_eq!(p.data.cursor.shake_threshold, 500.0);
        p.apply(&json!({"op":"set","path":"cursor.rotation_degrees","value":90}))
            .unwrap();
        for t in [0, 350_000_000, 500_000_000] {
            assert!(
                (p.frame_motion(t).unwrap().cursor_rotation_rad - std::f32::consts::FRAC_PI_2)
                    .abs()
                    < 1e-6
            );
            assert!(
                (p.query(&json!({"q":"render_options_at","tl_ns":t}))
                    .unwrap()["cursor_rotation_rad"]
                    .as_f64()
                    .unwrap()
                    - std::f64::consts::FRAC_PI_2)
                    .abs()
                    < 1e-6
            );
        }
        p.apply(&json!({"op":"batch","commands":[
            {"op":"set","path":"cursor.rotation_degrees","value":0},
            {"op":"set","path":"cursor.rotation_mode","value":"tilt"},
            {"op":"set","path":"cursor.tilt_amount","value":2}]}))
            .unwrap();
        assert!(p.data.cursor.rotate_on_move);
        assert!(
            (p.frame_motion(350_000_000).unwrap().cursor_rotation_rad - 30_f32.to_radians()).abs()
                < 1e-6
        );
        assert_eq!(
            p.frame_motion(500_000_000).unwrap().cursor_rotation_rad,
            0.0
        );
        assert_eq!(p.frame_motion(0).unwrap().cursor_rotation_rad, 0.0);
        p.apply(&json!({"op":"set","path":"cursor.tilt_amount","value":0}))
            .unwrap();
        assert_eq!(
            p.frame_motion(350_000_000).unwrap().cursor_rotation_rad,
            0.0
        );
        p.undo().unwrap();
        p.apply(&json!({"op":"split","at_tl_ns":350_000_000}))
            .unwrap();
        assert_eq!(
            p.frame_motion(350_000_000).unwrap().cursor_rotation_rad,
            0.0
        );
        p.apply(&json!({"op":"batch","commands":[{"op":"set","path":"cursor.rotation_mode","value":"static"},{"op":"set","path":"cursor.rotation_degrees","value":90}]}))
            .unwrap();
        assert!(!p.data.cursor.rotate_on_move);
        assert!(
            (p.frame_motion(350_000_000).unwrap().cursor_rotation_rad
                - std::f32::consts::FRAC_PI_2)
                .abs()
                < 1e-6
        );
        p.apply(&json!({"op":"set","path":"cursor.rotation_degrees","value":-180}))
            .unwrap();
        assert_eq!(
            p.frame_motion(0).unwrap().cursor_rotation_rad,
            -std::f32::consts::PI
        );
        p.apply(&json!({"op":"set","path":"cursor.visible","value":false}))
            .unwrap();
        assert_eq!(p.frame_motion(0).unwrap().cursor_rotation_rad, 0.0);
        let before = p.data.clone();
        for (path, value) in [
            ("rotation_mode", json!("invalid")),
            ("rotation_degrees", json!(180.01)),
            ("rotation_degrees", json!(-180.01)),
            ("tilt_amount", json!(-0.1)),
            ("tilt_amount", json!(2.1)),
            ("shake_threshold", json!(99)),
            ("shake_threshold", json!(2001)),
        ] {
            assert!(p.apply(&json!({"op":"batch","commands":[{"op":"set","path":"notes","value":"must roll back"},{"op":"set","path":format!("cursor.{path}"),"value":value}]})).is_err());
            assert_eq!(p.data, before);
        }
    }
    #[test]
    fn threshold_frame_goldens_share_raw_data_and_follow_history_snapshots_and_reopen() {
        let f = Fixture::new();
        let events = [
            event(0, 100.0),
            event(100_000_000, 100.75),
            event(200_000_000, 101.5),
            event(300_000_000, 104.0),
            event(400_000_000, 104.0),
        ];
        let bytes = events
            .iter()
            .map(|e| serde_json::to_string(e).unwrap() + "\n")
            .collect::<String>();
        let path = f.0.join("recording/seg-000/events.jsonl");
        std::fs::write(&path, &bytes).unwrap();
        let mut p = Project::create(&f.0).unwrap();
        p.data.autosave = false;
        p.apply(&json!({"op":"batch","commands":[
            {"op":"set","path":"cursor.smoothing","value":0},
            {"op":"set","path":"cursor.remove_shakes","value":true},
            {"op":"set","path":"canvas.output_size","value":[320,200]},
            {"op":"set","path":"canvas.padding","value":0}]}))
            .unwrap();
        let x = |p: &Project, t| p.frame(t).unwrap().cursor_x;
        assert!((x(&p, 100_000_000) - 100.75).abs() < 1e-9);
        let snapshot = p.clone();
        p.apply(&json!({"op":"set","path":"cursor.shake_threshold","value":2000}))
            .unwrap();
        assert!((x(&p, 200_000_000) - 100.0).abs() < 1e-9);
        assert!((x(&snapshot, 200_000_000) - 101.5).abs() < 1e-9);
        assert!(std::sync::Arc::ptr_eq(
            &p.input[0].positions,
            &snapshot.input[0].positions
        ));
        assert!(!std::sync::Arc::ptr_eq(
            &p.input[0].steady_positions,
            &snapshot.input[0].steady_positions
        ));
        p.undo().unwrap();
        assert!((x(&p, 200_000_000) - 101.5).abs() < 1e-9);
        p.redo().unwrap();
        assert!((x(&p, 200_000_000) - 100.0).abs() < 1e-9);
        p.save(&f.0).unwrap();
        let restored = Project::open(&f.0).unwrap();
        assert_eq!(restored.data.cursor.shake_threshold, 2000.0);
        assert_eq!(x(&p, 200_000_000), x(&restored, 200_000_000));
        p.apply(&json!({"op":"set","path":"cursor.remove_shakes","value":false}))
            .unwrap();
        assert!((x(&p, 200_000_000) - 101.5).abs() < 1e-9);
        p.apply(&json!({"op":"set","path":"cursor.shake_threshold","value":100}))
            .unwrap();
        p.apply(&json!({"op":"set","path":"cursor.remove_shakes","value":true}))
            .unwrap();
        assert!((x(&p, 100_000_000) - 100.75).abs() < 1e-9);
        let mut retina = p.clone();
        retina.session.tracks.screen.pixel_size = [640, 400];
        assert_eq!(x(&retina, 100_000_000), x(&p, 100_000_000));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), bytes);
        assert_eq!(
            crate::allocation_test::count(|| {
                p.frame(150_000_000).unwrap();
                p.frame_extras(150_000_000).unwrap();
                p.frame_motion(150_000_000).unwrap();
            }),
            0
        );
    }
    #[test]
    fn legacy_cursor_settings_and_preset_aliases_keep_the_old_one_point_deadband() {
        let (f, mut p) = make();
        p.data.autosave = false;
        let mut raw = serde_json::to_value(&p.data).unwrap();
        for key in [
            "rotation_mode",
            "rotation_degrees",
            "tilt_amount",
            "shake_threshold",
        ] {
            raw["cursor"].as_object_mut().unwrap().remove(key);
        }
        raw["cursor"]["rotate_on_move"] = true.into();
        raw["cursor"]["remove_shakes"] = true.into();
        let old = crate::project::decode_project(&serde_json::to_vec(&raw).unwrap()).unwrap();
        assert_eq!(old.cursor.rotation_mode, "tilt");
        assert_eq!(old.cursor.shake_threshold, 1000.0);
        assert_eq!(old.cursor.tilt_amount, 1.0);
        assert_eq!(old.cursor.rotation_degrees, 0.0);
        std::fs::write(f.0.join("project.json"), serde_json::to_vec(&raw).unwrap()).unwrap();
        let loaded = Project::open(&f.0).unwrap();
        assert_eq!(loaded.input[0].shake_threshold, 1000.0);
        p.apply(&json!({"op":"apply_preset","preset":{"cursor":{"rotate_on_move":true,"remove_shakes":true}}})).unwrap();
        assert_eq!(p.data.cursor.rotation_mode, "tilt");
        assert_eq!(p.data.cursor.shake_threshold, 1000.0);
        p.apply(&json!({"op":"set","path":"cursor.rotate_on_move","value":false}))
            .unwrap();
        assert_eq!(p.data.cursor.rotation_mode, "static");
        let prior = p.data.clone();
        p.apply(&json!({"op":"apply_preset","preset":{"cursor":{"rotation_mode":"tilt","rotation_degrees":30,"tilt_amount":0.5,"shake_threshold":1500}}})).unwrap();
        assert!(p.data.cursor.rotate_on_move);
        assert_eq!(p.input[0].shake_threshold, 1500.0);
        p.undo().unwrap();
        assert_eq!(p.data, prior);
        assert_eq!(p.input[0].shake_threshold, 1000.0);
    }
    #[test]
    fn aligned_screen_physics_early_lead_short_ramps_and_legacy_migration() {
        let (f, mut p) = make();
        p.data.zoom_settings.physics_version = 1;
        let mut legacy = ZoomSettings {
            animation_style: "focused".into(),
            ..ZoomSettings::default()
        };
        assert_eq!(zoom_spring(&legacy).tension, 500.0);
        legacy.physics_version = 1;
        assert_eq!(
            (
                zoom_spring(&legacy).tension,
                zoom_spring(&legacy).friction,
                zoom_spring(&legacy).mass
            ),
            (250.0, 40.0, 2.25)
        );
        legacy.animation_style = "smooth".into();
        assert_eq!(
            (
                zoom_spring(&legacy).tension,
                zoom_spring(&legacy).friction,
                zoom_spring(&legacy).mass
            ),
            (170.0, 50.0, 3.0)
        );
        p.apply(&json!({"op":"add_zoom","zoom":{"tl_start_ns":1_000_000_000,"tl_end_ns":3_000_000_000_i64,"target":[0.5,0.5],"scale":2,"mode":"manual","ease_in_ns":300_000_000,"ease_out_ns":300_000_000}})).unwrap();
        assert_eq!(p.frame(800_000_000).unwrap().screen_crop.w, 1.0);
        p.apply(&json!({"op":"set","path":"zoom_settings.start_early","value":true}))
            .unwrap();
        assert_eq!(p.frame(650_000_000).unwrap().screen_crop.w, 1.0);
        assert!(p.frame(800_000_000).unwrap().screen_crop.w < 1.0);
        assert_eq!(p.frame(1_000_000_000).unwrap().screen_crop.w, 0.5);
        assert_eq!(p.frame(3_000_000_000).unwrap().screen_crop.w, 1.0);
        p.undo().unwrap();
        assert_eq!(p.frame(800_000_000).unwrap().screen_crop.w, 1.0);
        p.redo().unwrap();
        p.save(&f.0).unwrap();
        let reopened = Project::open(&f.0).unwrap();
        for t in [800_000_000, 1_000_000_000, 2_900_000_000] {
            assert_eq!(
                reopened.frame(t).unwrap().screen_crop,
                p.frame(t).unwrap().screen_crop
            );
        }
        p.data.cursor = crate::model::Cursor::default();
        p.data.cursor.spring.tension = 700.0; // Valid old custom settings survive opting into a named preset.
        p.apply(&json!({"op":"set","path":"cursor.speed_preset","value":"rapid"}))
            .unwrap();
        assert_eq!(p.data.cursor.smoothing, 1.0);
        assert_eq!(p.data.cursor.spring.tension, 700.0);
        p.apply(&json!({"op":"set","path":"cursor.speed_preset","value":"none"}))
            .unwrap();
        assert_eq!(p.data.cursor.smoothing, 0.0);
        for (path, value) in [
            ("zoom_settings.spring.mass", json!(15)),
            ("zoom_settings.spring.tension", json!(5)),
            ("zoom_settings.spring.friction", json!(200)),
        ] {
            p.apply(&json!({"op":"set","path":path,"value":value}))
                .unwrap();
        }
        p.apply(&json!({"op":"set","path":"cursor.spring.tension","value":250}))
            .unwrap();
        let before = p.data.clone();
        for (path, value) in [
            ("zoom_settings.spring.mass", json!(15.1)),
            ("cursor.spring.tension", json!(601)),
            ("cursor.spring.friction", json!(4)),
        ] {
            assert!(p
                .apply(&json!({"op":"set","path":path,"value":value}))
                .is_err());
            assert_eq!(p.data, before);
        }
        assert_eq!(
            crate::allocation_test::count(|| {
                p.frame(800_000_000).unwrap();
                p.frame_motion(800_000_000).unwrap();
            }),
            0
        );
    }
    #[test]
    fn bs3_new_zoom_spring_is_centered_monotonic_and_uncompressed() {
        let (_f, mut p) = make();
        assert_eq!(p.data.zoom_settings.physics_version, 2);
        assert_eq!(p.data.zoom_settings.animation_style, "smooth");
        let id = p
            .apply(&json!({"op":"insert_zoom","tl_start_ns":1_000_000_000_i64,"duration_ns":2_500_000_000_i64,"patch":{"mode":"manual","target":[0.5,0.5],"scale":2}}))
            .unwrap()
            .created_ids[0]
            .clone();
        let z = p.data.zooms.iter().find(|z| z.id == id).unwrap();
        assert_eq!(
            (z.ease_in_ns, z.ease_out_ns),
            (1_000_000_000, 1_000_000_000)
        );

        let progress = |t| {
            let width = p.frame(t).unwrap().screen_crop.w;
            1.0 / width - 1.0
        };
        let mut last = 0.0;
        let mut halfway = None;
        for step in 0..=100 {
            let t = step * 10_000_000;
            let value = progress(t);
            assert!(value >= last - 1e-12 && value <= 1.0 + 1e-12);
            if halfway.is_none() && value >= 0.5 {
                halfway = Some(t);
            }
            last = value;
        }
        assert!((150_000_000..=300_000_000).contains(&halfway.unwrap()));
        assert_eq!(progress(1_000_000_000), 1.0);
        assert_eq!(progress(3_500_000_000), 1.0);
        let mut last = 1.0;
        for step in 1..=100 {
            let value = progress(3_500_000_000 + step * 10_000_000);
            assert!(value <= last + 1e-12 && value >= -1e-12);
            last = value;
        }
        assert_eq!(p.frame(4_500_000_000).unwrap().screen_crop.w, 1.0);
        assert_eq!(
            crate::allocation_test::count(|| {
                std::hint::black_box(p.frame(250_000_000).unwrap());
                std::hint::black_box(p.frame(3_750_000_000).unwrap());
            }),
            0
        );
    }
    #[test]
    fn default_pointer_shake_filter_and_type_debounce_preserve_recorded_events() {
        let (_f, mut p) = make();
        let original = p.events.clone();
        let base = p.frame(0).unwrap();
        assert_eq!(base.cursor_id, 5);
        assert!(p.frame(100_000_000).unwrap().cursor_x != base.cursor_x);
        p.apply(&json!({"op":"set","path":"cursor.remove_shakes","value":true}))
            .unwrap();
        for t in [0, 100_000_000, 200_000_000, 300_000_000] {
            assert_eq!(p.frame(t).unwrap().cursor_x, base.cursor_x);
        }
        assert!(p.frame(400_000_000).unwrap().cursor_x > base.cursor_x);
        p.apply(&json!({"op":"set","path":"cursor.optimize_types","value":true}))
            .unwrap();
        assert_eq!(p.frame(560_000_000).unwrap().cursor_id, 5);
        assert_eq!(p.frame(650_000_000).unwrap().cursor_id, 5);
        assert_eq!(p.frame(680_000_000).unwrap().cursor_id, 7);
        p.apply(&json!({"op":"set","path":"cursor.always_default","value":true}))
            .unwrap();
        assert_eq!(p.frame(700_000_000).unwrap().cursor_id, 0);
        assert_eq!(p.frame_extras(700_000_000).unwrap().cursor_style, 1);
        assert_eq!(
            p.query(&json!({"q":"render_options"})).unwrap()["cursor_style"],
            json!("pointer")
        );
        assert_eq!(p.events, original);
        p.undo().unwrap();
        assert_eq!(p.frame(700_000_000).unwrap().cursor_id, 7);
        assert_eq!(
            crate::allocation_test::count(|| {
                p.frame(350_000_000).unwrap();
                p.frame_extras(350_000_000).unwrap();
                p.frame_motion(350_000_000).unwrap();
            }),
            0
        );
    }
    #[test]
    fn tilt_has_bounded_signed_velocity_and_stops_at_idle_or_cut() {
        let (_f, mut p) = make();
        p.data.cursor.rotate_on_move = true;
        p.data.cursor.motion_blur = 0.7;
        let moving = p.frame_motion(350_000_000).unwrap();
        assert!((moving.cursor_rotation_rad - 15_f32.to_radians()).abs() < 1e-6);
        assert_eq!(moving.cursor_motion_blur, 0.7);
        let idle = p.frame_motion(500_000_000).unwrap();
        assert_eq!(idle.cursor_rotation_rad, 0.0);
        assert_eq!(idle.cursor_motion_blur, 0.0);
        assert_eq!(p.frame_motion(0).unwrap().cursor_rotation_rad, 0.0);
        p.events[0] = vec![event(0, 200.0), event(100_000_000, 100.0)];
        p.input[0] = InputCache::new(&p.events[0]);
        assert!(p.frame_motion(50_000_000).unwrap().cursor_rotation_rad < 0.0);
        p.apply(&json!({"op":"split","at_tl_ns":50_000_000}))
            .unwrap();
        assert_eq!(p.frame_motion(50_000_000).unwrap().cursor_rotation_rad, 0.0);
        p.data.cursor.visible = false;
        assert_eq!(p.frame_motion(60_000_000).unwrap().cursor_rotation_rad, 0.0);
    }
    #[test]
    fn stop_before_end_is_stateless_recomputes_after_cuts_and_can_hold_start() {
        let (f, mut p) = make();
        p.data.cursor.rotate_on_move = true;
        p.apply(&json!({"op":"set","path":"cursor.stop_before_end_ns","value":4_700_000_000_i64}))
            .unwrap();
        let stopped = p.frame(300_000_000).unwrap();
        for t in [5_000_000_000_i64, 700_000_000, 400_000_000, 350_000_000] {
            let frame = p.frame(t).unwrap();
            assert_eq!(
                (frame.cursor_x, frame.cursor_y),
                (stopped.cursor_x, stopped.cursor_y)
            );
            assert_eq!(p.frame_motion(t).unwrap().cursor_rotation_rad, 0.0);
        }
        let snapshot = p.clone();
        p.apply(
            &json!({"op":"delete_range","tl_start_ns":1_000_000_000,"tl_end_ns":2_000_000_000}),
        )
        .unwrap();
        let first = p.frame(0).unwrap();
        assert_eq!(p.frame(3_000_000_000_i64).unwrap().cursor_x, first.cursor_x);
        assert_eq!(
            snapshot.frame(400_000_000).unwrap().cursor_x,
            stopped.cursor_x
        );
        p.save(&f.0).unwrap();
        assert_eq!(
            Project::open(&f.0).unwrap().data.cursor.stop_before_end_ns,
            4_700_000_000_i64
        );
        assert!(p
            .apply(&json!({"op":"set","path":"cursor.stop_before_end_ns","value":-1}))
            .is_err());
        assert_eq!(
            crate::allocation_test::count(|| {
                p.frame(3_000_000_000_i64).unwrap();
                p.frame_motion(3_000_000_000_i64).unwrap();
            }),
            0
        );
    }
    #[test]
    fn screen_presets_per_kind_blur_and_camera_zoom_scale() {
        let (_f, mut p) = make();
        p.data.zoom_settings.physics_version = 1;
        p.session.tracks.camera = Some(CameraTrack {
            device_name: "procedural".into(),
            pixel_size: [320, 200],
            fps: 30.0,
            mirrored: false,
        });
        let camera_file = p.session.segments[0].files["screen"].clone();
        p.session.segments[0]
            .files
            .insert("camera".into(), camera_file);
        p.apply(&json!({"op":"add_zoom","zoom":{"tl_start_ns":0,"tl_end_ns":2_000_000_000,"target":[0.5,0.5],"scale":2,"mode":"manual","ease_in_ns":500_000_000,"ease_out_ns":500_000_000}})).unwrap();
        p.apply(&json!({"op":"set","path":"zoom_settings.animation_style","value":"focused"}))
            .unwrap();
        let focused = p.frame(200_000_000).unwrap().screen_crop.w;
        p.apply(&json!({"op":"set","path":"zoom_settings.animation_style","value":"smooth"}))
            .unwrap();
        let smooth = p.frame(200_000_000).unwrap().screen_crop.w;
        assert_ne!(focused, smooth);
        p.apply(&json!({"op":"set","path":"canvas.motion_blur_settings.zoom","value":0.6}))
            .unwrap();
        p.apply(&json!({"op":"set","path":"canvas.motion_blur_settings.pan","value":0}))
            .unwrap();
        assert_eq!(p.frame_motion(200_000_000).unwrap().zoom_motion_blur, 0.6);
        assert_eq!(p.frame_motion(200_000_000).unwrap().pan_motion_blur, 0.0);
        assert_eq!(p.frame_motion(1_000_000_000).unwrap().zoom_motion_blur, 0.0);
        let normal = p.frame(1_000_000_000).unwrap().camera_dest;
        p.apply(&json!({"op":"set","path":"camera.zoom_scale","value":1.5}))
            .unwrap();
        let big = p.frame(1_000_000_000).unwrap().camera_dest;
        assert!((big.w - normal.w * 1.5).abs() < 1e-6);
        assert!(big.x >= 0.0 && big.x + big.w <= 1920.0);
        assert!((p.frame(0).unwrap().camera_dest.w - normal.w).abs() < 1e-6);
        for (path, value) in [
            ("camera.zoom_scale", json!(5)),
            ("zoom_settings.animation_style", json!("unknown")),
            ("canvas.motion_blur_settings.pan", json!(-0.1)),
        ] {
            let before = p.data.clone();
            assert!(p
                .apply(&json!({"op":"set","path":path,"value":value}))
                .is_err());
            assert_eq!(p.data, before);
        }
        let snapshot = p.clone();
        for t in [1_000_000_000, 0, 100_000_000] {
            assert_eq!(
                p.frame_motion(t).unwrap(),
                snapshot.frame_motion(t).unwrap()
            );
        }
    }
    #[test]
    fn motion_abi_sizes_output_errors_hot_path_and_original_library() {
        use crate::ffi::*;
        use std::mem::{offset_of, size_of};
        assert_eq!(size_of::<crate::frame::Frame>(), 328);
        assert_eq!(size_of::<crate::layers::FrameExtras>(), 2600);
        assert_eq!(size_of::<FrameMotion>(), 24);
        assert_eq!(offset_of!(FrameMotion, cursor_rotation_rad), 8);
        let (_f, p) = make();
        let h = YcProject::new(p);
        let mut motion = FrameMotion {
            tl_ns: 42,
            ..FrameMotion::default()
        };
        unsafe {
            assert_eq!(yc_frame_motion_at(&h, -1, &mut motion), 1);
            assert_eq!(motion.tl_ns, 42);
            assert_eq!(yc_frame_motion_at(std::ptr::null(), 0, &mut motion), 1);
            assert_eq!(yc_frame_motion_at(&h, 0, std::ptr::null_mut()), 1);
        }
        assert_eq!(
            crate::allocation_test::count(|| {
                assert_eq!(
                    unsafe { yc_frame_motion_at(&h, 350_000_000, &mut motion) },
                    0
                );
            }),
            0
        );
        let (f, p) = make();
        let sources = p.query(&json!({"q":"music_library"})).unwrap();
        assert_eq!(sources.as_array().unwrap().len(), 2);
        assert_eq!(sources[0]["duration_ns"], json!(8_000_000_000_i64));
        drop(f);
    }
    #[test]
    fn master_blur_scales_all_kinds_without_changing_legacy_choices() {
        let (_f, mut p) = make();
        p.data.zoom_settings.physics_version = 1;
        p.apply(&json!({"op":"batch","commands":[
            {"op":"set","path":"cursor.motion_blur","value":0.8},
            {"op":"set","path":"canvas.motion_blur","value":0.6},
            {"op":"add_zoom","zoom":{"tl_start_ns":0,"tl_end_ns":2_000_000_000_i64,"target":[0.5,0.5],"mode":"manual","scale":2,"ease_in_ns":1_000_000_000,"ease_out_ns":0}}
        ]})).unwrap();
        let base = p.frame_motion(50_000_000).unwrap();
        assert!(base.cursor_motion_blur > 0.0 && base.zoom_motion_blur > 0.0);
        for amount in [0.0, 0.5, 1.0] {
            p.apply(&json!({"op":"set","path":"canvas.global_motion_blur","value":amount}))
                .unwrap();
            let m = p.frame_motion(50_000_000).unwrap();
            assert!((m.cursor_motion_blur - base.cursor_motion_blur * amount as f32).abs() < 1e-6);
            assert!((m.zoom_motion_blur - base.zoom_motion_blur * amount as f32).abs() < 1e-6);
            assert!((m.pan_motion_blur - base.pan_motion_blur * amount as f32).abs() < 1e-6);
            assert!(
                (p.frame_extras(50_000_000).unwrap().cursor_motion_blur - 0.8 * amount as f32)
                    .abs()
                    < 1e-6
            );
            assert!((p.frame(50_000_000).unwrap().motion_blur - 0.6 * amount as f32).abs() < 1e-6);
            assert_eq!(
                p.query(&json!({"q":"render_options_at","tl_ns":50_000_000}))
                    .unwrap()["cursor_motion_blur"],
                json!(m.cursor_motion_blur as f64)
            );
        }
        let mut legacy = serde_json::to_value(&p.data).unwrap();
        legacy["canvas"]
            .as_object_mut()
            .unwrap()
            .remove("global_motion_blur");
        p.data = crate::project::decode_project(&serde_json::to_vec(&legacy).unwrap()).unwrap();
        assert_eq!(p.data.canvas.global_motion_blur, None);
        assert_eq!(p.frame_motion(50_000_000).unwrap(), base);
        let before = p.data.clone();
        assert!(p
            .apply(&json!({"op":"set","path":"canvas.global_motion_blur","value":1.1}))
            .is_err());
        assert_eq!(p.data, before);
    }
}

#[cfg(test)]
mod pan_and_camera_regressions {
    use super::*;
    use crate::{
        input::InputCache,
        model::{CameraTrack, Event},
        project::tests::Fixture,
    };
    use serde_json::json;
    #[test]
    fn bs4_auto_follow_uses_screen_spring_and_none_is_raw() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        let event = |t, x| Event {
            t,
            kind: "move".into(),
            x: Some(x),
            y: Some(100.0),
            id: None,
            details: Default::default(),
        };
        p.data.cursor.remove_shakes = false;
        p.events[0] = vec![
            event(0, 160.0),
            event(999_999_999, 160.0),
            event(1_000_000_000, 320.0),
            event(4_000_000_000, 320.0),
        ];
        p.input[0] = InputCache::new(&p.events[0]);
        p.apply(&json!({"op":"add_zoom","zoom":{"tl_start_ns":0,"tl_end_ns":4_500_000_000_i64,"mode":"auto","scale":2,"target":[0.5,0.5],"ease_in_ns":0,"ease_out_ns":0}})).unwrap();

        p.data.zoom_settings.animation_style = "none".into();
        let start = p.frame(900_000_000).unwrap().screen_crop.x;
        let raw = p.frame(1_016_666_667).unwrap().screen_crop.x;
        assert!(raw > start);
        p.data.zoom_settings.animation_style = "smooth".into();
        let fraction = |t| (p.frame(t).unwrap().screen_crop.x - start) / (raw - start);
        assert!(fraction(1_050_000_000) < 0.30);
        assert!((0.70..=0.95).contains(&fraction(1_500_000_000)));
        assert!(fraction(2_100_000_000) >= 0.99);
        p.data.zoom_settings.animation_style = "custom".into();
        assert!((p.frame(1_050_000_000).unwrap().screen_crop.x - start) / (raw - start) < 1.0);
        p.data.zoom_settings.animation_style = "none".into();
        assert!(
            ((p.frame(1_016_666_667).unwrap().screen_crop.x - start) / (raw - start) - 1.0).abs()
                < 1e-12
        );
        assert_eq!(
            crate::allocation_test::count(|| {
                std::hint::black_box(p.frame(1_500_000_000).unwrap());
            }),
            0
        );
    }
    #[test]
    fn focused_and_smooth_pan_settle_differently_with_crop_and_clamp_bounds() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        let event = |t, x| Event {
            t,
            kind: "move".into(),
            x: Some(x),
            y: Some(100.0),
            id: None,
            details: Default::default(),
        };
        p.events[0] = vec![
            event(0, 160.0),
            event(400_000_000, 160.0),
            event(500_000_000, 250.0),
            event(1_000_000_000, 250.0),
        ];
        p.input[0] = InputCache::new(&p.events[0]);
        p.apply(&json!({"op":"batch","commands":[{"op":"set","path":"canvas.crop","value":[0.1,0.1,0.7,0.7]},{"op":"add_zoom","zoom":{"tl_start_ns":0,"tl_end_ns":2_000_000_000,"mode":"auto","scale":3,"target":[0.5,0.5],"ease_in_ns":0,"ease_out_ns":0}},{"op":"set","path":"canvas.motion_blur_settings.pan","value":0.8},{"op":"set","path":"canvas.motion_blur_settings.zoom","value":0}]})).unwrap();
        p.apply(&json!({"op":"set","path":"zoom_settings.animation_style","value":"focused"}))
            .unwrap();
        let focused = p.frame(550_000_000).unwrap();
        p.apply(&json!({"op":"set","path":"zoom_settings.animation_style","value":"smooth"}))
            .unwrap();
        let smooth = p.frame(550_000_000).unwrap();
        assert!((focused.screen_crop.x - smooth.screen_crop.x).abs() > 1e-5);
        let motion = p.frame_motion(550_000_000).unwrap();
        assert_eq!(motion.pan_motion_blur, 0.8);
        assert_eq!(motion.zoom_motion_blur, 0.0);
        assert_eq!(smooth.motion_blur, motion.pan_motion_blur);
        assert_eq!(p.frame_motion(1_200_000_000).unwrap().pan_motion_blur, 0.8);
        assert_eq!(p.frame_motion(2_200_000_000).unwrap().pan_motion_blur, 0.0);
        for style in ["custom", "focused", "smooth"] {
            p.apply(&json!({"op":"set","path":"zoom_settings.animation_style","value":style}))
                .unwrap();
            for t in [0, 1, 500_000_000, 550_000_000, 1_200_000_000] {
                let frame = p.frame(t).unwrap();
                assert!(
                    frame.screen_crop.x >= 0.1
                        && frame.screen_crop.x + frame.screen_crop.w <= 0.8 + 1e-15
                );
                assert!(
                    frame.screen_crop.y >= 0.1
                        && frame.screen_crop.y + frame.screen_crop.h <= 0.8 + 1e-15
                );
            }
        }
        assert_eq!(
            crate::allocation_test::count(|| {
                p.frame(550_000_000).unwrap();
                p.frame_motion(550_000_000).unwrap();
            }),
            0
        );
    }
    #[test]
    fn camera_zoom_respects_fitted_layouts_and_remains_in_canvas() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.session.tracks.camera = Some(CameraTrack {
            device_name: "procedural".into(),
            pixel_size: [1280, 800],
            fps: 30.0,
            mirrored: false,
        });
        let file = p.session.segments[0].files["screen"].clone();
        p.session.segments[0].files.insert("camera".into(), file);
        p.apply(&json!({"op":"batch","commands":[{"op":"set","path":"canvas.aspect","value":"custom"},{"op":"set","path":"canvas.output_size","value":[1280,768]},{"op":"set","path":"camera.size","value":1},{"op":"set","path":"camera.position","value":[1,1]},{"op":"set","path":"camera.zoom_scale","value":4},{"op":"add_zoom","zoom":{"tl_start_ns":0,"tl_end_ns":2_000_000_000,"target":[0.5,0.5],"scale":2,"mode":"manual","ease_in_ns":0,"ease_out_ns":0}}]})).unwrap();
        for t in [0, 1, 1_000_000_000] {
            let d = p.frame(t).unwrap().camera_dest;
            assert!(d.x >= 0.0 && d.y >= 0.0 && d.x + d.w <= 1280.0 && d.y + d.h <= 768.0);
        }
        for mode in ["camera", "side_by_side"] {
            p.apply(&json!({"op":"set","path":"camera.layouts","value":[{"id":"fit","tl_start_ns":0,"tl_end_ns":2_000_000_000,"mode":mode}]})).unwrap();
            let large = p.frame(1_000_000_000).unwrap().camera_dest;
            p.apply(&json!({"op":"set","path":"camera.zoom_scale","value":1}))
                .unwrap();
            assert_eq!(p.frame(1_000_000_000).unwrap().camera_dest, large);
            p.apply(&json!({"op":"set","path":"camera.zoom_scale","value":4}))
                .unwrap();
        }
    }
}
