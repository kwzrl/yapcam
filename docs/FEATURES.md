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

> **Reference-analysis limits (updated 2026-10-15).** REA on Screen Studio's Electron app was
> limited: the full-asar run hit REA's resource limit and the own-sources run (226 JS files)
> produced a truncated graph with almost no feature strings; bundle strings are obfuscated;
> extracting the asar is not allowed by policy here. Usable [technical] facts: the file/asset
> inventory and that the app ships a Core ML speech-enhancement model (MossFormer2 SE, 48 kHz),
> i.e. ML voice enhancement (AUD-06). Remaining values come from official guides ([docs]).
> **[observed] rows: to observe with the user in the morning** (screenshots/screen access
> missing). Exact slider ranges, defaults and preset numbers stay TBD until then.

Priority: **M1** = end-to-end path (display + system audio + cursor events → editor →
background/padding + manual zoom → MP4 1080p). Everything else is **M2**.

## A. Recording – sources and session

| ID | Area | Reference behavior | Src | Yapcam behavior | Team | Status | Acceptance test |
|---|---|---|---|---|---|---|---|
| REC-01 | Capture | Record an entire display | docs | SCStream display capture, native pixel size, HEVC, cursor excluded from video (M1) | capture | limited (no TCC: display capture implemented; host media check pending) | Record 5 s; ffprobe size = display pixels; cursor absent in video |
| REC-02 | Capture | Record a single window | docs | SCContentFilter window; follows window moves/resizes; target-window-closed ends/pauses with warning | capture | limited (no TCC: window capture implemented, resize/scale policy tested) | Record TextEdit window while moving it; output stays window-sized |
| REC-03 | Capture | Record a custom area | docs | Area rect in display points, drawn with overlay; stored in session.json | capture+ui | limited (no TCC: area capture implemented; geometry math tested) | Area 800×600 → video 800×600 (×scale) |
| REC-04 | Capture | Source picker (display / window / area) in toolbar | docs/assumption | Vertical toolbar with three modes and live thumbnails | ui | implemented (ui: popovers via UI snapshots; live interaction limited: no TCC) | Switch modes, each starts correct capture |
| REC-05 | Capture | Area/window selection overlay, resizable, remembers last area | assumption | Full-screen overlay, drag/resize handles, size readout, Esc cancels | ui | implemented (ui: overlay snapshots only; mouse interaction unverified) | Draw, resize, record, rect matches |
| REC-06 | Capture | Countdown before recording | assumption | 3-2-1 countdown (configurable off/3/5 s); not captured | ui | implemented (ui: countdown overlay; timing by reading only) | Countdown not visible in output frame 0 |
| REC-07 | Capture | Start/stop via global shortcut and menu bar item | docs | Global hotkey (configurable), menu bar item with state | ui | implemented (ui: Carbon hotkeys register at launch; start/stop live limited: no TCC) | Hotkey starts and stops recording |
| REC-08 | Capture | Pause / resume during recording | docs | New segment per resume; pauses removed from source time (FORMATS.md) | capture | limited (no TCC: SessionLifecycleTests with injected services pass: pause/resume segments, no drift in 10k-segment test) | Record 3 s, pause 5 s, 3 s → duration ≈ 6 s, A/V in sync |
| REC-09 | Capture | Recording HUD (timer, pause, stop, mic level) | assumption | Small floating panel excluded from capture | ui | implemented (ui: HUD snapshots; exclusion from capture limited: no TCC) | HUD absent from exported file |
| REC-10 | Capture | Exclude own app windows from capture | docs/assumption | CaptureExclusions registered windows | capture | limited (no TCC: stream exclusion policy unit-tested only) | E2E: toolbar visible on screen, absent in recording |
| REC-11 | Capture | Frame rate 30/60 fps, VFR | assumption | maxFPS option; VFR timestamps preserved | capture | limited (no TCC: cadence/VFR cap unit tests at 30/60 Hz pass) | ffprobe frame timestamps monotonic, ≤60 fps |
| REC-12 | Capture | Retina / native pixel recording | assumption | pixel_size = points×scale; math tests (no Retina HW) | capture | limited (no Retina display; unit tests only) | Unit: scale 2 sizes |
| REC-13 | Capture | Hide desktop icons while recording | technical (hide-icons helper) | Option; restores icons on stop/crash | capture/ui | implemented (capture stream filter + ui toggle; Finder behaviour unverified) | Icons hidden in recording, restored after |
| REC-14 | Capture | Hide Dock icon / recording flag option | docs | Settings toggle for Yapcam Dock icon (accessory activation policy) | ui | implemented (ui: Dock toggle; build only) | Toggle hides Dock icon |
| REC-15 | Capture | Capture notifications option | docs | Option documented; macOS limits apply | capture | limited (OS-dependent) | Banner appears in recording when enabled |
| REC-16 | Capture | Create project from existing video | docs | Import MOV/MP4 → .yapcam (screen track only, no events) | core+ui | implemented (core Project.importVideo + ui menu; native encode check pending) | Import sample.mp4, edit, export |
| REC-17 | Capture | Record iPhone/iPad via mirroring/device | docs | Out of scope for first pass unless window capture of iPhone Mirroring window works (it is a window) | capture | limited (no device) | n/a |
| REC-18 | Capture | Recovery of interrupted recordings | technical ("recover unfinished recordings" prompt) | Prompt on launch for interrupted packages; recover finalizes segments | capture+ui | implemented (capture RecoveryTests pass incl. skipped-segment cases; ui relaunch prompt; real kill -9 untested; capture M3: 100 simulated crash trials + hour simulation per capture status (native MOV hour host gate pending)) | Kill -9 during recording → relaunch → recover → opens |
| REC-19 | Capture | Low-disk handling | assumption | Check free space at start, warn, stop gracefully with diskFull | capture | verified (capture session fault simulation: low disk during capture keeps interrupted package; ui <1 GB start block by reading; capture M3 limits work per capture status) | Simulated low space → package finalized, error shown |
| REC-20 | Capture | Permission onboarding | docs | Screen, mic, camera, accessibility, input monitoring guided panel | ui | implemented (ui: onboarding snapshots; permission table + ask-then-open tests) | Missing permission shows state and opens Settings |
| REC-21 | Capture | Speaker notes while recording | docs | Optional notes shown in HUD, stored in project | ui+core | implemented (core notes + ui toolbar popover + teleprompter panel; ui tests; live recording limited: no TCC) | Notes persist in project.json |

