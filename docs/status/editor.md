# editor status

READY cc5a72e editor on real core/render: EditorDocument, EditorWindows.open (recovery prompt + relink), timeline, M2 inspectors, lanes, palette

## Done (verified)
- **Real adapters** (`Adapters.swift`): `CoreEditingProject` over `Project`, `PreviewPlayerAdapter` over `PreviewPlayer`, `RenderExportEngine` over `Exporter`, `ProjectRenderSource: RenderProjectSource` (core→render bridge; nobody else provides it). Verified by `RealStackTests` against `Tests/Fixtures/synthetic/basic.yapcam`: edit → save → reopen, invalid values rejected by core with state unchanged, clicks/geometry from core, journal restore/discard, missing media error, real export, copy-frame PNG 1920×1080.
- **Public API** per SWIFT_API.md: `EditorDocument(package:)` (open or create, optional `restoreUnsavedChanges:`), `EditorView(document:)`, `EditorWindows.open(package:)` (+ `saveAll()`), `EditorCommands` (include in app `.commands`).
- **Recovery prompt**: `EditorWindows.open` asks Restore/Discard/Cancel when `autosave/project.json` is newer than `project.json`. **Relink**: missing media → locate each file, copied to its package path, core re-verifies on reopen.
- **Editing**: transport (Space, J/K/L, ←/→ frame, ⇧← / ⇧→ 1 s), split (S, ⌘B), delete, trim start/end to playhead ([ / ]), undo/redo (menu + ⌘Z/⇧⌘Z), debounced autosave + save on close/terminate, snapping with guide, timeline zoom (+/−/⇧Z), multi-select zooms (⇧/⌘-click), speed per clip.
- **Gestures = one undo step** (zoom and lane drags preview locally, commit on release; sliders commit on release).
- **Zoom**: add (Z), drag body/edges, scale, enable toggle, focus point picker on preview (click/drag; uses core `screen_dest`/`screen_crop` so it is exact through padding and zoom), auto zooms toggle/follow cursor/speed preset, regenerate.
- **Inspector tabs**: Look (background solid/gradient/blur, aspect, padding, radius, shadow, inset, motion blur), Cursor (visible, size, smoothing, speed preset, hide idle, click effect, loop, hidden sections lane), Camera (visible, shape, size, radius, opacity, mirror, corners, layout lane; "no camera track" state), Audio (mute/volume per track, speed up typing, silence → cut/speed).
- **Lanes**: camera layouts, cursor hidden ranges (drag/resize/delete). Crop controls (canvas.crop) and volume-over-time ranges accepted by real core (RealCoreRangesTests).
- ⌘K command palette (also cheat sheet), copy current frame (⇧⌘C → PNG clipboard), export sheet (720/1080, 30/60, progress/cancel/error/Show in Finder).
- Tests: `swift test` green, editor 90 tests (model, snapping, geometry, gestures, lanes, silence, palette, real-stack). Snapshots (real NSHostingView, light + dark) checked: selection states and lanes readable.

- ZOM-04 per-zoom Auto/Manual switch (reaches core). EDT-05 verified: 100 mixed edits on real core undo to the exact initial state and redo to the exact final state. Short (<2 s) project: zoom clipped to project end; 3 h project: timeline fits, ruler steps ≥ 60 s.
- Export sheet has an "Include audio" toggle (default on). Workaround for the render hang; the real-export test uses audio off.

- ExportModel tests are deterministic (`waitUntilFinished()`, no fixed sleeps); 3 parallel `swift test --parallel --num-workers 8` runs were green. Note: after rebuilding the Rust lib, SwiftPM may keep a stale test binary — `rm -rf .build/arm64-apple-macosx/debug/YapcamPackageTests.xctest` forces a relink.
- Relink UI now uses core's transactional `Project.relink` (edits preserved, rollback on failure); real-core test removes `screen.mov`, relinks, edits intact.

## LOK-02 wallpapers (done)
Look tab → Wallpapers: category grid of the 12 original render wallpapers/gradients with thumbnails (generated off-main), one click applies (`BackgroundLibrary.apply`: gradients set colors, artwork imports a generated image) as one undo step; busy state, error surfaced, double-apply blocked. Verified: fake flow + real core (gradient then image wallpaper, thumbnail 192×108, undo). CUR-17 cursor style picker exists (recorded/pointer/touch).

## FEATURES section K (done)
Controls for every path core documented in "Guide audit": CUR-12 always default arrow, CUR-13 tilt while moving, CUR-14 stop cursor before end (toggle + length), CUR-15 remove tiny shakes, CUR-16 reduce cursor-type flicker, ANI-02 screen animation Custom/Focused/Smooth, CAM-07 camera size while zoomed, ANI-03 per-kind blur (zoom, screen move; "same as motion blur" = null inherits). Verified: real core accepts all, rejects out-of-range `camera.zoom_scale` with state unchanged, `motion_at` evaluates; inherit/explicit semantics tested. Not verified: how tilt/hold/blur look in a real preview (Metal host run).

