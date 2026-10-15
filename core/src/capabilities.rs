//! Read-only capability policy shared by cold UI queries and frame evaluation.
use crate::project::Project;
use serde::Serialize;
pub(crate) fn external(kind: &str) -> bool {
    matches!(
        kind,
        "device"
            | "external"
            | "external_device"
            | "iphone"
            | "ipad"
            | "continuity"
            | "screen_continuity"
    )
}
#[derive(Clone, Copy, Debug, Serialize)]
pub(crate) struct Capabilities {
    pub can_crop: bool,
    pub can_round_corners: bool,
    pub can_inset: bool,
    pub can_cursor: bool,
    pub can_auto_zoom: bool,
    pub can_camera: bool,
    pub can_camera_layouts: bool,
    pub can_external_audio: bool,
    pub device_frame_active: bool,
    pub external_recording: bool,
}
impl Project {
    pub(crate) fn capabilities(&self) -> Capabilities {
        let external_recording = external(&self.session.source.kind);
        let device_frame_active = self.data.canvas.device_frame.is_some();
        let geometry = !external_recording && !device_frame_active;
        let mouse = self.input.iter().any(|i| i.mouse_data) && !external_recording;
        let camera = self.session.tracks.camera.is_some()
            && self
                .session
                .segments
                .iter()
                .any(|s| s.files.contains_key("camera"));
        Capabilities {
            can_crop: geometry,
            can_round_corners: geometry,
            can_inset: geometry,
            can_cursor: mouse && !self.session.tracks.screen.cursor_in_video,
            can_auto_zoom: mouse,
            can_camera: camera,
            can_camera_layouts: camera,
            can_external_audio: false,
            device_frame_active,
            external_recording,
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::tests::Fixture;
    use serde_json::json;
    #[test]
    fn gates_preserve_settings_and_frame_queries_remain_allocation_free() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.data.autosave = false;
        let c = p.capabilities();
        assert!(c.can_crop && c.can_cursor && c.can_auto_zoom);
        assert!(!c.can_camera);
        p.apply(&json!({"op":"batch","commands":[{"op":"set","path":"canvas.crop","value":[0.1,0.1,0.7,0.7]},{"op":"set","path":"canvas.radius","value":12},{"op":"set","path":"canvas.inset","value":4}]})).unwrap();
        let before = p.frame(0).unwrap();
        assert_eq!(before.screen_crop.w, 0.7);
        p.apply(&json!({"op":"set","path":"canvas.device_frame","value":"own-generic-frame"}))
            .unwrap();
        let f = p.frame(0).unwrap();
        assert_eq!(f.screen_crop.w, 1.0);
        assert_eq!(f.screen_corner_radius, 0.0);
        assert_eq!(f.inset_width, 0.0);
        assert_eq!(p.data.canvas.crop, [0.1, 0.1, 0.7, 0.7]);
        assert!(!p.capabilities().can_crop);
        p.undo().unwrap();
        assert_eq!(p.frame(0).unwrap().screen_crop, before.screen_crop);
        for kind in [
            "device",
            "external",
            "external_device",
            "iphone",
            "ipad",
            "continuity",
            "screen_continuity",
        ] {
            p.session.source.kind = kind.into();
            assert!(!p.capabilities().can_cursor);
            assert!(!p.capabilities().can_crop);
            assert_eq!(p.frame(0).unwrap().cursor_visible, 0);
        }
        p.apply(&json!({"op":"insert_zoom"})).unwrap();
        assert_eq!(p.data.zooms.last().unwrap().mode, "manual");
        p.session.source.kind = "import".into();
        assert!(p.capabilities().can_crop);
        p.input.iter_mut().for_each(|i| i.mouse_data = false);
        assert!(!p.capabilities().can_auto_zoom);
        assert_eq!(p.frame(0).unwrap().cursor_visible, 0);
        assert_eq!(
            crate::allocation_test::count(|| {
                p.frame(0).unwrap();
                p.frame_extras(0).unwrap();
            }),
            0
        );
    }
}