## B. Audio and devices

| ID | Area | Reference behavior | Src | Yapcam behavior | Team | Status | Acceptance test |
|---|---|---|---|---|---|---|---|
| AUD-01 | Audio | Record system audio | docs | SC audio capture → system.m4a, separate track (M1) | capture | limited (no TCC: system.m4a track implemented, PCM duration tests pass) | Play tone during recording; track RMS > threshold |
| AUD-02 | Audio | Record microphone | docs | AVCapture → mic.m4a, device picker, level meter | capture | limited (no mic HW; no-device path tested) | No-device: option disabled with message; no crash |
| AUD-03 | Audio | Mic device lost mid-recording | assumption | Recording continues, warning, mic track truncated | capture | limited (no HW; simulated) | Unit/simulated device loss |
| AUD-04 | Audio | Per-track volume (mic, system) | docs | audio.mic_gain_db / system_gain_db; mute | editor+core | integrated (editor Audio tab -> core audio gains; RealCoreRangesTests; audible effect in export unverified) | Set −∞ → exported track silent |
| AUD-05 | Audio | Volume over time (volume keyframes/segments) | docs (scrubber/volume) | Per-clip/segment gain | core+editor | implemented (editor volume ranges list -> core; not a timeline lane; export effect unverified) | Gain ramp audible in export |
| AUD-06 | Audio | Noise reduction / speech enhancement | technical (Core ML MossFormer2 speech-enhancement model, 48 kHz, ships in app) | Apple VoiceProcessing or small model; marked M2-late | render | integrated (core toggle/settings + render preview/export mic enhancement path, SpeechTimelineTests; core/render status 'native checks pending'; editor toggle/processor wiring still required -> editor; speech quality unverified) | Noisy sample → lower noise floor |
| AUD-07 | Audio | Background music library + volume | technical (bundled music in 5 genres) | Own royalty-free tracks only (not reference files); loop, fade | editor+render | integrated (core model + editor UI; editor TextAndMusicTests/unit tests; pixels/audio unverified on a Metal host) | Add music, export has 3rd source |
| AUD-08 | Audio | Mouse click sounds | docs / technical (click sound sets) | Own click sounds (2 variants), volume | render | integrated (core model + editor UI; editor TextAndMusicTests/unit tests; pixels/audio unverified on a Metal host) | Click event → audio impulse at time |
| AUD-09 | Audio | Recording start/stop sounds | technical | Optional | ui | implemented (ui: start/stop sounds, played outside capture; build only) | Setting toggles |
| AUD-10 | Audio | Captions via local transcription | docs / technical (whisper binary) | On-device speech recognition (Speech/ whisper.cpp later); caption style | editor | integrated (capture transcription -> core import_transcript -> editor caption UI; unit tests; real Speech host check pending; render stage verified on Metal M4 (Lead run 03:15, YAPCAM_REQUIRE_RENDER_HARDWARE=1, render 86/86)) | Transcribe sample; caption times align ±200 ms |
| AUD-11 | Audio | Silence detection → speed-up/cut | technical (detect-silence) | Offer to cut/speed silent ranges | core+editor | implemented (core PCM silence analysis verified; AAC decode unavailable in sandbox; editor Audio tab -> cut/speed) | Silence range detected in known file |

