//! Package persistence and cold-path runtime state.
use crate::model::*;
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Component, Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};

#[derive(Debug)]
pub struct Error {
    pub status: i32,
    pub message: String,
}
pub type Result<T> = std::result::Result<T, Error>;
impl Error {
    pub fn new(status: i32, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
        }
    }
}
impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Self::new(4, e.to_string())
    }
}
impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Self::new(2, e.to_string())
    }
}
static NEXT_ID: AtomicU64 = AtomicU64::new(1);
pub fn unique_id(prefix: &str) -> String {
    let t = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!(
        "{prefix}-{t:x}-{:x}",
        NEXT_ID.fetch_add(1, Ordering::Relaxed)
    )
}
#[derive(Clone)]
pub struct Project {
    pub data: ProjectData,
    pub session: Session,
    pub events: Vec<Vec<Event>>,
    pub input: Vec<crate::input::InputCache>,
    pub package: PathBuf,
    pub undo: Vec<ProjectData>,
    pub redo: Vec<ProjectData>,
    pub snapshot: bool,
}
/// Owned journal destination captured while staging, with no live project lock.
pub(crate) struct JournalTarget {
    package: Option<PathBuf>,
}
impl JournalTarget {
    pub(crate) fn write(&self, next: &ProjectData) -> Result<()> {
        let Some(package) = &self.package else {
            return Ok(());
        };
        #[cfg(test)]
        journal_test_hook::pause();
        let dir = relative_path(package, "autosave")?;
        fs::create_dir_all(&dir)?;
        relative_path(package, "autosave/project.json")?;
        atomic_write(&dir, "project.json", &serde_json::to_vec(next)?)
    }
}
#[cfg(test)]
pub(crate) mod journal_test_hook {
    use std::cell::RefCell;
    thread_local! { static HOOK: RefCell<Option<Box<dyn FnOnce()>>> = RefCell::new(None); }
    pub(crate) fn set(hook: impl FnOnce() + 'static) {
        HOOK.with(|h| *h.borrow_mut() = Some(Box::new(hook)));
    }
    pub(super) fn pause() {
        let hook = HOOK.with(|h| h.borrow_mut().take());
        if let Some(hook) = hook {
            hook();
        }
    }
}

