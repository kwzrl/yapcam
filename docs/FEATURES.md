# Yapcam feature inventory (reference: Screen Studio 4.0.4-4926)

Columns: `ID | Area | Reference behavior | Source | Yapcam behavior | Team | Status | Acceptance test`.
Status: `todo / implemented / integrated / verified (how) / limited (why)`.

Source tags: **[observed]** used the installed app · **[docs]** official guide pages ·
**[technical]** file/asset inventory of the installed app (names only, nothing copied) ·
**[assumption]** our inference or design decision.

> **Evidence caveat (first pass).** [observed] and deep [technical] passes (settings schema,
> project format, export option values) were NOT possible in this session: the permission
> classifier denied reverse-engineering calls on the installed app (bundle string
> search, REA analysis). Exact option values (preset lists, slider ranges, defaults) are
> therefore [docs]/[assumption] and are marked "values TBD" where unknown. Refinement
> needs the user to allow REA/observation on `/Applications/Screen Studio.app`
> (see docs/status/qa.md Blockers). Notes: `docs/reference/*.md`.

Priority: **M1** = end-to-end path (display + system audio + cursor events → editor →
background/padding + manual zoom → MP4 1080p). Everything else is **M2**.

## A. Recording – sources and session

| ID | Area | Reference behavior | Src | Yapcam behavior | Team | Status | Acceptance test |
|---|---|---|---|---|---|---|---|
| REC-01 | Capture | Record an entire display | docs | SCStream display capture, native pixel size, HEVC, cursor excluded from video (M1) | capture | todo | Record 5 s; ffprobe size = display pixels; cursor absent in video |
| REC-02 | Capture | Record a single window | docs | SCContentFilter window; follows window moves/resizes; target-window-closed ends/pauses with warning | capture | todo | Record TextEdit window while moving it; output stays window-sized |
| REC-03 | Capture | Record a custom area | docs | Area rect in display points, drawn with overlay; stored in session.json | capture+ui | todo | Area 800×600 → video 800×600 (×scale) |
| REC-04 | Capture | Source picker (display / window / area) in toolbar | docs/assumption | Vertical toolbar with three modes and live thumbnails | ui | todo | Switch modes, each starts correct capture |
| REC-05 | Capture | Area/window selection overlay, resizable, remembers last area | assumption | Full-screen overlay, drag/resize handles, size readout, Esc cancels | ui | todo | Draw, resize, record, rect matches |
| REC-06 | Capture | Countdown before recording | assumption | 3-2-1 countdown (configurable off/3/5 s); not captured | ui | todo | Countdown not visible in output frame 0 |
| REC-07 | Capture | Start/stop via global shortcut and menu bar item | docs | Global hotkey (configurable), menu bar item with state | ui | todo | Hotkey starts and stops recording |
| REC-08 | Capture | Pause / resume during recording | docs | New segment per resume; pauses removed from source time (FORMATS.md) | capture | todo | Record 3 s, pause 5 s, 3 s → duration ≈ 6 s, A/V in sync |
| REC-09 | Capture | Recording HUD (timer, pause, stop, mic level) | assumption | Small floating panel excluded from capture | ui | todo | HUD absent from exported file |
| REC-10 | Capture | Exclude own app windows from capture | docs/assumption | CaptureExclusions registered windows | capture | todo | E2E: toolbar visible on screen, absent in recording |
| REC-11 | Capture | Frame rate 30/60 fps, VFR | assumption | maxFPS option; VFR timestamps preserved | capture | todo | ffprobe frame timestamps monotonic, ≤60 fps |
| REC-12 | Capture | Retina / native pixel recording | assumption | pixel_size = points×scale; math tests (no Retina HW) | capture | limited (no Retina display; unit tests only) | Unit: scale 2 sizes |
| REC-13 | Capture | Hide desktop icons while recording | technical (hide-icons helper) | Option; restores icons on stop/crash | capture/ui | todo | Icons hidden in recording, restored after |
| REC-14 | Capture | Hide Dock icon / recording flag option | docs | Settings toggle for Yapcam Dock icon (accessory activation policy) | ui | todo | Toggle hides Dock icon |
| REC-15 | Capture | Capture notifications option | docs | Option documented; macOS limits apply | capture | limited (OS-dependent) | Banner appears in recording when enabled |
| REC-16 | Capture | Create project from existing video | docs | Import MOV/MP4 → .yapcam (screen track only, no events) | core+ui | todo | Import sample.mp4, edit, export |
| REC-17 | Capture | Record iPhone/iPad via mirroring/device | docs | Out of scope for first pass unless window capture of iPhone Mirroring window works (it is a window) | capture | limited (no device) | n/a |
| REC-18 | Capture | Recovery of interrupted recordings | technical ("recover unfinished recordings" prompt) | Prompt on launch for interrupted packages; recover finalizes segments | capture+ui | todo | Kill -9 during recording → relaunch → recover → opens |
| REC-19 | Capture | Low-disk handling | assumption | Check free space at start, warn, stop gracefully with diskFull | capture | todo | Simulated low space → package finalized, error shown |
| REC-20 | Capture | Permission onboarding | docs | Screen, mic, camera, accessibility, input monitoring guided panel | ui | todo | Missing permission shows state and opens Settings |
| REC-21 | Capture | Speaker notes while recording | docs | Optional notes shown in HUD, stored in project | ui+core | todo | Notes persist in project.json |

