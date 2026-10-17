# inspector status

R7 progress (Claude, team/inspector). Done items have tests in Tests/YapcamEditorTests/ReferenceAlignmentTests.swift.

- [x] BS-4 editor part: presets keep `animation_style`=preset id (custom only for hand-tuned sliders); duplicate Screen animation picker removed.
- [x] BS-2: Cursor section has one "Animation" segment (Smooth/Medium/Rapid/None) sharing state with Animations; Smoothing/Movement speed rows removed.
- [x] BS-10: Click sound moved under Cursor (None/Soft/Crisp, 0–100 % volume -> gain_db, default 25 %, Reset, "Play click preview"); Audio shows a pointer note.
- [x] BS-11: zoom panel: Disable zoom first, mode hints, Level "2.0×" + Reset + hint, "Use for new zooms" (writes default_scale).
- [x] BS-12: manual zoom shows unzoomed-frame thumbnail with draggable dot (AgentFrameRenderer.grab, off-main).
- [x] CAM-15/16: per-layout 9-point camera position (centre included, global grid too) and "Custom camera size" (10–75 %) on overlay layouts.
- [x] CAM-04: Roundness slider (editor-side mapping: radius = r*64 pt, 100 % = circle). CAM-03: Mirror camera also in Camera layout.
- [x] Task 9 (part): "Export current frame as image…" (PNG/JPEG) in ⌘K palette.

## Assumptions
- Click preview synth duplicates the formula of `ProceduralAudio` (YapcamRender, internal). Request below to expose it publicly.
- Roundness is mapped in the editor on `camera.radius`/`camera.shape` because core has no `camera.roundness` field.

## Requests
- render: make `ProceduralAudio.samples(for:)` / a `clickSampleWAV(variant:)` public so the editor preview uses the exact export sound.
- core: `zoom_settings` has no default mode / ease fields; "Use for new zooms" only stores default_scale.
- core: CAM-03 new projects should default `camera.mirrored` to false.
- editor (EditorView.swift): attach `.contextMenu { Button("Export Frame as Image…") { model.exportCurrentFrame() }; Button("Copy Frame") { model.copyFrameHandler?() } }` to the preview. I provide `EditorModel.exportCurrentFrame()` / `canExportFrame`.
- ui: File menu item "Export Frame as Image…" can call `EditorDocument.model.exportCurrentFrame()`.
