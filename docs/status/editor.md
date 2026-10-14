# editor status

READY (pending commit hash below) editor on real core/render: EditorDocument, EditorWindows.open (recovery prompt + relink), timeline, M2 inspectors, lanes, palette

## Done (verified)
- **Real adapters** (`Adapters.swift`): `CoreEditingProject` over `Project`, `PreviewPlayerAdapter` over `PreviewPlayer`, `RenderExportEngine` over `Exporter`, `ProjectRenderSource: RenderProjectSource` (core→render bridge; nobody else provides it). Verified by `RealStackTests` against `Tests/Fixtures/synthetic/basic.yapcam`: edit → save → reopen, invalid values rejected by core with state unchanged, clicks/geometry from core, journal restore/discard, missing media error, real export, copy-frame PNG 1920×1080.
- **Public API** per SWIFT_API.md: `EditorDocument(package:)` (open or create, optional `restoreUnsavedChanges:`), `EditorView(document:)`, `EditorWindows.open(package:)` (+ `saveAll()`), `EditorCommands` (include in app `.commands`).
- **Recovery prompt**: `EditorWindows.open` asks Restore/Discard/Cancel when `autosave/project.json` is newer than `project.json`. **Relink**: missing media → locate each file, copied to its package path, core re-verifies on reopen.
- **Editing**: transport (Space, J/K/L, ←/→ frame, ⇧← / ⇧→ 1 s), split (S, ⌘B), delete, trim start/end to playhead ([ / ]), undo/redo (menu + ⌘Z/⇧⌘Z), debounced autosave + save on close/terminate, snapping with guide, timeline zoom (+/−/⇧Z), multi-select zooms (⇧/⌘-click), speed per clip.
- **Gestures = one undo step** (zoom and lane drags preview locally, commit on release; sliders commit on release).
- **Zoom**: add (Z), drag body/edges, scale, enable toggle, focus point picker on preview (click/drag; uses core `screen_dest`/`screen_crop` so it is exact through padding and zoom), auto zooms toggle/follow cursor/speed preset, regenerate.
- **Inspector tabs**: Look (background solid/gradient/blur, aspect, padding, radius, shadow, inset, motion blur), Cursor (visible, size, smoothing, speed preset, hide idle, click effect, loop, hidden sections lane), Camera (visible, shape, size, radius, opacity, mirror, corners, layout lane; "no camera track" state), Audio (mute/volume per track, speed up typing, silence → cut/speed).
- **Lanes**: camera layouts, cursor hidden ranges (drag/resize/delete).
- ⌘K command palette (also cheat sheet), copy current frame (⇧⌘C → PNG clipboard), export sheet (720/1080, 30/60, progress/cancel/error/Show in Finder).
- Tests: `swift test` green, editor 42 tests (model, snapping, geometry, gestures, lanes, silence, palette, real-stack). Snapshots (real NSHostingView, light + dark) checked: selection states and lanes readable.

## Measured
- Scrub model path (model seek + core `yc_frame_at` geometry eval): ~3 µs per scrub step (no GPU). End-to-end scrub latency incl. Metal/AVPlayer seek is **not yet measured** (needs a live window).

## Known issues / reported to render
- **Export with audio hangs** (render): `Exporter` with `includeAudio: true` never finishes when the timeline includes fixture seg-000 audio (3 s clip). Video-only export of the same project takes 0.4 s; audio of seg-001 only works. Repro: `Project.create(fixture)`, `Exporter(settings: includeAudio true)`, `run` → no progress after ~59 % (frame ~93/150) and stalls forever, ~1 % CPU. The editor's real-export test therefore cuts seg-000 away first. This blocks the M1 path for recordings with system audio until render fixes it.

## Not implemented (no core/render support yet — will not fake)
- Text overlays/annotations (EDT-09), reactions (EDT-13), masks/highlight regions (EDT-08), intro/outro animations (EDT-14), captions (AUD-10), background music (AUD-07), cursor sets (CUR-06), crop UI (core `canvas.crop` exists; no UI yet), camera background removal/face framing (render config not driven by project data), audio volume-over-time lane (`audio.ranges` exists in core; no lane yet).
- J/K/L has no variable-rate shuttle (player has no rate API).
- Real camera/mic devices untested (none on this Mac); camera/mic inspector only checked via fakes + "no track" state.

## Next
- Audio ranges lane, crop controls, window-level manual test with a real recording once capture is integrated; measure real scrub latency; >30 min project check.

## Requests (to Lead)
- App integration: `Sources/Yapcam/Recording/Engine.swift` `openEditor(package:)` should call `EditorWindows.open(package:)`; call `EditorWindows.saveAll()` in `applicationWillTerminate`; add `EditorCommands()` to the app's `.commands`.
- render: fix audio export hang (above).
- core: add a `{"q":"clicks"}`-style query is present and used; `canvas.output_size` for non-16:9 presets is set by the editor (1440×1080, 1080×1080, 1080×1920, 2520×1080) — confirm these sizes.