## B. Audio and devices

| ID | Area | Reference behavior | Src | Yapcam behavior | Team | Status | Acceptance test |
|---|---|---|---|---|---|---|---|
| AUD-01 | Audio | Record system audio | docs | SC audio capture → system.m4a, separate track (M1) | capture | todo | Play tone during recording; track RMS > threshold |
| AUD-02 | Audio | Record microphone | docs | AVCapture → mic.m4a, device picker, level meter | capture | limited (no mic HW; no-device path tested) | No-device: option disabled with message; no crash |
| AUD-03 | Audio | Mic device lost mid-recording | assumption | Recording continues, warning, mic track truncated | capture | limited (no HW; simulated) | Unit/simulated device loss |
| AUD-04 | Audio | Per-track volume (mic, system) | docs | audio.mic_gain_db / system_gain_db; mute | editor+core | todo | Set −∞ → exported track silent |
| AUD-05 | Audio | Volume over time (volume keyframes/segments) | docs (scrubber/volume) | Per-clip/segment gain | core+editor | todo | Gain ramp audible in export |
| AUD-06 | Audio | Noise reduction / speech enhancement | technical (speech-enhancement model shipped) | Apple VoiceProcessing or small model; marked M2-late | render | todo | Noisy sample → lower noise floor |
| AUD-07 | Audio | Background music library + volume | technical (bundled music in 5 genres) | Own royalty-free tracks only (not reference files); loop, fade | editor+render | todo | Add music, export has 3rd source |
| AUD-08 | Audio | Mouse click sounds | docs / technical (click sound sets) | Own click sounds (2 variants), volume | render | todo | Click event → audio impulse at time |
| AUD-09 | Audio | Recording start/stop sounds | technical | Optional | ui | todo | Setting toggles |
| AUD-10 | Audio | Captions via local transcription | docs / technical (whisper binary) | On-device speech recognition (Speech/ whisper.cpp later); caption style | editor | todo | Transcribe sample; caption times align ±200 ms |
| AUD-11 | Audio | Silence detection → speed-up/cut | technical (detect-silence) | Offer to cut/speed silent ranges | core+editor | todo | Silence range detected in known file |

## C. Camera