## Build note
After rebasing onto a core that changed `EditCommand`, an incremental `swift test` crashed with SIGSEGV in unrelated tests (`objc_retain` in an `EditCommand` copy, ui's PresetTests) — stale object layouts. `swift package clean` + rebuild fixed it: 3 consecutive full runs green (212 tests, 30 suites). If a rebase gives random crashes, clean first.

## Review fixes (docs: /Users/larry/yapcam-fleet/reviews/review-ui-editor-1.md; tests in `ReviewFixTests.swift`)
- **#3 export destroyed existing file**: export now writes to a sibling temp file and replaces the destination (`replaceItemAt`) only after the exporter's verified success (`AtomicExport`); cancel/failure leave the original and remove the temp. Tests: failure, cancellation, success/fresh path.
- **#4 relink could delete the selected source**: relink goes through core's transactional `Project.relink` (stages a copy of the source first, backs up and rolls back); the old delete-then-copy code is gone. Test: user picks the changed file itself as the replacement → file survives.
- **#5 journal-only restore erased edits**: `EditorDocument` treats `autosave/project.json` as a project (open wins over create). Test: only the journal survives → padding/zoom restored.
- **#9 stale silence results**: any edit resets a completed analysis to idle; a result arriving after an edit (revision changed) is discarded. Tests: edit after found; edit while analyzing.
- **#11 stale click snaps**: click times are re-queried lazily after every project change (edit/undo/redo). Test on real core: deleteRange changes them, undo/redo restores them.
- **#12 image backgrounds**: `ProjectRenderSource.renderBackgroundAsset` resolves via `Project.mediaURL(atIndex:)`. Test: import background image, resolve asset and render a frame through the compositor.
- **#13 focus drag undo steps**: drag previews locally and commits one `update_zoom` on release. Test: 40 drag updates → one undo restores the original focus. (Limit: the preview picture changes on release, the marker follows live.)
- **#14 restored edits unsaved on close**: restored journal marks the model dirty (`markRecoveredUnsaved`) so close saves it. Tests: model + real core (restore → save → no prompt on reopen, edits kept).
- **#15 scrub self-snap**: scrubbing excludes the playhead from snap targets (`includePlayhead: false`); zoom/lane drags still snap to it. Test with 6 px distance.

## Measured
- **Live window** (real NSWindow + MTKView + GPU, `YAPCAM_LIVE_DIR=<dir> swift test --filter LiveWindowTests`): 120 scrub steps (model seek + `MTKView.draw()` incl. frame eval + Metal submit) median 16.5 ms, p95 20 ms, max 30 ms, i.e. one 60 Hz display frame (draw waits for the drawable); completion latency of the GPU/AVPlayer seek not separable. `cacheDisplay` does not capture the Metal layer, so preview pixels in that screenshot are not verified.
- Scrub model path (model seek + core `yc_frame_at` geometry eval): ~3 µs per scrub step (no GPU). End-to-end scrub latency incl. Metal/AVPlayer seek is **not yet measured** (needs a live window).

## Known issues / reported to render
- **Export with audio hangs** (render): `Exporter` with `includeAudio: true` never finishes when the timeline includes fixture seg-000 audio (3 s clip). Video-only export of the same project takes 0.4 s; audio of seg-001 only works. It is also nondeterministic: it stalled even with seg-000 cut away on a later run, so treat any audio export as unreliable. Repro: `Project.create(fixture)`, `Exporter(settings: includeAudio true)`, `run` → no progress after ~59 % (frame ~93/150) and stalls forever, ~1 % CPU. The editor's real-export test therefore exports without audio. This blocks the M1 path for recordings with system audio until render fixes it.

## Not implemented (no core/render support yet — will not fake)
- Text overlays/annotations (EDT-09), reactions (EDT-13), masks/highlight regions (EDT-08), intro/outro animations (EDT-14), captions (AUD-10), background music (AUD-07), cursor sets (CUR-06), camera background removal/face framing (render config not driven by project data), volume-over-time is an inspector list (add/edit/remove), not a timeline lane.
- J/K/L has no variable-rate shuttle (player has no rate API).
- Real camera/mic devices untested (none on this Mac); camera/mic inspector only checked via fakes + "no track" state.

## Backlog batch 2 (Lead, main 6d91a7f) — items 1–3 done
- **Render integration fix**: `ProjectRenderSource` now forwards `renderEffects` and `renderAudioRanges` to core/render's Project adapter. Before this, the editor's preview and export ignored highlights, fades, cursor/camera options and gain automation.
- **1) EDT-08 masks/highlights/spotlights**: timeline lane (drag/resize), Overlays tab (style Highlight/Spotlight/Mask, follows screen or canvas, fill/outline colors, width, radius, dim), rect editor over the preview (drag body, drag corners, one command per gesture, correct through zoom/crop). Core's 32-overlap limit surfaces as an error with state unchanged. Verified: model tests, real core accepts all kinds, `frameExtras` highlight_count 3 and render effects layers 3 via the editor's source, 33rd overlapping region rejected, rect drag = one undo step, snapshot of the Overlays tab.
- **2) EDT-14 intro/outro**: Overlays tab, none/fade with lengths (core: fade only). Verified against core fade_opacity at start/mid, and core rejection of non-positive length (state unchanged).
- **3) Controls**: CUR-08 cursor motion blur, CUR-11 cursor spotlight radius, cursor style (recorded/pointer/touch, CUR-06 partial), ZOM-08 "Instant (no easing)" per zoom, LOK-06 window frame, background noise (LOK-04), zoom motion blur, camera shadow / background removal / face framing toggles. Verified: all paths accepted by real core; extras reflect them.
- Not verified: pixels of highlights/fades in a real preview (needs a Metal host run through the app); UI interaction of the rect editor was tested through its geometry/model functions, not by synthesized mouse events.
- **4) core models landed (main f640b35) — editor UI done:**
  - **EDT-09 text / EDT-13 reactions**: timeline lane (drag/resize), Overlays tab (add text, 8 reaction glyphs, text, follows canvas/screen, size, text/background color with alpha, radius, opacity), box editor over the preview (move/resize, one command per gesture).
  - **AUD-10 captions**: caption lane + list (click to select/seek, edit text, timing by lane drag, style), "Generate captions from speech" imports `recording/transcript.json` when present, otherwise calls the app-provided `EditorWindows.transcriber` (needs YapcamCapture's TranscriptionService; see Requests); stale results (timeline changed meanwhile) are rejected; undoable.
  - **AUD-07 music**: library (Calm/Bright originals), add file (core `importMusic`), lane, volume, loop, fades, lower-during-speech ducking with amount, remove.
  - **CUR-10 key overlay**: enable, shortcuts only, visible duration, position rect, font size, text/background colors, radius, opacity.
  - **AUD-08 click sound**: enable, soft/crisp, volume.
  - **EDT-14 animations**: none/fade/zoom/slide ×4 for intro and outro with lengths.
  - Palette gained: add text/reaction/highlight/mask, generate captions, add music.
  - Verified (tests): model flows with fakes; real core accepts every path, effects_at returns annotation/reaction/caption text layers, audio_overlays returns click instructions and bright music, a real WAV imports as a file music track, transcript.json → captions → undo, empty text rejected with state unchanged, zoom entrance gives no black fade. Overlays inspector snapshot checked.
  - Not verified: pixels of text/captions/animations in a real preview or export (Metal host run), live mouse interaction of the box editor, real on-device transcription (needs the app's Speech permission), music audibility.

## Backlog state (checked after rebase on f0862b0)
Every editor-owned FEATURES row that core/render can support is implemented. Core still has no commands/model for annotations (EDT-09), reactions (EDT-13), masks (EDT-08), animations (EDT-14), captions (AUD-10) or background music (AUD-07), so those stay unimplemented (no fake UI). Blocked on others, not on editor work: app wiring (`LiveEngine.openEditor` still reveals in Finder, `EditorCommands` not installed — ui/Lead), render audio-export hang.

## Re-check on main 4a1cee5
- Rebased; full `swift test` green (146). App now calls `EditorWindows.open` (`LiveEngine.openEditor`) and `EditorWindows.saveAll()` on quit. Still not installed: `EditorCommands()` in the app menu (⌘Z/⇧⌘Z/⌘B won't act on the editor; the palette (⌘K) and toolbar do) — ui/Lead. Live capture→editor→export by hand is still blocked by the Screen Recording grant (qa F2).

## Next
- Window-level manual test (nothing left that needs no external input except this and real scrub latency) with a real recording once capture is integrated; measure real scrub latency; >30 min project check.

## Requests (to Lead)
- ui: set `EditorWindows.transcriber = { try await TranscriptionService().transcribe(package: $0) → encode RecordingTranscript to JSON Data }` at app start (it links YapcamCapture; the editor doesn't). Until then Generate captions only works with an existing recording/transcript.json.
- App integration: `Sources/Yapcam/Recording/Engine.swift` `openEditor(package:)` should call `EditorWindows.open(package:)`; call `EditorWindows.saveAll()` in `applicationWillTerminate`; add `EditorCommands()` to the app's `.commands`.
- render: fix audio export hang (above).
- core: add a `{"q":"clicks"}`-style query is present and used; `canvas.output_size` for non-16:9 presets is set by the editor (1440×1080, 1080×1080, 1080×1920, 2520×1080) — confirm these sizes.
