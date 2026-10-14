# Team editor (YapcamEditor)

Own: `Sources/YapcamEditor/**`, `Tests/YapcamEditorTests/**`.
Implement the `YapcamEditor` surface in `docs/SWIFT_API.md` on top of `Project`
(core) and `PreviewPlayer`/`Exporter` (render). Until they land, develop against
small test doubles inside your module; switch as soon as main has the real ones.

## Goal
An exceptionally good timeline for screen recordings that needs no editing training.

## M1
Editor window: preview (PreviewView) with transport (play/pause, time, J/K/L, space),
timeline with ruler, playhead, scrubbing, clip track, zoom track; split at playhead
(S / ⌘B), delete selection, add manual zoom at playhead; inspector with background
and padding; export sheet (MP4, 1080p, 30/60 fps) with progress, cancel, error and
"Show in Finder"; Undo/Redo wired to `Project` (menu + ⌘Z/⇧⌘Z); autosave (debounced
`save()` after edits + on close) and the recovery prompt.

## M2
Everything in FEATURES.md for editing: zoom editing (drag edges = duration, drag body
= time, focus point picker on preview, scale, transition speed, auto zooms toggle +
regenerate), cursor settings (size, smoothing, hide idle, click effect, visibility),
camera layout lane + editing, background/padding/radius/shadow/inset/aspect ratio,
speed changes, audio (volume, mute, noise/normalize if in reference), snapping
(playhead, clip edges, zoom edges, clicks), multi-select, keyboard shortcuts, zoom
in/out of timeline, very short (<2 s) and long (>30 min) projects, missing-media
relink UI.

## Quality bar
Selection states readable, snapping visible, no layout jumps while scrubbing.
Screenshot and check light + dark before marking done. Measure scrub latency.
