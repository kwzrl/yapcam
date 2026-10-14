//! Schema 1 project/session types. Coordinates for effects are normalized unless
//! explicitly named points or pixels; durations and event clocks are nanoseconds.
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const SCHEMA_VERSION: u32 = 1;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Session {
    pub schema_version: u32,
    pub app_version: String,
    pub created_at: String,
    pub status: String,
    pub source: Source,
    pub tracks: Tracks,
    pub segments: Vec<Segment>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Source {
    pub kind: String,
    pub display_id: u32,
    pub display_name: String,
    pub content_rect_points: [f64; 4],
    pub scale: f64,
    pub window_title: Option<String>,
    pub app_bundle_id: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Tracks {
    pub screen: ScreenTrack,
    pub camera: Option<CameraTrack>,
    pub mic: Option<AudioTrack>,
    pub system_audio: Option<AudioTrack>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ScreenTrack {
    pub pixel_size: [u32; 2],
    pub max_fps: u32,
    pub codec: String,
    pub cursor_in_video: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct CameraTrack {
    pub device_name: String,
    pub pixel_size: [u32; 2],
    pub fps: f64,
    pub mirrored: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct AudioTrack {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_name: Option<String>,
    pub sample_rate: u32,
    pub channels: u32,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Segment {
    pub index: u32,
    pub dir: String,
    pub src_start_ns: i64,
    pub duration_ns: i64,
    pub host_start_ns: i64,
    pub files: BTreeMap<String, String>,
    #[serde(default)]
    pub track_start_ns: BTreeMap<String, i64>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Event {
    pub t: i64,
    #[serde(rename = "type")]
    pub kind: String,
    pub x: Option<f64>,
    pub y: Option<f64>,
    pub id: Option<u32>,
    #[serde(flatten)]
    pub details: BTreeMap<String, serde_json::Value>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ProjectData {
    pub schema_version: u32,
    pub id: String,
    pub created_at: String,
    pub modified_at: String,
    pub recording: String,
    #[serde(default)]
    pub media: Vec<Media>,
    pub timeline: Timeline,
    #[serde(default)]
    pub zooms: Vec<Zoom>,
    #[serde(default)]
    pub zoom_settings: ZoomSettings,
    #[serde(default)]
    pub notes: String,
    #[serde(default = "enabled")]
    pub autosave: bool,
    #[serde(default)]
    pub cursor: Cursor,
    #[serde(default)]
    pub camera: Camera,
    #[serde(default)]
    pub canvas: Canvas,
    #[serde(default)]
    pub audio: Audio,
    #[serde(default, rename = "export")]
    pub export_settings: Export,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Media { pub path: String, pub size: u64, pub head_hash: String }
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Timeline { pub clips: Vec<Clip> }
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Clip {
    pub id: String,
    pub src_start_ns: i64,
    pub src_end_ns: i64,
    pub speed: f64,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Zoom {
    pub id: String,
    pub tl_start_ns: i64,
    pub tl_end_ns: i64,
    pub mode: String,
    pub target: [f64; 2],
    pub scale: f64,
    pub ease_in_ns: i64,
    pub ease_out_ns: i64,
    #[serde(default = "enabled")]
    pub enabled: bool,
}
fn enabled() -> bool { true }
macro_rules! settings {
    ($name:ident { $($field:ident: $ty:ty = $value:expr),* $(,)? }) => {
        #[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
        #[serde(default, deny_unknown_fields)]
        pub struct $name { $(pub $field: $ty),* }
        impl Default for $name { fn default() -> Self { Self { $($field: $value),* } } }
    }
}
settings!(Cursor {
    visible: bool = true, size: f64 = 1.0, smoothing: f64 = 0.15,
    hide_when_idle: bool = false, idle_timeout_ns: i64 = 2_000_000_000,
    click_effect: String = "ring".into(), click_duration_ns: i64 = 400_000_000,
    speed_preset: String = "custom".into(), spring: Spring = Spring::default(),
    ranges: Vec<CursorRange> = vec![], loop_to_start: bool = false,
    loop_duration_ns: i64 = 400_000_000,
});
settings!(Spring { tension: f64 = 250.0, friction: f64 = 28.0, mass: f64 = 1.0, allow_overshoot: bool = false });
settings!(ZoomSettings { automatic: bool = true, follow_cursor: bool = true, dead_zone: f64 = 0.15,
    speed_preset: String = "custom".into(), spring: Spring = Spring::default() });
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct CursorRange { pub tl_start_ns: i64, pub tl_end_ns: i64, pub visible: bool }
settings!(Camera {
    visible: bool = true, position: [f64; 2] = [0.82, 0.78], size: f64 = 0.22,
    shape: String = "rounded_rect".into(), radius: f64 = 24.0,
    mirrored: bool = true, opacity: f64 = 1.0, layouts: Vec<Layout> = vec![],
});
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Layout {
    pub id: String, pub tl_start_ns: i64, pub tl_end_ns: i64,
    pub mode: String,
    #[serde(default)] pub camera_position: Option<[f64; 2]>,
    #[serde(default)] pub camera_size: Option<f64>,
}
settings!(Canvas {
    aspect: String = "16:9".into(), output_size: [u32; 2] = [1920, 1080],
    background: Background = Background::default(), padding: f64 = 48.0,
    radius: f64 = 18.0, shadow: Shadow = Shadow::default(),
    inset: f64 = 0.0, inset_color: [f32; 4] = [1.0, 1.0, 1.0, 1.0],
    motion_blur: f64 = 0.0, crop: [f64;4] = [0.0,0.0,1.0,1.0],
});
settings!(Background {
    kind: String = "solid".into(), color: [f32; 4] = [0.12, 0.14, 0.18, 1.0],
    color2: [f32; 4] = [0.24, 0.29, 0.38, 1.0], angle_deg: f64 = 45.0,
    asset: u32 = 0, blur: f64 = 24.0,
});
settings!(Shadow { radius: f64 = 24.0, opacity: f64 = 0.3, offset_y: f64 = 8.0 });
settings!(Audio { mic_gain_db: f64 = 0.0, system_gain_db: f64 = 0.0,
    mic_muted: bool = false, system_muted: bool = false, ranges: Vec<AudioRange> = vec![] });
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct AudioRange {
    pub id: String, pub track: String, pub tl_start_ns: i64, pub tl_end_ns: i64,
    pub start_gain_db: f64, pub end_gain_db: f64,
}
settings!(Export { last_preset: String = "mp4-1080p".into() });

impl ProjectData {
    pub fn from_session(session: &Session, id: String) -> Self {
        let end = session.segments.last().map_or(0, |s| s.src_start_ns + s.duration_ns);
        Self {
            schema_version: SCHEMA_VERSION, id, created_at: session.created_at.clone(),
            modified_at: session.created_at.clone(), recording: "recording/session.json".into(),
            media: vec![], timeline: Timeline { clips: if end > 0 { vec![Clip {
                id: "clip-1".into(), src_start_ns: 0, src_end_ns: end, speed: 1.0,
            }] } else { vec![] } }, zooms: vec![], cursor: Cursor::default(),
            camera: Camera::default(), canvas: Canvas::default(), audio: Audio::default(),
            export_settings: Export::default(), zoom_settings: ZoomSettings::default(), notes: String::new(), autosave:true,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn synthetic_session_and_project_roundtrip() {
        let s: Session = serde_json::from_str(include_str!("../../Tests/Fixtures/synthetic/basic.yapcam/recording/session.json")).unwrap();
        assert_eq!(s.segments.len(), 2);
        assert_eq!(s.segments[1].src_start_ns, 3_000_000_000);
        let p = ProjectData::from_session(&s, "test".into());
        assert_eq!(p.timeline.clips[0].src_end_ns, 5_000_000_000);
        assert_eq!(p, serde_json::from_str::<ProjectData>(&serde_json::to_string(&p).unwrap()).unwrap());
        for line in include_str!("../../Tests/Fixtures/synthetic/basic.yapcam/recording/seg-000/events.jsonl").lines() {
            let event: Event = serde_json::from_str(line).unwrap();
            assert!(event.t >= 0);
        }
    }
}
