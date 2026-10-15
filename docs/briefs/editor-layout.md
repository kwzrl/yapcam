# Brief: editor layout redesign (user feedback 2026-10-15)

Owner: editor (ui for menu wiring only). The user compared our editor with Screen Studio
4.0.4 and wants that level of clarity. Keep our own visual design (calm, precise), but
adopt this structure. Functionality already exists; this is layout + controls.

## Window structure
```
┌ top bar: [folder] [trash]      Project name           [undo][redo] [Presets ▾] [Export] ┐
├──────────────────────────────────────────────────────┬──┬─────────────────────────────┤
│ left mini rail: zoom in/out of preview, crop, ...    │ic│ inspector panel (one section │
│                 big PREVIEW (fills, letterboxed)     │on│ at a time, scrollable)       │
│   above preview: [layout/aspect ▾] [Crop]  [Preview quality ▾]                │ra│                              │
├──────────────────────────────────────────────────────┴──┴─────────────────────────────┤
│ transport row: [cut tool]   0:03 ⏮ ⏯ ⏭ 0:05            [audio wave] [1x] [zoom slider] │
│ timeline: ruler; CLIP track (one tall rounded bar per clip, label "6s · 1x");          │
│           ZOOM track below (rounded bars "2x · Auto/Manual"); other lanes only when    │
│           they have content (camera layout, overlays, captions, cursor) — no empty     │
│           rows. Playhead full height. Timeline height ≈ 25 % of the window.            │
└────────────────────────────────────────────────────────────────────────────────────────┘
```
- Preview gets most of the space; the timeline is compact.
- **Inspector icon rail** (vertical, right of the preview): Background/Look, Cursor, Camera,
  Captions/Overlays, Audio, Keyboard shortcuts overlay, Animations/Motion. Icons with
  tooltips; selected state clear. Panel title + sections with sliders and segmented controls.

## Background panel (most visible, do first)
- Segmented: Wallpaper | Gradient | Color | Image | (Blur of screen).
- Wallpaper: a row of categories and a **thumbnail grid** of our own procedurally generated
  wallpapers (render team's library), selected outline, "Pick random".
- Sliders with value + Reset: Background blur, Padding, Screen rounded corners, Inset toggle
  + value, Shadow (size, opacity). Aspect/output size in the "layout" menu above the preview.

## Timeline interaction (keep existing logic)
- Click clip selects; drag edges trims; S/⌘B split; zoom bars draggable with edge handles;
  selecting a zoom opens the Zoom section in the inspector (scale, auto/manual, focus picker on
  the preview, transition speed).
- Cut tool (scissors) toggles split-on-click mode.

## Top bar
- Export button (accent) opens the existing export sheet; Presets menu applies/saves presets;
  undo/redo buttons mirror the menu.

## Acceptance
- Snapshot renders light/dark of: empty state, real recording loaded, zoom selected,
  each inspector section. Lead reviews the images before merge.
- All existing editor tests stay green; UI self-tests (`--editor-selftest`) still pass.
