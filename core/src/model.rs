//! Schema 1 project/session types. Coordinates for effects are normalized unless
//! explicitly named points or pixels; durations and event clocks are nanoseconds.
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const SCHEMA_VERSION: u32 = 1;
/// Stable Render-owned wallpaper selected by the revision-3 project factory.
/// The index is its zero-based position in `BackgroundLibrary.presets`.
pub const FACTORY_WALLPAPER_ID: &str = "deep-slate";
pub const FACTORY_WALLPAPER_INDEX: u32 = 1;

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
    #[serde(default)]
    pub display_name: Option<String>,
    pub content_rect_points: [f64; 4],
    pub scale: f64,
    pub window_title: Option<String>,
    pub app_bundle_id: Option<String>,
}
impl Source {
    pub(crate) fn display_name_or_default(&self) -> String {
        self.display_name
            .as_deref()
            .filter(|name| !name.trim().is_empty())
            .or_else(|| {
                (self.kind == "window")
                    .then_some(self.window_title.as_deref())
                    .flatten()
                    .filter(|title| !title.trim().is_empty())
            })
            .map(str::to_owned)
            .unwrap_or_else(|| format!("Display {}", self.display_id))
    }
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub speech_enhancement: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stereo_mic: Option<bool>,
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
    #[serde(default)]
    pub defaults_revision: u32,
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
    pub typing: TypingSettings,
    #[serde(default)]
    pub insertion_styles: InsertionStyles,
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
    pub captions: CaptionSettings,
    #[serde(default)]
    pub audio: Audio,
    #[serde(default, rename = "export")]
    pub export_settings: Export,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Media {
    pub path: String,
    pub size: u64,
    pub head_hash: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Timeline {
    pub clips: Vec<Clip>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Clip {
    pub id: String,
    pub src_start_ns: i64,
    pub src_end_ns: i64,
    pub speed: f64,
    #[serde(default, skip_serializing_if = "ClipSettings::is_default")]
    pub settings: ClipSettings,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Zoom {
    #[serde(default = "classic_zoom_style")]
    pub style: String,
    #[serde(default)]
    pub lens: ZoomLens,
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
fn classic_zoom_style() -> String {
    "classic".into()
}
fn enabled() -> bool {
    true
}
macro_rules! settings {
    ($name:ident { $($field:ident: $ty:ty = $value:expr),* $(,)? }) => {
        #[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
        #[serde(default, deny_unknown_fields)]
        pub struct $name { $(pub $field: $ty),* }
        impl Default for $name { fn default() -> Self { Self { $($field: $value),* } } }
    }
}
settings!(InsertionStyles { zoom:Option<ZoomInsertionStyle>=None, mask:Option<MaskInsertionStyle>=None });
settings!(ZoomLens {
    radius: f64 = 0.35,
    bevel: f64 = 0.2,
    chromatic_aberration: f64 = 0.5
});
settings!(ZoomInsertionStyle {
    style: String = "classic".into(),
    lens: ZoomLens = ZoomLens::default(),
    mode: String = "auto".into(),
    scale: f64 = 2.0,
    ease_in_ns: i64 = 300_000_000,
    ease_out_ns: i64 = 300_000_000
});
settings!(MaskInsertionStyle {
    kind: String = "highlight".into(),
    fill_policy: String = "custom".into(),
    blur_radius: f64 = 32.0,
    radius: f64 = 12.0,
    opacity: f64 = 1.0,
    dim_opacity: f64 = 0.4,
    fill: [f32; 4] = [1.0, 0.85, 0.2, 0.0],
    stroke: [f32; 4] = [1.0, 0.85, 0.2, 1.0],
    stroke_width: f64 = 3.0
});
settings!(ClipSettings {
    mic_gain: f64 = 1.0,
    system_gain: f64 = 1.0,
    external_gain: f64 = 1.0,
    hide_cursor: bool = false,
    disable_smoothing: bool = false
});
impl ClipSettings {
    fn is_default(&self) -> bool {
        self == &Self::default()
    }
}
settings!(TypingSettings { speed: f64 = 3.0, dismissed: Vec<String> = vec![] });
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CursorVariant {
    Standard,
    Alternate,
}
settings!(CursorVariants {
    arrow: CursorVariant = CursorVariant::Standard,
    pointing_hand: CursorVariant = CursorVariant::Standard,
    touch: CursorVariant = CursorVariant::Standard,
    text: CursorVariant = CursorVariant::Standard,
    resize_horizontal: CursorVariant = CursorVariant::Standard,
    resize_vertical: CursorVariant = CursorVariant::Standard,
    resize_diagonal_nwse: CursorVariant = CursorVariant::Standard,
    resize_diagonal_nesw: CursorVariant = CursorVariant::Standard,
    open_hand: CursorVariant = CursorVariant::Standard,
    closed_hand: CursorVariant = CursorVariant::Standard,
    crosshair: CursorVariant = CursorVariant::Standard,
    not_allowed: CursorVariant = CursorVariant::Standard,
});
settings!(Cursor {
    visible: bool = true, size: f64 = 1.0, size_points: Option<f64> = None, physics_version: u32 = 0, smoothing: f64 = 0.15,
    hide_when_idle: bool = false, idle_timeout_ns: i64 = 2_000_000_000,
    click_effect: String = "ring".into(), click_duration_ns: i64 = 400_000_000,
    speed_preset: String = "custom".into(), spring: Spring = Spring::default(),
    ranges: Vec<CursorRange> = vec![], loop_to_start: bool = false,
    loop_duration_ns: i64 = 400_000_000,
    style: String = "recorded".into(), motion_blur: f64 = 0.0,
    set_id: Option<String> = None, shape: Option<String> = None,
    variants: CursorVariants = CursorVariants::default(),
    logical_size: String = "regular".into(),
    spotlight_radius: f64 = 0.0, key_overlay: KeyOverlay = KeyOverlay::default(),
    always_default: bool = false,
    use_default_if_app_has_low_resolution: bool = true, rotate_on_move: bool = false,
    rotation_mode: String = "static".into(), rotation_degrees: f64 = 0.0,
    tilt_amount: f64 = 1.0, shake_threshold: f64 = 500.0,
    blend_cuts: bool = false,
    stop_before_end_ns: i64 = 0, remove_shakes: bool = false, optimize_types: bool = false,
});
/// Normalize persisted legacy cursor fields or a portable cursor patch. Never
/// replace a supplied threshold; old enabled deadbands were exactly one point.
pub(crate) fn migrate_cursor(value: &mut serde_json::Value, legacy_threshold: bool) {
    let Some(fields) = value.as_object_mut() else {
        return;
    };
    if let Some(mode) = fields
        .get("rotation_mode")
        .and_then(serde_json::Value::as_str)
    {
        let tilt = matches!(mode, "tilt" | "follow");
        fields.insert("rotate_on_move".into(), tilt.into());
    } else if let Some(tilt) = fields
        .get("rotate_on_move")
        .and_then(serde_json::Value::as_bool)
    {
        fields.insert(
            "rotation_mode".into(),
            if tilt { "tilt" } else { "static" }.into(),
        );
    }
    if legacy_threshold && !fields.contains_key("shake_threshold") {
        fields.insert("shake_threshold".into(), 1000.into());
    }
}
settings!(Spring {
    tension: f64 = 250.0,
    friction: f64 = 28.0,
    mass: f64 = 1.0,
    allow_overshoot: bool = false
});
settings!(ZoomSettings {
    physics_version: u32 = 0,
    default_scale: f64 = 2.0,
    start_early: bool = false,
    animation_style: String = "custom".into(),
    automatic: bool = true,
    smart_framing: bool = false,
    follow_cursor: bool = true,
    dead_zone: f64 = 0.15,
    speed_preset: String = "custom".into(),
    spring: Spring = Spring::default()
});
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct CursorRange {
    pub tl_start_ns: i64,
    pub tl_end_ns: i64,
    pub visible: bool,
}
settings!(CameraStyle {
    preset: String = "original".into(), intensity: f64 = 1.0,
    warmth: f64 = 0.0, background_pop: f64 = 0.2, contrast: f64 = 0.25,
    color_intensity: f64 = 0.15, sharpen: f64 = 0.0, grain: f64 = 0.0,
    background_blur: f64 = 0.0, crop: [f64; 4] = [0.0,0.0,1.0,1.0],
    lut_path: Option<String> = None
});
settings!(CameraLayoutSettings {
    mode: String = "overlay".into(), aspect: Option<f64> = None,
    split_direction: String = "auto".into(),
    split_ratio: Option<f64> = None, split_flip: bool = false, split_padded: bool = false,
    cutout_position: [f64; 2] = [1.0,1.0], cutout_size: f64 = 0.5,
    edge_softness: f64 = 0.2, edge_inset: f64 = 0.0, corner_ratio: Option<f64> = None,
    edge_padding_ratio: f64 = 0.0, edge_distance_ratio: Option<f64> = None
});
settings!(Camera {
    layout_settings: CameraLayoutSettings = CameraLayoutSettings::default(),
    hide_during_silence: bool = false, min_silence_ns: i64 = 5_000_000_000,
    silence_ranges: Vec<ActivityRange> = vec![],
    speech_activity: Option<SpeechActivity> = None,
    style: CameraStyle = CameraStyle::default(),
    visible: bool = true, position: [f64; 2] = [0.82, 0.78], size: f64 = 0.22,
    shape: String = "rounded_rect".into(), radius: f64 = 24.0, roundness: Option<f64> = None,
    mirrored: bool = true, opacity: f64 = 1.0, layouts: Vec<Layout> = vec![],
    shadow_radius: f64 = 0.0, background_removal: bool = false,
    face_framing: bool = false, zoom_scale: f64 = 1.0,
});
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Layout {
    #[serde(default = "enabled")]
    pub enabled: bool,
    #[serde(default)]
    pub settings: Option<CameraLayoutSettings>,
    pub id: String,
    pub tl_start_ns: i64,
    pub tl_end_ns: i64,
    pub mode: String,
    #[serde(default)]
    pub camera_position: Option<[f64; 2]>,
    #[serde(default)]
    pub camera_size: Option<f64>,
    #[serde(default)]
    pub camera_background_removal: Option<bool>,
    #[serde(default)]
    pub camera_face_framing: Option<bool>,
    #[serde(default)]
    pub camera_shadow_radius: Option<f64>,
}
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct ScreenQuality {
    pub improve_quality: f64,
    pub upscaling: String,
}
impl Default for ScreenQuality {
    fn default() -> Self {
        Self {
            improve_quality: 0.5,
            upscaling: "quality".into(),
        }
    }
}
impl<'de> Deserialize<'de> for ScreenQuality {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        use serde::de::Error;
        let raw = serde_json::Value::deserialize(deserializer)?;
        let object = raw
            .as_object()
            .ok_or_else(|| D::Error::custom("Screen quality must be an object"))?;
        if object
            .keys()
            .any(|key| !matches!(key.as_str(), "improve_quality" | "upscaling"))
        {
            return Err(D::Error::custom("Unknown screen quality field"));
        }
        let mut result = Self::default();
        if let Some(value) = object.get("improve_quality") {
            result.improve_quality = value
                .as_f64()
                .ok_or_else(|| D::Error::custom("Screen quality amount must be a number"))?;
        }
        if let Some(value) = object.get("upscaling") {
            result.upscaling = value
                .as_str()
                .ok_or_else(|| D::Error::custom("Screen upscaling must be a string"))?
                .into();
        }
        Ok(result)
    }
}
settings!(Canvas {
    screen_quality: Option<ScreenQuality> = None,
    device_frame: Option<String> = None,
    aspect: String = "16:9".into(),
    avoid_empty_zoom_area: bool = false, keep_zoomed: bool = false, auto_layout: bool = false,
    output_size: [u32; 2] = [1920, 1080],
    background: Background = Background::default(),
    padding: f64 = 48.0, padding_ratio: Option<f64> = None,
    radius: f64 = 18.0,
    shadow: Shadow = Shadow::default(),
    inset: f64 = 0.0,
    inset_origin: [f64; 2] = [0.0, 0.0],
    inset_color: [f32; 4] = [1.0, 1.0, 1.0, 1.0],
    motion_blur: f64 = 0.0,
    global_motion_blur: Option<f64> = None,
    motion_blur_settings: MotionBlurSettings = MotionBlurSettings::default(),
    crop: [f64; 4] = [0.0, 0.0, 1.0, 1.0],
    window_chrome: bool = false, highlights: Vec<Highlight> = vec![],
    animation: Animation = Animation::default(),
    annotations: Vec<TextRecord> = vec![], reactions: Vec<TextRecord> = vec![],
    captions: Vec<TextRecord> = vec![],
});
settings!(CaptionSettings {
    hidden: bool = false
});
settings!(Highlight {
    enabled: bool = true, keyframes: Vec<MaskKeyframe> = vec![],
    id: String = String::new(),
    tl_start_ns: i64 = 0,
    tl_end_ns: i64 = 1,
    rect: [f64; 4] = [0.25, 0.25, 0.5, 0.5],
    space: String = "source".into(),
    kind: String = "highlight".into(),
    fill_policy: String = "custom".into(),
    blur_radius: f64 = 32.0,
    radius: f64 = 12.0,
    opacity: f64 = 1.0,
    dim_opacity: f64 = 0.4,
    fill: [f32; 4] = [1.0, 0.85, 0.2, 0.0],
    stroke: [f32; 4] = [1.0, 0.85, 0.2, 1.0],
    stroke_width: f64 = 3.0,
});
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct MaskKeyframe {
    pub tl_ns: i64,
    pub rect: [f64; 4],
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SourceActivityRange {
    pub src_start_ns: i64,
    pub src_end_ns: i64,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SpeechActivity {
    pub source: String,
    pub coverage_start_ns: i64,
    pub coverage_end_ns: i64,
    pub ranges: Vec<SourceActivityRange>,
}
settings!(MotionBlurSettings { zoom: Option<f64> = None, pan: Option<f64> = None });
settings!(Animation {
    entrance: String = "none".into(),
    exit: String = "none".into(),
    entrance_duration_ns: i64 = 400_000_000,
    exit_duration_ns: i64 = 400_000_000,
});
settings!(Background {
    kind: String = "solid".into(),
    color: [f32; 4] = [0.12, 0.14, 0.18, 1.0],
    color2: [f32; 4] = [0.24, 0.29, 0.38, 1.0],
    angle_deg: f64 = 45.0,
    asset: u32 = 0,
    wallpaper_id: Option<String> = None,
    wallpaper_index: Option<u32> = None,
    blur: f64 = 24.0,
    noise: f64 = 0.0,
});
settings!(Shadow {
    style: String = "classic".into(),
    distance: f64 = 25.0,
    angle_deg: f64 = 45.0,
    blur: f64 = 20.0,
    radius: f64 = 24.0,
    opacity: f64 = 0.3,
    offset_y: f64 = 8.0
});
impl Shadow {
    pub fn evaluated(&self) -> (f64, f64, f64) {
        if self.style == "directional" {
            let radians = self.angle_deg.to_radians();
            (
                self.distance * radians.cos(),
                self.distance * radians.sin(),
                self.blur * 8.0,
            )
        } else {
            (0.0, self.offset_y, self.radius)
        }
    }
}
settings!(Audio { mic_preset: String = "voice".into(), stereo_mic: bool = false, music_volume: f64 = 0.05, mic_gain_db: f64 = 0.0, system_gain_db: f64 = 0.0,
    mic_replacements: Vec<MicrophoneReplacement> = vec![],
    mic_muted: bool = false, system_muted: bool = false, ranges: Vec<AudioRange> = vec![],
    music: Vec<MusicTrack> = vec![], click_sound: ClickSound = ClickSound::default(),
    speech_enhancement: bool = false,
    speech_enhancement_settings: SpeechEnhancementSettings = SpeechEnhancementSettings::default() });
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct MicrophoneReplacement {
    pub original: Media,
    pub enhanced: Media,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct AudioRange {
    pub id: String,
    pub track: String,
    pub tl_start_ns: i64,
    pub tl_end_ns: i64,
    pub start_gain_db: f64,
    pub end_gain_db: f64,
}
settings!(SpeechEnhancementSettings {
    high_pass_hz: f64 = 90.0,
    noise_threshold_db: f64 = -45.0,
    noise_reduction_db: f64 = 30.0,
    compressor_threshold_db: f64 = -24.0,
    compressor_ratio: f64 = 3.0,
    target_lufs: f64 = -16.0,
    peak_ceiling_dbfs: f64 = -1.0,
    normalize_loudness: bool = true,
});
settings!(TextStyle {
    font_family: String = "sans".into(),
    reveal: String = "line".into(),
    growth: String = "full".into(),
    entrance: String = "appear".into(),
    language: String = "auto".into(),
    font_size: f64 = 36.0,
    font_size_ratio: Option<f64> = None,
    color: [f32; 4] = [1.0, 1.0, 1.0, 1.0],
    background: [f32; 4] = [0.0, 0.0, 0.0, 0.65],
    radius: f64 = 12.0,
    opacity: f64 = 1.0,
});
settings!(TextRecord {
    words: Vec<CaptionWord> = vec![],
    id: String = String::new(),
    tl_start_ns: i64 = 0,
    tl_end_ns: i64 = 1,
    text: String = String::new(),
    rect: [f64; 4] = [0.1, 0.75, 0.8, 0.15],
    space: String = "canvas".into(),
    style: TextStyle = TextStyle::default(),
});
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct CaptionWord {
    pub text: String,
    pub tl_start_ns: i64,
    pub tl_end_ns: i64,
}
impl<'de> Deserialize<'de> for CaptionWord {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        use serde::de::Error;
        let raw = serde_json::Value::deserialize(deserializer)?;
        let object = raw
            .as_object()
            .ok_or_else(|| D::Error::custom("Caption word must be an object"))?;
        if object
            .keys()
            .any(|key| !matches!(key.as_str(), "text" | "tl_start_ns" | "tl_end_ns"))
        {
            return Err(D::Error::custom("Unknown caption word field"));
        }
        let text = object
            .get("text")
            .and_then(|v| v.as_str())
            .ok_or_else(|| D::Error::custom("Missing caption word text"))?;
        let start = object
            .get("tl_start_ns")
            .and_then(|v| v.as_i64())
            .ok_or_else(|| D::Error::custom("Missing integer caption word start"))?;
        let end = object
            .get("tl_end_ns")
            .and_then(|v| v.as_i64())
            .ok_or_else(|| D::Error::custom("Missing integer caption word end"))?;
        Ok(Self {
            text: text.into(),
            tl_start_ns: start,
            tl_end_ns: end,
        })
    }
}
settings!(KeyOverlay {
    enabled: bool = false,
    duration_ns: i64 = 1_000_000_000,
    shortcuts_only: bool = true,
    hidden_shortcuts: Vec<String> = vec![],
    disabled_events: Vec<u32> = vec![],
    rect: [f64; 4] = [0.3, 0.82, 0.4, 0.12],
    style: TextStyle = TextStyle::default(),
});
settings!(ClickSound {
    enabled: bool = false,
    variant: String = "soft".into(),
    gain_db: f64 = -12.0
});
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ActivityRange {
    pub tl_start_ns: i64,
    pub tl_end_ns: i64,
}
settings!(Ducking {
    enabled: bool = false, gain_db: f64 = -12.0, attack_ns: i64 = 50_000_000,
    release_ns: i64 = 200_000_000, ranges: Vec<ActivityRange> = vec![],
});
settings!(MusicTrack {
    id: String = String::new(),
    tl_start_ns: i64 = 0,
    tl_end_ns: i64 = 1,
    source: String = "file".into(),
    path: String = String::new(),
    file_start_ns: i64 = 0,
    file_duration_ns: i64 = 0,
    gain_db: f64 = -18.0,
    r#loop: bool = true,
    fade_in_ns: i64 = 500_000_000,
    fade_out_ns: i64 = 500_000_000,
    library_id: Option<String> = None,
    ducking: Ducking = Ducking::default(),
});
settings!(Export {
    last_preset: String = "mp4-1080p".into()
});

impl ProjectData {
    pub fn from_session(session: &Session, id: String) -> Self {
        let end = session
            .segments
            .last()
            .map_or(0, |s| s.src_start_ns + s.duration_ns);
        let mut data = Self {
            defaults_revision: 4,
            schema_version: SCHEMA_VERSION,
            id,
            created_at: session.created_at.clone(),
            modified_at: session.created_at.clone(),
            recording: "recording/session.json".into(),
            media: vec![],
            timeline: Timeline {
                clips: if end > 0 {
                    vec![Clip {
                        id: "clip-1".into(),
                        src_start_ns: 0,
                        src_end_ns: end,
                        speed: 1.0,
                        settings: Default::default(),
                    }]
                } else {
                    vec![]
                },
            },
            zooms: vec![],
            cursor: Cursor::default(),
            camera: Camera::default(),
            canvas: Canvas::default(),
            captions: CaptionSettings::default(),
            audio: Audio::default(),
            export_settings: Export::default(),
            zoom_settings: ZoomSettings::default(),
            typing: TypingSettings::default(),
            insertion_styles: InsertionStyles::default(),
            notes: String::new(),
            autosave: true,
        };
        data.canvas.aspect = "source".into();
        data.canvas.padding_ratio = Some(0.10);
        data.canvas.radius = 16.0;
        data.canvas.shadow.style = "directional".into();
        // Render's own Deep Slate library entry is an analytic gradient, so its
        // persisted palette renders through the existing ABI while the stable
        // identity/index let picker consumers restore Wallpaper selection.
        data.canvas.background.kind = "gradient".into();
        data.canvas.background.color = [
            0x18 as f32 / 255.0,
            0x2b as f32 / 255.0,
            0x42 as f32 / 255.0,
            1.0,
        ];
        data.canvas.background.color2 = [
            0x70 as f32 / 255.0,
            0x69 as f32 / 255.0,
            0x88 as f32 / 255.0,
            1.0,
        ];
        data.canvas.background.angle_deg = 115.0;
        data.canvas.background.wallpaper_id = Some(FACTORY_WALLPAPER_ID.into());
        data.canvas.background.wallpaper_index = Some(FACTORY_WALLPAPER_INDEX);
        data.canvas.background.blur = 0.0;
        data.canvas.motion_blur = 1.0;
        data.canvas.global_motion_blur = Some(1.0);
        data.cursor.size_points = Some(48.0);
        data.cursor.set_id = Some("original".into());
        data.cursor.click_effect = "none".into();
        data.cursor.smoothing = 1.0;
        // Softer than the "smooth" preset (470/70/3) and still critically damped: no float, no overshoot.
        data.cursor.speed_preset = "custom".into();
        data.cursor.spring = Spring {
            tension: 250.0,
            friction: 55.0,
            mass: 3.0,
            allow_overshoot: false,
        };
        data.cursor.physics_version = 1;
        data.cursor.blend_cuts = true;
        data.cursor.motion_blur = 1.0;
        data.zoom_settings.physics_version = 2;
        // A calm camera move (~1.2 s, critically damped) instead of "smooth" (170/50/3, ~0.8 s); the 1.5 s
        // ease gives the spring room to settle before the zoom holds and after it ends.
        data.zoom_settings.animation_style = "custom".into();
        data.zoom_settings.speed_preset = "custom".into();
        data.zoom_settings.spring = Spring {
            tension: 70.0,
            friction: 30.0,
            mass: 3.0,
            allow_overshoot: false,
        };
        data.insertion_styles.zoom = Some(ZoomInsertionStyle {
            ease_in_ns: 1_500_000_000,
            ease_out_ns: 1_500_000_000,
            ..ZoomInsertionStyle::default()
        });
        data.camera.mirrored = false;
        data.camera.position = [1.0, 1.0];
        data.camera.size = 0.5;
        data.camera.zoom_scale = 0.6;
        data.camera.layout_settings.aspect = Some(1.0);
        data.camera.layout_settings.corner_ratio = Some(0.15);
        data.camera.layout_settings.edge_padding_ratio = 0.5;
        data.camera.layout_settings.edge_distance_ratio = Some(0.03);
        data.cursor.loop_duration_ns = 1_000_000_000;
        data.cursor.remove_shakes = true;
        data.cursor.optimize_types = true;
        data.cursor.rotation_mode = "tilt".into();
        data.cursor.rotate_on_move = true;
        data.cursor.tilt_amount = 0.5;
        data.zoom_settings.smart_framing = true;
        data.canvas.auto_layout = true;
        data.cursor.key_overlay.style.font_size = 108.0;
        data.cursor.key_overlay.style.font_size_ratio = Some(0.1);
        data.canvas.inset_color = [0.0, 0.0, 0.0, 0.5];
        data.canvas.screen_quality = Some(ScreenQuality::default());
        data.audio.click_sound.gain_db = 20.0 * 0.25_f64.log10();
        if let Some(mic) = &session.tracks.mic {
            data.audio.speech_enhancement = mic.speech_enhancement.unwrap_or(false);
            data.audio.stereo_mic = mic.stereo_mic.unwrap_or(false);
        }
        data
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn synthetic_session_and_project_roundtrip() {
        let mut s: Session = serde_json::from_str(include_str!(
            "../../Tests/Fixtures/synthetic/basic.yapcam/recording/session.json"
        ))
        .unwrap();
        assert_eq!(s.segments.len(), 2);
        assert_eq!(s.segments[1].src_start_ns, 3_000_000_000);
        let p = ProjectData::from_session(&s, "test".into());
        assert_eq!(p.timeline.clips[0].src_end_ns, 5_000_000_000);
        assert_eq!(
            p,
            serde_json::from_str::<ProjectData>(&serde_json::to_string(&p).unwrap()).unwrap()
        );
        for line in include_str!(
            "../../Tests/Fixtures/synthetic/basic.yapcam/recording/seg-000/events.jsonl"
        )
        .lines()
        {
            let event: Event = serde_json::from_str(line).unwrap();
            assert!(event.t >= 0);
        }
        s.tracks.mic = Some(AudioTrack {
            device_name: Some("Stereo fixture".into()),
            sample_rate: 48_000,
            channels: 2,
            speech_enhancement: Some(true),
            stereo_mic: Some(true),
        });
        let captured = ProjectData::from_session(&s, "captured-options".into());
        assert!(captured.audio.speech_enhancement);
        assert!(captured.audio.stereo_mic);
    }
}