pub fn relative_path(package: &Path, relative: &str) -> Result<PathBuf> {
    let p = Path::new(relative);
    if relative.is_empty() || p.components().any(|c| !matches!(c, Component::Normal(_))) {
        return Err(Error::new(1, format!("Unsafe package path: {relative}")));
    }
    let full = package.join(p);
    let mut ancestor = full.as_path();
    while !ancestor.exists() {
        ancestor = ancestor
            .parent()
            .ok_or_else(|| Error::new(1, "Invalid path"))?;
    }
    if !ancestor
        .canonicalize()?
        .starts_with(package.canonicalize()?)
    {
        return Err(Error::new(
            1,
            format!("Media path escapes package: {relative}"),
        ));
    }
    Ok(full)
}
pub fn read_session(package: &Path, recording: &str) -> Result<Session> {
    let raw: serde_json::Value =
        serde_json::from_slice(&fs::read(relative_path(package, recording)?)?)?;
    check_version(&raw)?;
    let session: Session = serde_json::from_value(raw)?;
    validate_session(&session)?;
    Ok(session)
}
fn check_version(raw: &serde_json::Value) -> Result<u32> {
    let v = raw
        .get("schema_version")
        .and_then(|v| v.as_u64())
        .ok_or_else(|| Error::new(2, "Missing schema_version"))?;
    if v > SCHEMA_VERSION as u64 {
        return Err(Error::new(3, format!("Unsupported schema_version: {v}")));
    }
    Ok(v as u32)
}
/// Version 0 was the prerelease form of schema 1; absent settings take defaults.
/// Future migrations belong here and must retain the original media references.
pub fn decode_project(bytes: &[u8]) -> Result<ProjectData> {
    let mut raw: serde_json::Value = serde_json::from_slice(bytes)?;
    if check_version(&raw)? == 0 {
        raw["schema_version"] = SCHEMA_VERSION.into();
    }
    let p: ProjectData = serde_json::from_value(raw)?;
    validate_data(&p)?;
    Ok(p)
}
pub fn validate_session(s: &Session) -> Result<()> {
    let mut end: i64 = 0;
    if s.source.scale <= 0.0
        || !s.source.scale.is_finite()
        || s.tracks.screen.pixel_size.contains(&0)
        || s.source.content_rect_points.iter().any(|x| !x.is_finite())
        || s.source.content_rect_points[2] <= 0.0
        || s.source.content_rect_points[3] <= 0.0
    {
        return Err(Error::new(2, "Invalid capture geometry"));
    }
    if s.tracks
        .camera
        .as_ref()
        .is_some_and(|c| c.pixel_size.contains(&0) || !c.fps.is_finite() || c.fps <= 0.0)
        || [&s.tracks.mic, &s.tracks.system_audio].iter().any(|a| {
            a.as_ref()
                .is_some_and(|a| a.channels == 0 || a.sample_rate == 0)
        })
    {
        return Err(Error::new(2, "Invalid optional track format"));
    }
    for (i, seg) in s.segments.iter().enumerate() {
        if seg.index != i as u32 || seg.src_start_ns != end || seg.duration_ns <= 0 {
            return Err(Error::new(
                2,
                "Segments must be contiguous, ordered, and positive",
            ));
        }
        end = end
            .checked_add(seg.duration_ns)
            .ok_or_else(|| Error::new(2, "Source duration overflow"))?;
        if seg
            .track_start_ns
            .values()
            .any(|t| *t < 0 || *t >= seg.duration_ns)
        {
            return Err(Error::new(2, "Invalid track_start_ns"));
        }
    }
    Ok(())
}
pub fn validate_data(p: &ProjectData) -> Result<()> {
    let invalid = |s| Err(Error::new(1, s));
    let mut ids = std::collections::HashSet::new();
    let mut duration = 0.0;
    for c in &p.timeline.clips {
        if c.src_start_ns < 0
            || c.src_end_ns <= c.src_start_ns
            || !c.speed.is_finite()
            || !(0.05..=32.0).contains(&c.speed)
            || !ids.insert(c.id.as_str())
        {
            return invalid("Invalid clip or duplicate clip id");
        }
        duration += (c.src_end_ns - c.src_start_ns) as f64 / c.speed;
    }
    if !duration.is_finite() || duration >= i64::MAX as f64 {
        return invalid("Timeline duration overflow");
    }
    ids.clear();
    for z in &p.zooms {
        if z.tl_start_ns < 0
            || z.tl_end_ns <= z.tl_start_ns
            || !(1.0..=16.0).contains(&z.scale)
            || z.target.iter().any(|t| !(0.0..=1.0).contains(t))
            || z.ease_in_ns < 0
            || z.ease_out_ns < 0
            || !matches!(z.mode.as_str(), "auto" | "manual")
            || !ids.insert(&z.id)
        {
            return invalid("Invalid zoom");
        }
    }
    let c = &p.canvas;
    if c.output_size.contains(&0)
        || c.output_size.iter().any(|v| *v > 16384)
        || !(0.0..=16384.0).contains(&c.padding)
        || !(0.0..=16384.0).contains(&c.radius)
        || !(0.0..=8192.0).contains(&c.inset)
        || !(0.0..=16384.0).contains(&c.shadow.radius)
        || !(-32768.0..=32768.0).contains(&c.shadow.offset_y)
        || !(0.0..=16384.0).contains(&c.background.blur)
        || !c.background.angle_deg.is_finite()
        || !(0.0..=1.0).contains(&c.shadow.opacity)
        || !(0.0..=1.0).contains(&c.motion_blur)
        || !(0.0..=1.0).contains(&c.background.noise)
        || !matches!(
            c.background.kind.as_str(),
            "solid" | "gradient" | "image" | "blurred_screen"
        )
    {
        return invalid("Invalid canvas settings");
    }
    if c.aspect != "source" && c.aspect != "custom" {
        let parts: Vec<_> = c.aspect.split(':').collect();
        if parts.len() != 2
            || parts.iter().any(|s| {
                s.parse::<f64>()
                    .map_or(true, |v| !v.is_finite() || v <= 0.0)
            })
        {
            return invalid("Invalid canvas aspect");
        }
    }
    let color_ok = |color: &[f32; 4]| {
        color
            .iter()
            .all(|v| v.is_finite() && (0.0..=1.0).contains(v))
    };
    if !color_ok(&c.background.color)
        || !color_ok(&c.background.color2)
        || !color_ok(&c.inset_color)
    {
        return invalid("Invalid color");
    }
    if c.background.kind == "image" && c.background.asset as usize >= p.media.len() {
        return invalid("Background asset index is unavailable");
    }
    let cur = &p.cursor;
    if !(0.1..=10.0).contains(&cur.size)
        || !(0.0..=1.0).contains(&cur.smoothing)
        || cur.idle_timeout_ns < 0
        || cur.click_duration_ns <= 0
        || !matches!(cur.click_effect.as_str(), "none" | "ring" | "highlight")
        || !matches!(cur.style.as_str(), "recorded" | "pointer" | "touch")
        || !(0.0..=1.0).contains(&cur.motion_blur)
        || !(0.0..=16384.0).contains(&cur.spotlight_radius)
    {
        return invalid("Invalid cursor settings");
    }
    let cam = &p.camera;
    if !(0.01..=1.0).contains(&cam.size)
        || cam.position.iter().any(|v| !(0.0..=1.0).contains(v))
        || !(0.0..=16384.0).contains(&cam.radius)
        || !(0.0..=1.0).contains(&cam.opacity)
        || !matches!(cam.shape.as_str(), "rounded_rect" | "circle" | "squircle")
        || !(0.0..=16384.0).contains(&cam.shadow_radius)
    {
        return invalid("Invalid camera settings");
    }
    ids.clear();
    for l in &cam.layouts {
        if l.tl_start_ns < 0
            || l.tl_end_ns <= l.tl_start_ns
            || !matches!(
                l.mode.as_str(),
                "screen" | "camera" | "overlay" | "side_by_side"
            )
            || l.camera_position
                .is_some_and(|p| p.iter().any(|v| !(0.0..=1.0).contains(v)))
            || l.camera_size.is_some_and(|s| !(0.01..=1.0).contains(&s))
            || !ids.insert(&l.id)
        {
            return invalid("Invalid layout segment");
        }
    }
    if !(-96.0..=24.0).contains(&p.audio.mic_gain_db)
        || !(-96.0..=24.0).contains(&p.audio.system_gain_db)
    {
        return invalid("Invalid audio gain");
    }
    let preset_ok = |p: &str| matches!(p, "custom" | "slow" | "mellow" | "quick" | "rapid");
    let spring_ok = |s: &Spring| {
        (1.0..=2000.0).contains(&s.tension)
            && (1.0..=200.0).contains(&s.friction)
            && (0.1..=10.0).contains(&s.mass)
    };
    if !preset_ok(&cur.speed_preset)
        || !preset_ok(&p.zoom_settings.speed_preset)
        || !spring_ok(&cur.spring)
        || !spring_ok(&p.zoom_settings.spring)
        || !(0.0..=0.45).contains(&p.zoom_settings.dead_zone)
        || cur.loop_duration_ns <= 0
    {
        return invalid("Invalid spring or follow settings");
    }
    for r in &cur.ranges {
        if r.tl_start_ns < 0 || r.tl_end_ns <= r.tl_start_ns {
            return invalid("Invalid cursor range");
        }
    }
    ids.clear();
    for r in &p.audio.ranges {
        if r.tl_start_ns < 0
            || r.tl_end_ns <= r.tl_start_ns
            || !matches!(r.track.as_str(), "mic" | "system_audio")
            || !(-96.0..=24.0).contains(&r.start_gain_db)
            || !(-96.0..=24.0).contains(&r.end_gain_db)
            || !ids.insert(&r.id)
        {
            return invalid("Invalid audio range");
        }
    }
    if c.crop.iter().any(|v| !v.is_finite())
        || c.crop[0] < 0.0
        || c.crop[1] < 0.0
        || c.crop[2] <= 0.0
        || c.crop[3] <= 0.0
        || c.crop[0] + c.crop[2] > 1.0
        || c.crop[1] + c.crop[3] > 1.0
    {
        return invalid("Invalid source crop");
    }
    ids.clear();
    for h in &c.highlights {
        if h.id.is_empty()
            || h.id == "canvas-fade"
            || !ids.insert(&h.id)
            || h.tl_start_ns < 0
            || h.tl_end_ns <= h.tl_start_ns
            || !matches!(h.space.as_str(), "source" | "canvas")
            || h.rect.iter().any(|v| !v.is_finite())
            || h.rect[0] < 0.0
            || h.rect[1] < 0.0
            || h.rect[2] <= 0.0
            || h.rect[3] <= 0.0
            || h.rect[0] + h.rect[2] > 1.0
            || h.rect[1] + h.rect[3] > 1.0
            || !(0.0..=16384.0).contains(&h.radius)
            || !(0.0..=16384.0).contains(&h.stroke_width)
            || !(0.0..=1.0).contains(&h.opacity)
            || !(0.0..=1.0).contains(&h.dim_opacity)
            || !color_ok(&h.fill)
            || !color_ok(&h.stroke)
        {
            return invalid("Invalid highlight");
        }
    }
    // The fixed ABI stores a prefix without truncation. Bound simultaneous
    // highlights, allowing arbitrarily many non-overlapping timeline regions.
    let mut boundaries = Vec::with_capacity(c.highlights.len() * 2);
    for h in &c.highlights {
        boundaries.push((h.tl_start_ns, 1_i32));
        boundaries.push((h.tl_end_ns, -1_i32));
    }
    boundaries.sort_unstable(); // end before start at equal, half-open times
    let mut active = 0;
    for (_, delta) in boundaries {
        active += delta;
        if active > crate::layers::MAX_FRAME_HIGHLIGHTS as i32 {
            return invalid("At most 32 highlights may overlap");
        }
    }
    if !matches!(c.animation.entrance.as_str(), "none" | "fade")
        || !matches!(c.animation.exit.as_str(), "none" | "fade")
        || c.animation.entrance_duration_ns <= 0
        || c.animation.exit_duration_ns <= 0
    {
        return invalid("Invalid canvas animation");
    }
    Ok(())
}
/// FNV-1a fingerprint of at most the first MiB; prefixed for future algorithms.
pub fn fingerprint(path: &Path) -> Result<Media> {
    let f = File::open(path)?;
    let size = f.metadata()?.len();
    let mut hash: u64 = 0xcbf29ce484222325;
    let mut buf = [0u8; 8192];
    let mut reader = f.take(1_048_576);
    loop {
        let count = reader.read(&mut buf)?;
        if count == 0 {
            break;
        }
        for b in &buf[..count] {
            hash = (hash ^ *b as u64).wrapping_mul(0x100000001b3);
        }
    }
    Ok(Media {
        path: String::new(),
        size,
        head_hash: format!("fnv1a64:{hash:016x}"),
    })
}
impl Project {
    pub fn create(package: &Path) -> Result<Self> {
        let session = read_session(package, "recording/session.json")?;
        let data = ProjectData::from_session(&session, unique_id("project"));
        let mut p = Self::load(package, data, session)?;
        p.check_media()?;
        for seg in &p.session.segments {
            for relative in seg.files.values() {
                let relative = format!("recording/{relative}");
                if p.data.media.iter().any(|m| m.path == relative) {
                    continue;
                }
                let mut m = fingerprint(&relative_path(package, &relative)?)?;
                m.path = relative;
                p.data.media.push(m);
            }
        }
        for seg in &p.session.segments {
            if let Some(manifest) = seg.files.get("cursors") {
                let path = relative_path(package, &format!("recording/{manifest}"))?;
                let cursors: serde_json::Value = serde_json::from_slice(&fs::read(path)?)?;
                if let Some(map) = cursors.as_object() {
                    for cursor in map.values() {
                        if let Some(file) = cursor.get("file").and_then(serde_json::Value::as_str) {
                            let relative = format!("recording/{}/{file}", seg.dir);
                            let path = relative_path(package, &relative)?;
                            if !path.is_file() {
                                return Err(Error::new(5, serde_json::to_string(&vec![relative])?));
                            }
                            let mut media = fingerprint(&path)?;
                            media.path = relative;
                            p.data.media.push(media);
                        }
                    }
                }
            }
        }
        p.check_media()?;
        Ok(p)
    }
    pub fn open(package: &Path) -> Result<Self> {
        let primary_path = relative_path(package, "project.json")?;
        let previous_path = relative_path(package, "project.json.prev")?;
        let journal_path = relative_path(package, "autosave/project.json")?;
        let primary = fs::read(primary_path)
            .map_err(Error::from)
            .and_then(|b| decode_project(&b));
        let mut data = match primary {
            Ok(p) => p,
            Err(e) if e.status == 3 => return Err(e),
            Err(e) => match fs::read(previous_path)
                .map_err(Error::from)
                .and_then(|b| decode_project(&b))
            {
                Ok(p) => p,
                Err(e) if e.status == 3 => return Err(e),
                Err(_) => {
                    if let Ok(bytes) = fs::read(&journal_path) {
                        decode_project(&bytes)?
                    } else {
                        return Err(e);
                    }
                }
            },
        };
        if let Ok(bytes) = fs::read(&journal_path) {
            match decode_project(&bytes) {
                Ok(journal) if journal.id == data.id => data = journal,
                Err(e) if e.status == 3 => return Err(e),
                _ => {}
            }
        }
        let session = read_session(package, &data.recording)?;
        let p = Self::load(package, data, session)?;
        p.check_media()?;
        Ok(p)
    }
    fn load(package: &Path, data: ProjectData, session: Session) -> Result<Self> {
        let end = session
            .segments
            .last()
            .map_or(0, |s| s.src_start_ns + s.duration_ns);
        if data.timeline.clips.iter().any(|c| c.src_end_ns > end) {
            return Err(Error::new(2, "Clip exceeds recording duration"));
        }
        let mut events = Vec::new();
        for seg in &session.segments {
            let mut list = Vec::new();
            if let Some(path) = seg.files.get("events") {
                let path = relative_path(package, &format!("recording/{path}"))?;
                if path.exists() {
                    let mut last = 0;
                    for line in fs::read_to_string(path)?
                        .lines()
                        .filter(|l| !l.trim().is_empty())
                    {
                        let event: Event = serde_json::from_str(line)?;
                        if event.t < last
                            || event.t > seg.duration_ns
                            || event.x.is_some_and(|x| !x.is_finite())
                            || event.y.is_some_and(|y| !y.is_finite())
                        {
                            return Err(Error::new(
                                2,
                                "Invalid/nonmonotonic event time or coordinates",
                            ));
                        }
                        last = event.t;
                        list.push(event);
                    }
                }
            }
            events.push(list);
        }
        let input = events
            .iter()
            .map(|events| crate::input::InputCache::new(events))
            .collect();
        Ok(Self {
            data,
            session,
            events,
            input,
            package: package.into(),
            undo: vec![],
            redo: vec![],
            snapshot: false,
        })
    }
    pub fn check_media(&self) -> Result<()> {
        self.check_media_for(&self.data)
    }
    pub fn check_media_for(&self, data: &ProjectData) -> Result<()> {
        let mut missing = Vec::new();
        for m in &data.media {
            let path = relative_path(&self.package, &m.path)?;
            match fingerprint(&path) {
                Ok(found) if found.size == m.size && found.head_hash == m.head_hash => {}
                _ => missing.push(m.path.clone()),
            }
        }
        for s in &self.session.segments {
            for file in s.files.values() {
                let path = format!("recording/{file}");
                if !relative_path(&self.package, &path)?.is_file() && !missing.contains(&path) {
                    missing.push(path);
                }
            }
        }
        if missing.is_empty() {
            Ok(())
        } else {
            Err(Error::new(5, serde_json::to_string(&missing)?))
        }
    }
    pub fn write_journal(&self, next: &ProjectData) -> Result<()> {
        self.journal_target(next).write(next)
    }
    pub(crate) fn journal_target(&self, next: &ProjectData) -> JournalTarget {
        JournalTarget {
            package: if self.snapshot || (!next.autosave && !self.data.autosave) {
                None
            } else {
                Some(self.package.clone())
            },
        }
    }
    pub fn save(&self, package: &Path) -> Result<()> {
        save_data(&self.data, package)
    }
}
pub(crate) fn save_data(data: &ProjectData, package: &Path) -> Result<()> {
    #[cfg(test)]
    journal_test_hook::pause();
    validate_data(data)?;
    let bytes = serde_json::to_vec_pretty(data)?;
    let primary = relative_path(package, "project.json")?;
    relative_path(package, "project.json.prev")?;
    // Never overwrite a valid recovery file with a corrupt primary.
    if let Ok(previous) = fs::read(&primary) {
        if decode_project(&previous).is_ok() {
            atomic_write(package, "project.json.prev", &previous)?;
        }
    }
    atomic_write(package, "project.json", &bytes)?;
    let journal = relative_path(package, "autosave/project.json")?;
    if journal.exists() {
        fs::remove_file(journal)?;
        File::open(package.join("autosave"))?.sync_all()?;
    }
    Ok(())
}
fn atomic_write(package: &Path, name: &str, bytes: &[u8]) -> Result<()> {
    let temporary = package.join(format!(".{name}.{}.tmp", unique_id("save")));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&temporary, package.join(name))?;
        File::open(package)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(temporary);
    }
    result
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    pub struct Fixture(pub PathBuf);
    impl Fixture {
        pub fn new() -> Self {
            let p = std::env::temp_dir().join(unique_id("yapcam-core-test"));
            fn copy(a: &Path, b: &Path) {
                fs::create_dir_all(b).unwrap();
                for e in fs::read_dir(a).unwrap() {
                    let e = e.unwrap();
                    if e.file_type().unwrap().is_dir() {
                        copy(&e.path(), &b.join(e.file_name()));
                    } else {
                        fs::copy(e.path(), b.join(e.file_name())).unwrap();
                    }
                }
            }
            copy(
                &Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("../Tests/Fixtures/synthetic/basic.yapcam"),
                &p,
            );
            Self(p)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn atomic_save_recovery_and_version() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.save(&f.0).unwrap();
        let original = p.data.clone();
        p.data.canvas.padding = 100.0;
        p.save(&f.0).unwrap();
        assert_eq!(Project::open(&f.0).unwrap().data.canvas.padding, 100.0);
        fs::write(f.0.join("project.json"), "{broken").unwrap();
        let recovered = Project::open(&f.0).unwrap();
        assert_eq!(recovered.data, original);
        recovered.save(&f.0).unwrap();
        assert_eq!(
            decode_project(&fs::read(f.0.join("project.json.prev")).unwrap()).unwrap(),
            original
        );
        fs::write(f.0.join("project.json"), "{\"schema_version\":999}").unwrap();
        assert_eq!(Project::open(&f.0).err().unwrap().status, 3);
    }
    #[test]
    fn missing_changed_media_and_path_validation() {
        let f = Fixture::new();
        let p = Project::create(&f.0).unwrap();
        p.save(&f.0).unwrap();
        fs::remove_file(f.0.join("recording/seg-000/screen.mov")).unwrap();
        let e = Project::open(&f.0).err().unwrap();
        assert_eq!(e.status, 5);
        assert!(e.message.contains("screen.mov"));
        assert!(relative_path(&f.0, "../elsewhere").is_err());
        assert!(relative_path(&f.0, "/etc/passwd").is_err());
    }
    #[test]
    fn migration_hook() {
        let f = Fixture::new();
        let p = Project::create(&f.0).unwrap();
        let mut v = serde_json::to_value(p.data).unwrap();
        v["schema_version"] = 0.into();
        v.as_object_mut().unwrap().remove("cursor");
        let migrated = decode_project(&serde_json::to_vec(&v).unwrap()).unwrap();
        assert_eq!(migrated.schema_version, 1);
        assert!(migrated.cursor.visible);
    }
}