| ID | Area | Reference behavior | Src | Yapcam behavior | Team | Status | Acceptance test |
|---|---|---|---|---|---|---|---|
| CAM-01 | Camera | Record webcam as separate track | docs | camera.mov host-time stamped | capture | limited (no camera; no-device path) | No camera: option unavailable, message |
| CAM-02 | Camera | Camera shape, size, position, radius, shadow, mirror | docs | camera.* settings | editor+render | todo | Fixture camera track: rect/shape in frame |
| CAM-03 | Camera | Dynamic camera layouts (hide/enlarge/fullscreen over time) | docs | camera layout segments on timeline | core+editor | todo | Layout change at t → frame description changes |
| CAM-04 | Camera | Background removal for camera | technical (matting/segmentation models) | Vision person segmentation | render | limited (no camera) | Synthetic still image test |
| CAM-05 | Camera | Face detection to frame camera | technical (face-detector) | Vision face rect | render | todo | Fixture image |
| CAM-06 | Camera | Camera lost mid-recording | assumption | Continue, warning | capture | limited | simulated |

## D. Cursor and input events

| ID | Area | Reference behavior | Src | Yapcam behavior | Team | Status | Acceptance test |
|---|---|---|---|---|---|---|---|
| CUR-01 | Cursor | Cursor recorded as data, rendered in editor | docs/technical | events.jsonl + cursors PNG, screen without cursor (M1) | capture | todo | Events count>0; video cursor-free |
| CUR-02 | Cursor | Click/scroll/move capture | docs | CGEventTap listen-only | capture | todo | Scripted CGEvent clicks appear at right times |
| CUR-03 | Cursor | Smooth cursor movement toggle | docs | cursor.smoothing; off = raw | core+render | todo | Off: frame cursor == raw event pos |
| CUR-04 | Cursor | Cursor speed presets Slow/Mellow/Quick/Rapid + tension/friction/mass | docs | spring params; presets map to values | core | todo | Spring step response unit tests |
| CUR-05 | Cursor | Cursor size, show/hide, hide when idle, hide in sections | docs | cursor.size/visible/hide_when_idle + range overrides | core+editor | todo | Hidden section frame has no cursor |
| CUR-06 | Cursor | Cursor sets (macOS, tahoe, touch, many custom) | technical (assets: ~24 sets) | Native macOS cursor images + a few own styles | render | todo | Switch set changes image |
| CUR-07 | Cursor | Click effect (ripple/ring) | docs/assumption | cursor.click_effect | render | todo | Click frame differs from idle frame |
| CUR-08 | Cursor | Cursor motion blur | docs | strength slider | render | todo | Fast move frame blurred |
| CUR-09 | Cursor | Loop cursor to start position | assumption | option | core | todo | last pos = first pos |
| CUR-10 | Cursor | Keystroke display (opt-in) | assumption (key events in format) | key overlay with modifiers | capture+render | todo | cmd+k shows overlay |
| CUR-11 | Cursor | Cursor click highlights/spotlight | assumption | optional | render | todo | – |

## E. Zoom

| ID | Area | Reference behavior | Src | Yapcam behavior | Team | Status | Acceptance test |
|---|---|---|---|---|---|---|---|
| ZOM-01 | Zoom | Auto zoom from clicks | docs | analyzer creates zoom regions at click clusters (zooms[] mode=auto) | core | todo | Fixture with 3 click clusters → 3 zooms |
| ZOM-02 | Zoom | Manual zoom: add/move/resize on timeline, target point (M1) | docs | add_zoom command; target dot in preview | core+editor | verified (testM1OpenEditExport: crop changes at mid-zoom (core level; UI untested)) | Add zoom, frame at mid has zoom rect |
| ZOM-03 | Zoom | Zoom level per zoom | docs | scale 1…N | core | todo | Scale applied exactly |
| ZOM-04 | Zoom | Auto/Manual per zoom toggle | docs | mode switch | core+editor | todo | Switch changes target source |
| ZOM-05 | Zoom | Disable automatic zooms (global/per zoom) | docs | setting | core | todo | No auto zooms generated when off |
| ZOM-06 | Zoom | Zoom speed presets + tension/friction/mass | docs | ease_in/out + spring | core | todo | Curve unit tests (no overshoot unless set) |
| ZOM-07 | Zoom | Camera follows cursor while zoomed | docs | pan with cursor, dead-zone | core | todo | Cursor at edge pans view |
| ZOM-08 | Zoom | Instant zoom | docs | zoom without easing | core | todo | ease=0 |
| ZOM-09 | Zoom | Zoom motion blur | docs | strength slider | render | todo | – |
| ZOM-10 | Zoom | Zoom-aware sharpness (render from source resolution) | assumption | sample source at needed resolution | render | todo | Zoomed export has native detail |