## C. Camera

| ID | Area | Reference behavior | Src | Yapcam behavior | Team | Status | Acceptance test |
|---|---|---|---|---|---|---|---|
| CAM-01 | Camera | Record webcam as separate track | docs | camera.mov host-time stamped | capture | limited (no camera; no-device path) | No camera: option unavailable, message |
| CAM-02 | Camera | Camera shape, size, position, radius, shadow, mirror | docs | camera.* settings | editor+render | integrated (editor Camera tab -> core -> render; pixel output unverified, no camera; render stage verified on Metal M4 (Lead run 03:15, YAPCAM_REQUIRE_RENDER_HARDWARE=1, render 86/86)) | Fixture camera track: rect/shape in frame |
| CAM-03 | Camera | Dynamic camera layouts (hide/enlarge/fullscreen over time) | docs | camera layout segments on timeline | core+editor | integrated (editor layout lane -> core layouts; Rust layer tests; pixels unverified; render stage verified on Metal M4 (Lead run 03:15, YAPCAM_REQUIRE_RENDER_HARDWARE=1, render 86/86)) | Layout change at t → frame description changes |
| CAM-04 | Camera | Background removal for camera | technical (matting/segmentation models) | Vision person segmentation | render | limited (no camera: render Vision matting wired through frameExtras, synthetic tests; editor forwards render effects; render stage verified on Metal M4 (Lead run 03:15, YAPCAM_REQUIRE_RENDER_HARDWARE=1, render 86/86)) | Synthetic still image test |
| CAM-05 | Camera | Face detection to frame camera | technical (face-detector) | Vision face rect | render | limited (no camera: render Vision face framing wired through frameExtras, synthetic tests; render stage verified on Metal M4 (Lead run 03:15, YAPCAM_REQUIRE_RENDER_HARDWARE=1, render 86/86)) | Fixture image |
| CAM-06 | Camera | Camera lost mid-recording | assumption | Continue, warning | capture | limited | simulated |

## D. Cursor and input events

