# Reference notes: motion, zoom, cursor, export (own words)

Sources: official guide pages ([docs]); values marked TBD need observation of the
reference app (blocked in first pass, see FEATURES.md caveat). Nothing here is copied.

## Cursor
- Cursor is stored as data (positions, clicks, cursor images) and drawn by the editor;
  the screen video contains no cursor.
- "Smooth cursor animations": on = path is eased through a spring toward the recorded
  position; off = raw recorded position each frame. Off helps when displayed and
  actual position drift apart.
- Speed presets: Slow, Mellow, Quick, Rapid; "Customize" exposes tension, friction, mass.
  Numeric preset values: TBD. Yapcam design [assumption]: critically damped spring,
  presets map to tension 80/140/220/340, friction = 2*sqrt(tension*mass) (mass 1).
- Motion blur has separate strength for cursor movement, zoom in/out and panning.

## Zoom
- Each zoom is Auto or Manual. Auto targets where clicks happened; with no clicks it
  does nothing. Manual: user places a target point in the preview and sets level.
- Zoom speed uses the same four presets and spring parameters.
- Instant zoom: no easing between levels.
- Yapcam auto-zoom heuristic [assumption]: cluster clicks within 1.5 s and 20 % of screen
  width; zoom starts 0.4 s before first click, ends 1.0 s after last; scale 2.0 default;
  follow cursor with dead-zone of 30 % of the visible rect.

## Export
- Formats per guide: MP4 and GIF (third-party mention of MOV unconfirmed).
- Settings: resolution, FPS (24/30/60 typical), compression/quality, format.
- Compression level does not change export time; fps, resolution, GIF do.
  4K ≈ 4× the time of HD. GIF > 1 min not recommended.
- Yapcam: MP4 H.264/HEVC, MOV, GIF via ImageIO; heights 720/1080/1440/2160.

## Look & feel [docs section titles]
Background, captions, reactions, animations, mask/highlight, aspect ratio and crop,
dynamic camera layouts, presets, command menu, copy frame as image.
