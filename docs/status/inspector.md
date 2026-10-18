READY R7 (partial) | see list below; open: hide-captions needs core, preview right-click + ⌘/ wiring need editor/ui | swift build -j 4 ok; YapcamEditorTests 372 passed
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

- [x] Crop tool sheet (CropDraft: 8 handles + body drag, W/H/X/Y px fields, aspect lock, Confirm ↩ / Discard Esc, one undo step, ⌘K "Crop recording…").
- [x] CAM-33/MKT-037/038: Captions › "Edit transcript" sheet (paragraph text edit, word-level mapping, surplus words hidden not cut, pause lengths); `hideWords` (⌘⌫ hook), CAM-32 size Reset.
- [x] CAM-37/42: library music covers the timeline from 0 and replaces earlier library tracks (2 undo steps: remove+add); first background audio defaults to 0; first-level "Add background audio…"; mp4/mov/m4v accepted.
- [x] Advanced motion blur rows (cursor / zoom / pan via InheritedBlurRow); background blur slider for wallpaper/image.
- [x] B-09 ShortcutsGuide (`ShortcutsGuide.show()`, ⌘K "Keyboard shortcuts"), built from EditorKeyBindings.
- [x] S-03 export sheet: segmented Format/Resolution/Compression with descriptions + speed note, ⌘↩ copies to clipboard.
- [x] S-10 presets popover (click applies, gear menu incl. Show in Finder, inline create, Replace confirm).

## Edits in files outside my list (small, tell editor)
- Shell/StageControls.swift: crop popover -> `.sheet { CropToolView }`.
- Shell/TitleRow.swift: `PresetsMenu` now a button + `PresetsPopover`.
- CommandPalette.swift is mine; Tests/YapcamEditorTests/{TextAndMusicTests,OverlayTests}: first music at 0 (CAM-37).

## Assumptions
- Click preview synth duplicates the formula of `ProceduralAudio` (YapcamRender, internal). Request below to expose it publicly.
- Roundness is mapped in the editor on `camera.radius`/`camera.shape` because core has no `camera.roundness` field.

## Requests
- ui: bind ⌘/ (Help ▸ Keyboard Shortcuts) to `ShortcutsGuide.show()`; also callable from the recording HUD.
- editor: bottom transcript WordChip: double-click/Return inline edit -> `EditorModel.applyWordEdits(wordEdits(old:newText:))`; ⌘⌫ -> `hideWords(ids:)`.
- core: `captions.hidden` (CAM-31) so a "Hide captions" switch can be added; `camera.roundness` optional.
- core: CAM-37 library music replace in one undo step; BS-3/BS-4 core parts as in tasks.
- render: S-04 unavailable 4K web segments could show disabled (SegmentSwitch has no disabled state; kit change).
- render: make `ProceduralAudio.samples(for:)` / a `clickSampleWAV(variant:)` public so the editor preview uses the exact export sound.
- core: `zoom_settings` has no default mode / ease fields; "Use for new zooms" only stores default_scale.
- core: CAM-03 new projects should default `camera.mirrored` to false.
- editor (EditorView.swift): attach `.contextMenu { Button("Export Frame as Image…") { model.exportCurrentFrame() }; Button("Copy Frame") { model.copyFrameHandler?() } }` to the preview. I provide `EditorModel.exportCurrentFrame()` / `canExportFrame`.
- ui: File menu item "Export Frame as Image…" can call `EditorDocument.model.exportCurrentFrame()`.