| ID | Area | Reference behavior | Src | Yapcam behavior | Team | Status | Acceptance test |
|---|---|---|---|---|---|---|---|
| CUR-01 | Cursor | Cursor recorded as data, rendered in editor | docs/technical | events.jsonl + cursors PNG, screen without cursor (M1) | capture | limited (no TCC: events + cursor image sidecar implemented) | Events count>0; video cursor-free |
| CUR-02 | Cursor | Click/scroll/move capture | docs | CGEventTap listen-only | capture | implemented (capture InputTranslationTests pass; live event tap limited: no TCC) | Scripted CGEvent clicks appear at right times |
| CUR-03 | Cursor | Smooth cursor movement toggle | docs | cursor.smoothing; off = raw | core+render | integrated (editor toggle -> core spring -> render; Rust frame goldens; pixels unverified) | Off: frame cursor == raw event pos |
| CUR-04 | Cursor | Cursor speed presets Slow/Mellow/Quick/Rapid + tension/friction/mass | docs | spring params; presets map to values | core | integrated (editor speed presets -> core spring params; Rust spring test) | Spring step response unit tests |
| CUR-05 | Cursor | Cursor size, show/hide, hide when idle, hide in sections | docs | cursor.size/visible/hide_when_idle + range overrides | core+editor | integrated (editor cursor tab + hidden-sections lane -> core ranges) | Hidden section frame has no cursor |
| CUR-06 | Cursor | Cursor sets (macOS, tahoe, touch, many custom) | technical (assets: ~24 sets) | Native macOS cursor images + a few own styles | render | integrated (original vector cursors in render + core cursor catalog + editor palette/shape/size picker 2dc85e9 with OverlayTests; render stage verified on Metal M4 (Lead run 03:15); larger set collection not planned beyond catalog) | Switch set changes image |
| CUR-07 | Cursor | Click effect (ripple/ring) | docs/assumption | cursor.click_effect | render | integrated (editor click effect -> core -> render procedural effect; pixels unverified; render stage verified on Metal M4 (Lead run 03:15, YAPCAM_REQUIRE_RENDER_HARDWARE=1, render 86/86)) | Click frame differs from idle frame |
| CUR-08 | Cursor | Cursor motion blur | docs | strength slider | render | integrated (editor cursor motion blur control -> core extras -> render; render stage verified on Metal M4 (Lead run 03:15, YAPCAM_REQUIRE_RENDER_HARDWARE=1, render 86/86)) | Fast move frame blurred |
| CUR-09 | Cursor | Loop cursor to start position | assumption | option | core | integrated (editor loop toggle -> core) | last pos = first pos |
| CUR-10 | Cursor | Keystroke display (opt-in) | assumption (key events in format) | key overlay with modifiers | capture+render | integrated (core model + editor UI; editor TextAndMusicTests/unit tests; pixels/audio unverified on a Metal host; render stage verified on Metal M4 (Lead run 03:15, YAPCAM_REQUIRE_RENDER_HARDWARE=1, render 86/86); main 8600691: core key_overlay index (p99 0.07 ms with 36k keys per core status)) | cmd+k shows overlay |
| CUR-11 | Cursor | Cursor click highlights/spotlight | assumption | optional | render | integrated (editor spotlight radius -> core extras -> render; render stage verified on Metal M4 (Lead run 03:15, YAPCAM_REQUIRE_RENDER_HARDWARE=1, render 86/86)) | – |

## E. Zoom

| ID | Area | Reference behavior | Src | Yapcam behavior | Team | Status | Acceptance test |
|---|---|---|---|---|---|---|---|
| ZOM-01 | Zoom | Auto zoom from clicks | docs | analyzer creates zoom regions at click clusters (zooms[] mode=auto) | core | integrated (core auto.rs tests + editor regenerate/follow; fixture clicks only, no real recording) | Fixture with 3 click clusters → 3 zooms |
| ZOM-02 | Zoom | Manual zoom: add/move/resize on timeline, target point (M1) | docs | add_zoom command; target dot in preview | core+editor | verified (testM1OpenEditExport: crop changes at mid-zoom (core level; UI untested)) | Add zoom, frame at mid has zoom rect |
| ZOM-03 | Zoom | Zoom level per zoom | docs | scale 1…N | core | integrated (editor scale slider -> core) | Scale applied exactly |
| ZOM-04 | Zoom | Auto/Manual per zoom toggle | docs | mode switch | core+editor | integrated (editor per-zoom Auto/Manual -> core) | Switch changes target source |
| ZOM-05 | Zoom | Disable automatic zooms (global/per zoom) | docs | setting | core | integrated (editor auto-zoom toggle -> core) | No auto zooms generated when off |
| ZOM-06 | Zoom | Zoom speed presets + tension/friction/mass | docs | ease_in/out + spring | core | integrated (editor speed preset -> core ease/spring) | Curve unit tests (no overshoot unless set) |
| ZOM-07 | Zoom | Camera follows cursor while zoomed | docs | pan with cursor, dead-zone | core | integrated (editor follow-cursor toggle -> core pan; Rust frame goldens) | Cursor at edge pans view |
| ZOM-08 | Zoom | Instant zoom | docs | zoom without easing | core | integrated (editor 'Instant (no easing)' per zoom) | ease=0 |
| ZOM-09 | Zoom | Zoom motion blur | docs | strength slider | render | integrated (editor zoom motion blur control; pixels unverified; render stage verified on Metal M4 (Lead run 03:15, YAPCAM_REQUIRE_RENDER_HARDWARE=1, render 86/86)) | – |
| ZOM-10 | Zoom | Zoom-aware sharpness (render from source resolution) | assumption | sample source at needed resolution | render | implemented (render samples source at native size; sharpness check pending Metal host test; render stage verified on Metal M4 (Lead run 03:15, YAPCAM_REQUIRE_RENDER_HARDWARE=1, render 86/86)) | Zoomed export has native detail |