## F. Timeline / editing

| ID | Area | Reference behavior | Src | Yapcam behavior | Team | Status | Acceptance test |
|---|---|---|---|---|---|---|---|
| EDT-01 | Edit | Preview player play/pause/seek/scrub (M1) | docs | PreviewPlayer | render+editor | todo | Seek lands on right frame |
| EDT-02 | Edit | Split / trim / delete range (cuts) | docs | split, delete_range; all tracks shift together | core+editor | verified (testAudioVideoDurationsAgreeAfterCut + testSpeedAndCutChangeExportedDuration) | Cut; audio and video remain in sync |
| EDT-03 | Edit | Speed up segments | docs | set_speed per clip; audio pitch handling | core+render | todo | 2× clip halves duration |
| EDT-04 | Edit | Speed up typing segments automatically | docs | detect key bursts → speed | core | todo | Fixture keystrokes |
| EDT-05 | Edit | Undo/redo | assumption | command stack | core+editor | verified (testCutUndoRedoDuration + testNoDriftOverManyEdits (300 edits)) | 100 ops undo/redo exact |
| EDT-06 | Edit | Autosave + reopen | docs | autosave journal, project.json.prev | core | todo | Kill app, reopen, edits intact |
| EDT-07 | Edit | Aspect ratio + crop | docs | canvas.aspect, screen crop | core+render | todo | 9:16 export size correct |
| EDT-08 | Edit | Mask/highlight regions | docs | rect/rounded highlight with dim outside | core+render | todo | – |
| EDT-09 | Edit | Annotations / text overlays | assumption | text blocks on timeline | editor+render | todo | – |
| EDT-10 | Edit | Command menu (⌘K style) | docs | searchable action palette | editor | todo | – |
| EDT-11 | Edit | Copy current frame as image | docs | clipboard PNG of composited frame | editor | todo | Clipboard image equals frame |
| EDT-12 | Edit | Timeline zoom, snapping, keyboard shortcuts | docs | per shortcut list | editor | todo | – |
| EDT-13 | Edit | Reactions (emoji reactions on timeline) | docs | emoji sprites with animation | editor+render | todo | – |
| EDT-14 | Edit | Animations (intro/outro, scene transitions) | docs (Look & Feel/animations) | entrance/exit animation presets | core+render | todo | – |

## G. Look and canvas

| ID | Area | Reference behavior | Src | Yapcam behavior | Team | Status | Acceptance test |
|---|---|---|---|---|---|---|---|
| LOK-01 | Canvas | Background: solid, gradient (M1) | docs | canvas.background | render | todo | Pixel check of background |
| LOK-02 | Canvas | Background: wallpaper images in categories | technical (9 categories) | Own generated gradients/images only | render | todo | – |
| LOK-03 | Canvas | Background: macOS wallpaper / custom image | technical | custom image import; system wallpaper | render | todo | – |
| LOK-04 | Canvas | Background blur / noise texture | technical (noise asset) | option | render | todo | – |
| LOK-05 | Canvas | Padding (M1), corner radius, shadow, inset/border | docs | canvas.* | render | todo | Frame: content rect inset equals padding |
| LOK-06 | Canvas | Window device frame / macOS window chrome | technical (devices assets) | optional frames | render | todo | – |
| LOK-07 | Canvas | Output size/aspect presets | docs | canvas.output_size | core | todo | – |
| LOK-08 | Canvas | Watermark | n/a | none: no watermark ever | – | verified (by design) | Export has no overlay |