pub fn timestamp() -> String {
    let elapsed = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let seconds = elapsed.as_secs();
    let days = (seconds / 86400) as i64;
    let z = days + 719468;
    let era = z / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let mut year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = mp + if mp < 10 { 3 } else { -9 };
    year += if month <= 2 { 1 } else { 0 };
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        seconds / 3600 % 24,
        seconds / 60 % 60,
        seconds % 60,
        elapsed.subsec_millis()
    )
}
#[cfg(test)]
mod autosave_tests {
    use super::tests::Fixture;
    use super::*;
    use serde_json::json;
    #[test]
    fn crash_reopen_undo_redo_and_snapshot_isolation() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        p.apply(&json!({"op":"set","path":"notes","value":"notes survive crash"}))
            .unwrap();
        assert_eq!(
            Project::open(&f.0).unwrap().data.notes,
            "notes survive crash"
        );
        p.undo().unwrap();
        assert_eq!(Project::open(&f.0).unwrap().data.notes, "");
        p.redo().unwrap();
        assert_eq!(
            Project::open(&f.0).unwrap().data.notes,
            "notes survive crash"
        );
        let mut copy = p.clone();
        copy.snapshot = true;
        copy.apply(&json!({"op":"set","path":"notes","value":"export snapshot"}))
            .unwrap();
        assert_eq!(
            Project::open(&f.0).unwrap().data.notes,
            "notes survive crash"
        );
        p.save(&f.0).unwrap();
        assert!(!f.0.join("autosave/project.json").exists());
    }
    #[test]
    fn failed_journal_never_applies_edit() {
        let f = Fixture::new();
        let mut p = Project::create(&f.0).unwrap();
        let old = p.data.clone();
        fs::write(f.0.join("autosave"), "not a directory").unwrap();
        assert_eq!(
            p.apply(&json!({"op":"set","path":"canvas.padding","value":100}))
                .unwrap_err()
                .status,
            4
        );
        assert_eq!(p.data, old);
        assert!(p.undo.is_empty());
    }
    #[test]
    fn reject_parent_symlink_escape() {
        let f = Fixture::new();
        let external = Fixture::new();
        std::os::unix::fs::symlink(&external.0, f.0.join("external")).unwrap();
        assert!(relative_path(&f.0, "external/new-file").is_err());
    }
}
#[cfg(test)]
mod recovery_validation_tests {
    use super::tests::Fixture;
    use super::*;
    #[test]
    fn newer_backup_and_journal_are_refused() {
        let f = Fixture::new();
        let p = Project::create(&f.0).unwrap();
        p.save(&f.0).unwrap();
        fs::write(f.0.join("project.json"), "broken").unwrap();
        fs::write(f.0.join("project.json.prev"), "{\"schema_version\":99}").unwrap();
        assert_eq!(Project::open(&f.0).err().unwrap().status, 3);
        fs::remove_file(f.0.join("project.json.prev")).unwrap();
        p.save(&f.0).unwrap();
        fs::create_dir_all(f.0.join("autosave")).unwrap();
        fs::write(f.0.join("autosave/project.json"), "{\"schema_version\":99}").unwrap();
        assert_eq!(Project::open(&f.0).err().unwrap().status, 3);
    }
    #[test]
    fn missing_cursor_png_and_project_symlinks_are_rejected() {
        let f = Fixture::new();
        fs::remove_file(f.0.join("recording/seg-000/cursors/1.png")).unwrap();
        assert_eq!(Project::create(&f.0).err().unwrap().status, 5);
        let external = Fixture::new();
        let p = Project::create(&external.0).unwrap();
        p.save(&external.0).unwrap();
        std::os::unix::fs::symlink(external.0.join("project.json"), f.0.join("project.json"))
            .unwrap();
        assert_eq!(Project::open(&f.0).err().unwrap().status, 1);
    }
}