## F. Timeline / editing

| ID | Area | Reference behavior | Src | Yapcam behavior | Team | Status | Acceptance test |
|---|---|---|---|---|---|---|---|
| EDT-01 | Edit | Preview player play/pause/seek/scrub (M1) | docs | PreviewPlayer | render+editor | verified (editor LiveWindowTests: 120 scrubs median 16.5 ms, p95 20 ms on real window) | Seek lands on right frame |
| EDT-02 | Edit | Split / trim / delete range (cuts) | docs | split, delete_range; all tracks shift together | core+editor | verified (testAudioVideoDurationsAgreeAfterCut + testSpeedAndCutChangeExportedDuration) | Cut; audio and video remain in sync |
| EDT-03 | Edit | Speed up segments | docs | set_speed per clip; audio pitch handling | core+render | integrated (editor speed per clip -> core -> render clip mapping tests) | 2× clip halves duration |
| EDT-04 | Edit | Speed up typing segments automatically | docs | detect key bursts → speed | core | integrated (editor Audio tab 'speed up typing' -> core autoSpeedTyping; fixture keys only) | Fixture keystrokes |
| EDT-05 | Edit | Undo/redo | assumption | command stack | core+editor | verified (testCutUndoRedoDuration + testNoDriftOverManyEdits (300 edits)) | 100 ops undo/redo exact |
| EDT-06 | Edit | Autosave + reopen | docs | autosave journal, project.json.prev | core | verified (editor RealStackTests journal restore/discard + core autosave Rust tests; kill -9 on app untested) | Kill app, reopen, edits intact |
| EDT-07 | Edit | Aspect ratio + crop | docs | canvas.aspect, screen crop | core+render | integrated (editor aspect/crop -> core canvas; output sizes 1440x1080/1080x1080/1080x1920/2520x1080 awaiting core confirmation) | 9:16 export size correct |
| EDT-08 | Edit | Mask/highlight regions | docs | rect/rounded highlight with dim outside | core+render | integrated (editor Overlays tab + lane + rect editor -> core highlights; editor OverlayTests; pixels unverified; render stage verified on Metal M4 (Lead run 03:15, YAPCAM_REQUIRE_RENDER_HARDWARE=1, render 86/86)) | – |
| EDT-09 | Edit | Annotations / text overlays | assumption | text blocks on timeline | editor+render | integrated (core model + editor UI; editor TextAndMusicTests/unit tests; pixels/audio unverified on a Metal host; render stage verified on Metal M4 (Lead run 03:15, YAPCAM_REQUIRE_RENDER_HARDWARE=1, render 86/86)) | – |
| EDT-10 | Edit | Command menu (⌘K style) | docs | searchable action palette | editor | verified (editor palette unit tests; also cheat sheet) | – |
| EDT-11 | Edit | Copy current frame as image | docs | clipboard PNG of composited frame | editor | verified (editor RealStackTests: copy-frame PNG 1920x1080) | Clipboard image equals frame |
| EDT-12 | Edit | Timeline zoom, snapping, keyboard shortcuts | docs | per shortcut list | editor | verified (editor snapping/geometry/gesture unit tests; one undo step per gesture) | – |
| EDT-13 | Edit | Reactions (emoji reactions on timeline) | docs | emoji sprites with animation | editor+render | integrated (core model + editor UI; editor TextAndMusicTests/unit tests; pixels/audio unverified on a Metal host; render stage verified on Metal M4 (Lead run 03:15, YAPCAM_REQUIRE_RENDER_HARDWARE=1, render 86/86)) | – |
| EDT-14 | Edit | Animations (intro/outro, scene transitions) | docs (Look & Feel/animations) | entrance/exit animation presets | core+render | integrated (editor animation modes UI -> core; core supports fade + added modes per editor c7d941f; pixels unverified; render stage verified on Metal M4 (Lead run 03:15, YAPCAM_REQUIRE_RENDER_HARDWARE=1, render 86/86)) | – |

## G. Look and canvas

