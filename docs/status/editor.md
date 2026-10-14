# editor status

READY 
(M1 UI layer builds + 18 tests green against fakes; real `EditorDocument`/`EditorWindows` blocked on core `Project` + render `PreviewPlayer`/`Exporter` landing on main — see Blockers.)

## Done (verified)
- Backend protocols (`EditingProject`, `PlaybackEngine`, `ExportEngine`) + in-module fakes. Verified: `swift test --filter YapcamEditorTests` (18 tests, Swift Testing).
- `EditorModel`: transport (play/pause, seek clamp, J/K/L), split at playhead, delete clip/zoom (ripple, last clip protected), add/move/resize zoom with bounds + min duration, undo/redo + player invalidation, debounced autosave + `saveNow()` on close + save-failure surfacing, snapping (playhead, clip edges, zoom edges, clicks, start/end) with guide. Verified by unit tests.
- `ExportModel`: progress, cancel, failure, done. Verified by unit tests with fake engine.
- SwiftUI: `EditorContent` (preview slot, inspector, transport, timeline with ruler/playhead/scrub/clip + zoom track, zoom drag body/edges), export sheet (1080/720, 30/60 fps, Show in Finder), `EditorCommands` (Undo/Redo/Split menu), key handling (Space, J/K/L, S, Z, ⌫, arrows, +/-). Verified: real NSHostingView snapshots, light + dark, readable selection states (run tests with `YAPCAM_SNAPSHOT_DIR=<dir>`).

## In progress
- Waiting on core/render to wire the real adapters.

## Next
- `EditorDocument`, `EditorView`, `EditorWindows.open`, recovery prompt (needs `Project.open` semantics + `autosave/` journal format from core).
- M2: speed changes, multi-select, focus-point picker, cursor/camera/audio inspectors (need core commands/paths).
- Scrub latency measurement (needs real PreviewPlayer).

## Assumptions
- Editor-side `EditorCommand` mirrors docs/FORMATS.md; adapter maps to core `EditCommand`.
- Timeline ns in zooms = timeline time; scroll offset owned by native ScrollView.
- J/K/L: no variable-rate shuttle until player supports rates.
- Canvas paths used: `canvas.padding`, `canvas.radius`, `canvas.shadow`, `canvas.background` (hex string) — core to confirm names.

## Blockers
- `Project`, `PreviewPlayer`, `PreviewView`, `Exporter` not on main yet.

## Requests (to Lead)
- Package.swift: add `.testTarget(name: "YapcamEditorTests", dependencies: ["YapcamEditor"])` (I use it locally uncommitted). Also an `AppKit`-free fixture is not needed.
- Please confirm canvas `set` paths and a query for click times (`{"q":"clicks"}`) returning timeline-mapped ns for snapping.