## H. Presets and project

| ID | Area | Reference behavior | Src | Yapcam behavior | Team | Status | Acceptance test |
|---|---|---|---|---|---|---|---|
| PRJ-01 | Project | Package save/open (M1) | docs | .yapcam package, atomic writes | core | verified (testSaveReopen (.prev kept)) | Save/open roundtrip |
| PRJ-02 | Project | Presets create/apply/share (file-based) | docs | export/import preset JSON (local file sharing only) | core+ui | todo | Apply preset changes settings |
| PRJ-03 | Project | Default settings for new recordings | docs | settings panel | ui | todo | – |
| PRJ-04 | Project | Recent projects, open file association | assumption | – | ui | todo | – |
| PRJ-05 | Project | Missing media detection + relink | architecture | open throws missingMedia | core+ui | verified (testMissingMediaIsReported) | Remove screen.mov → clear error |
| PRJ-06 | Project | Extract raw recording files | docs | reveal/export raw tracks | ui | todo | Files copied |
| PRJ-07 | Project | Duplicate project / rename / delete | assumption | – | ui | todo | – |
| PRJ-08 | Project | Newer-schema refusal, old-schema migration | architecture | – | core | todo | Test fixtures |

## I. Export

| ID | Area | Reference behavior | Src | Yapcam behavior | Team | Status | Acceptance test |
|---|---|---|---|---|---|---|---|
| EXP-01 | Export | MP4 export 1080p H.264 (M1) | docs | Exporter | render | verified (PipelineE2E testM1OpenEditExport: ffprobe 1080p) | ffprobe 1920×1080, duration ±1 frame |
| EXP-02 | Export | Resolution options (720/1080/1440/2160/…) | docs/assumption | outputHeight | render | todo | per size ffprobe |
| EXP-03 | Export | FPS 24/30/60 | docs | fps | render | verified (testFPSAndNoAudio: r_frame_rate 60/1, 300 frames) | ffprobe r_frame_rate |
| EXP-04 | Export | Quality/compression level | docs | quality 0…1 | render | todo | bitrate monotonic |
| EXP-05 | Export | GIF export | docs, technical | native ImageIO GIF writer (no gifsicle) | render | verified (testFormatsAndPresets: GIF 30 frames) | valid GIF, frame count |
| EXP-06 | Export | MOV export, HEVC codec | docs(3rd party), assumption | format/codec | render | verified (testFormatsAndPresets: HEVC mp4 + H.264 mov) | – |
| EXP-07 | Export | Export progress/cancel, partial file removed | assumption | Task cancel | render+ui | verified (testCancelRemovesPartialFile) | Cancel → no file |
| EXP-08 | Export | Preview == export | architecture | same compositor | render | todo | ffmpeg frame diff < threshold |
| EXP-09 | Export | Performance settings (hardware encode, parallelism) | docs | – | render | todo | – |
| EXP-10 | Export | Quick share widget / copy file | docs | reveal in Finder / drag file; no upload | ui | limited (no cloud) | – |
| EXP-11 | Export | Verification: reopen output and check tracks | contract | Exporter | render | todo | – |

## J. Out of scope (cloud / account / commerce)

| ID | Area | Reference behavior | Src | Yapcam behavior | Team | Status |
|---|---|---|---|---|---|---|
| OOS-01 | Cloud | Shareable links, comments on links | docs | out of scope (no cloud) | – | limited (out of scope) |
| OOS-02 | Account | Login, license, subscription, payment | docs | out of scope | – | limited (out of scope) |
| OOS-03 | Telemetry | Crash reporting/analytics (Sentry in reference) | technical | none | – | limited (out of scope) |
| OOS-04 | Update | In-app auto-update | technical | out of scope | – | limited (out of scope) |
| OOS-05 | Web | Email address update, website | docs | out of scope | – | limited (out of scope) |
| OOS-06 | Diagnostics | Diagnostic info export | docs | local log export only (optional) | ui | todo |