| ID | Area | Reference behavior | Src | Yapcam behavior | Team | Status | Acceptance test |
|---|---|---|---|---|---|---|---|
| LOK-01 | Canvas | Background: solid, gradient (M1) | docs | canvas.background | render | verified (RenderTests solid + gradient pixel tests; need Metal host; render stage verified on Metal M4 (Lead run 03:15, YAPCAM_REQUIRE_RENDER_HARDWARE=1, render 86/86)) | Pixel check of background |
| LOK-02 | Canvas | Background: wallpaper images in categories | technical (9 categories) | Own generated gradients/images only | render | integrated (render BackgroundLibrary + editor wallpaper picker cc5a72e; tests; 12 original images; render stage verified on Metal M4 (Lead run 03:15, YAPCAM_REQUIRE_RENDER_HARDWARE=1, render 86/86)) | – |
| LOK-03 | Canvas | Background: macOS wallpaper / custom image | technical | custom image import; system wallpaper | render | verified (editor ReviewFixTests: import image background, resolve asset, render frame; render stage verified on Metal M4 (Lead run 03:15, YAPCAM_REQUIRE_RENDER_HARDWARE=1, render 86/86)) | – |
| LOK-04 | Canvas | Background blur / noise texture | technical (noise asset) | option | render | integrated (editor background blur/noise controls; pixels unverified; render stage verified on Metal M4 (Lead run 03:15, YAPCAM_REQUIRE_RENDER_HARDWARE=1, render 86/86)) | – |
| LOK-05 | Canvas | Padding (M1), corner radius, shadow, inset/border | docs | canvas.* | render | verified (RenderTests crop + rounded-corner pixel test; shadow/inset unverified; render stage verified on Metal M4 (Lead run 03:15, YAPCAM_REQUIRE_RENDER_HARDWARE=1, render 86/86)) | Frame: content rect inset equals padding |
| LOK-06 | Canvas | Window device frame / macOS window chrome | technical (devices assets) | optional frames | render | integrated (editor window frame control -> core extras -> render; render stage verified on Metal M4 (Lead run 03:15, YAPCAM_REQUIRE_RENDER_HARDWARE=1, render 86/86)) | – |
| LOK-07 | Canvas | Output size/aspect presets | docs | canvas.output_size | core | integrated (editor aspect presets set canvas.output_size) | – |
| LOK-08 | Canvas | Watermark | n/a | none: no watermark ever | – | verified (by design) | Export has no overlay |

## H. Presets and project

| ID | Area | Reference behavior | Src | Yapcam behavior | Team | Status | Acceptance test |
|---|---|---|---|---|---|---|---|
| PRJ-01 | Project | Package save/open (M1) | docs | .yapcam package, atomic writes | core | verified (testSaveReopen (.prev kept)) | Save/open roundtrip |
| PRJ-02 | Project | Presets create/apply/share (file-based) | docs | export/import preset JSON (local file sharing only) | core+ui | integrated (ui Presets menu: save/apply/import/export/library -> core presets; YapcamUITests) | Apply preset changes settings |
| PRJ-03 | Project | Default settings for new recordings | docs | settings panel | ui | implemented (ui: Settings Recording tab; build only) | – |
| PRJ-04 | Project | Recent projects, open file association | assumption | – | ui | implemented (ui: recent projects + .yapcam association; build only) | – |
| PRJ-05 | Project | Missing media detection + relink | architecture | open throws missingMedia | core+ui | verified (testMissingMediaIsReported) | Remove screen.mov → clear error |
| PRJ-06 | Project | Extract raw recording files | docs | reveal/export raw tracks | ui | implemented (ui: extract raw files; build only) | Files copied |
| PRJ-07 | Project | Duplicate project / rename / delete | assumption | – | ui | implemented (ui: rename/duplicate/trash; YapcamUITests) | – |
| PRJ-08 | Project | Newer-schema refusal, old-schema migration | architecture | – | core | verified (core ProjectTests: schema_version 42 refused with unsupportedVersion; migration of older versions untested) | Test fixtures |

## I. Export

| ID | Area | Reference behavior | Src | Yapcam behavior | Team | Status | Acceptance test |
|---|---|---|---|---|---|---|---|
| EXP-01 | Export | MP4 export 1080p H.264 (M1) | docs | Exporter | render | verified (PipelineE2E testM1OpenEditExport: ffprobe 1080p) | ffprobe 1920×1080, duration ±1 frame |
| EXP-02 | Export | Resolution options (720/1080/1440/2160/…) | docs/assumption | outputHeight | render | implemented (E2E verifies 720 and 1080; 1440/2160 untested) | per size ffprobe |
| EXP-03 | Export | FPS 24/30/60 | docs | fps | render | verified (testFPSAndNoAudio: r_frame_rate 60/1, 300 frames) | ffprobe r_frame_rate |
| EXP-04 | Export | Quality/compression level | docs | quality 0…1 | render | implemented (quality/bitrate settings validated; bitrate monotonic check not done) | bitrate monotonic |
| EXP-05 | Export | GIF export | docs, technical | native ImageIO GIF writer (no gifsicle) | render | verified (testFormatsAndPresets: GIF 30 frames) | valid GIF, frame count |
| EXP-06 | Export | MOV export, HEVC codec | docs(3rd party), assumption | format/codec | render | verified (testFormatsAndPresets: HEVC mp4 + H.264 mov) | – |
| EXP-07 | Export | Export progress/cancel, partial file removed | assumption | Task cancel | render+ui | verified (testCancelRemovesPartialFile) | Cancel → no file |
| EXP-08 | Export | Preview == export | architecture | same compositor | render | implemented (same evaluator; E2E checks zoom crop only; pixel diff vs preview not done: needs Metal host; render stage verified on Metal M4 (Lead run 03:15, YAPCAM_REQUIRE_RENDER_HARDWARE=1, render 86/86)) | ffmpeg frame diff < threshold |
| EXP-09 | Export | Performance settings (hardware encode, parallelism) | docs | – | render | implemented (render metrics; ExportSyncTests prints benchmark; no hardware numbers yet; render stage verified on Metal M4 (Lead run 03:15, YAPCAM_REQUIRE_RENDER_HARDWARE=1, render 86/86)) | – |
| EXP-10 | Export | Quick share widget / copy file | docs | reveal in Finder / drag file; no upload | ui | limited (no cloud) | – |
| EXP-11 | Export | Verification: reopen output and check tracks | contract | Exporter | render | verified (Exporter reopens output; E2E ffprobe agrees) | – |

## J. Out of scope (cloud / account / commerce)

| ID | Area | Reference behavior | Src | Yapcam behavior | Team | Status |
|---|---|---|---|---|---|---|
| OOS-01 | Cloud | Shareable links, comments on links | docs | out of scope (no cloud) | – | limited (out of scope) |
| OOS-02 | Account | Login, license, subscription, payment | docs | out of scope | – | limited (out of scope) |
| OOS-03 | Telemetry | Crash reporting/analytics (Sentry in reference) | technical | none | – | limited (out of scope) |
| OOS-04 | Update | In-app auto-update | technical | out of scope | – | limited (out of scope) |
| OOS-05 | Web | Email address update, website | docs | out of scope | – | limited (out of scope) |
| OOS-06 | Diagnostics | Diagnostic info export | docs | local log export only (optional) | ui | implemented (ui: Export Diagnostics...; build only) |

## K. Additional options found in official guides (audit 2026-10-15)

| ID | Area | Reference behavior | Src | Yapcam behavior | Team | Status | Acceptance test |
|---|---|---|---|---|---|---|---|
| CUR-12 | Cursor | "Always use default system cursor" (keep system cursor for e.g. text selection) | docs | cursor option | core+editor+render | integrated (core model + editor UI; editor TextAndMusicTests/unit tests; pixels/audio unverified on a Metal host) | Option on: I-beam recorded as arrow |
| CUR-13 | Cursor | Rotate cursor slightly while moving | docs | cursor.rotate_on_move | core+editor+render | integrated (core model + editor UI; editor TextAndMusicTests/unit tests; pixels/audio unverified on a Metal host) | Fast move frame shows tilt |
| CUR-14 | Cursor | Stop cursor movement before end of video | docs | cursor option | core+editor | integrated (core model + editor UI; editor TextAndMusicTests/unit tests; pixels/audio unverified on a Metal host) | Last N ms position constant |
| CUR-15 | Cursor | Remove cursor shakes (tiny jitters) | docs | filter in evaluator | core+editor | integrated (core model + editor UI; editor TextAndMusicTests/unit tests; pixels/audio unverified on a Metal host) | Jitter < threshold removed |
| CUR-16 | Cursor | Optimize original cursor types (less rapid type flicker) | docs | debounce cursor id changes | core | integrated (core model + editor UI; editor TextAndMusicTests/unit tests; pixels/audio unverified on a Metal host) | Flicker fixture collapses |
| CUR-17 | Cursor | Cursor type: macOS or Touch | docs | = CUR-06 (touch style exists in render) | render+editor | implemented (render has recorded/pointer/touch; no picker) | – |
| ANI-01 | Motion | Cursor animation style: Smooth / Medium / Rapid / None (guide wording; search snippet said Slow/Mellow/Quick/Rapid – to observe) | docs | = CUR-04 presets; add "None" | core+editor | integrated (presets; 'None' = smoothing off) | – |
| ANI-02 | Motion | Screen animation style: Focused (stabilizes fast, readable) vs Smooth (fluid) | docs | zoom pan/settle presets | core+editor | integrated (core model + editor UI; editor TextAndMusicTests/unit tests; pixels/audio unverified on a Metal host) | Two presets differ in settle time |
| ANI-03 | Motion | Motion blur strength slider + advanced per-kind (cursor movement, zoom in/out, screen move) | docs | blur per kind | core+editor+render | integrated (core model + editor UI; editor TextAndMusicTests/unit tests; pixels/audio unverified on a Metal host) | – |
| LOK-09 | Canvas | Background types: Wallpaper, Gradient (from chosen color), Color (hex/palette), Image upload | docs | background kinds | editor+render | integrated (solid/gradient/blur/image; wallpaper library = LOK-02) | – |
| LOK-10 | Canvas | Padding 0 hides background; rounded corners; inset frame; shadow | docs | canvas.* | render | verified (RenderTests crop/radius pixel tests) | – |
| CAM-07 | Camera | "Camera during zoom": resize frame while zoomed, or keep constant | docs | camera.zoom_scale option | core+editor+render | integrated (core model + editor UI; editor TextAndMusicTests/unit tests; pixels/audio unverified on a Metal host) | Frame size changes at mid-zoom |
| EXP-12 | Export | Formats named by guide: GIF and MP4; resolutions HD and 4K; FPS 24/30/60; compression level does not affect time | docs | matches EXP-02/03/05 | render | implemented (E2E verifies 720/1080, 60 fps, GIF) | – |

## Audit log
Last audit: against main 25f2b97 (CUR-06 integrated); earlier 8600691 (M3 notes added to CUR-06/10, REC-18/19); earlier a02a89e (Metal hardware results folded in); earlier 78a8a0e; earlier 88f1995; earlier f640b35 (core worktree status read for unmerged core work); earlier 60902da (masks/intro-outro/presets/background library/transcription landed); earlier passes 6d91a7f, 4a1cee5, from code, team status files and test names (not re-run
by qa except E2E). Meaning: **implemented** = code present, not verified end to end;
**integrated** = reachable editor→core→render, no pixel/real-media proof; **verified (how)** = a
named test or measurement passed; **limited (why)** = cannot be verified here. Live-capture
rows are `limited (no TCC)` until Screen Recording is re-granted. Reference-observation of
Screen Studio is still blocked (see docs/status/qa.md), so option values stay TBD.

## Backlog: rows still open, per owning team (Lead hands these out)
No row is `todo`. Open work, by owner:

| Team | Rows | Missing |
|---|---|---|
| editor | AUD-06 | toggle UI + processor/URL wiring (core setting and render path exist) |
| render + Lead | all new layers | host/Metal verification (`YAPCAM_REQUIRE_RENDER_HARDWARE=1`) of text, reactions, captions, highlights, camera effects |
| capture + Lead | AUD-10 | real Speech-framework host check |
| Lead | live rows | Screen Recording grant; then QA live tests (REC-*, AUD-01, CUR-01/02, A/V sync) |
| qa + user | [observed] rows | morning observation session of Screen Studio |

Cross-team wiring gaps: none known in code; hardware/pixel verification needs a Metal host run
(`YAPCAM_REQUIRE_RENDER_HARDWARE=1`), live rows need the TCC grant.

## Metal hardware results (Lead run 03:15, main a02a89e, M4)
Render 86/86 on Metal incl. text, reactions, captions, highlights, camera effects, A/V sync within
one frame after export. Synthetic-source benchmarks (60 frames, no audio): export 1080p 4.7x,
4K 1.9x realtime; preview 1080p 57.6 fps (3 dropped / 2 s), 4K 58.9 fps (2 dropped / 2 s).
Camera rows remain synthetic-input only (no camera hardware). Source: docs/STATUS.md.
