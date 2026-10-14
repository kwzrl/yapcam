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

## Update 2026-10-15 (official guides, own words)
- Analysis limits: see FEATURES.md note. No [observed] data yet; numbers stay TBD.
- Cursor animation style options (guide): Smooth, Medium, Rapid, None. (An earlier search
  snippet listed Slow, Mellow, Quick, Rapid; conflict to resolve by observation.)
- Screen animation style: Focused (settles quickly, easy to read) or Smooth (more fluid).
- Motion blur: strength slider, with advanced separate amounts for cursor movement,
  zoom in/out, and moving the screen while zoomed.
- Cursor options: hide, size, type (macOS or Touch), always use system default cursor,
  hide when idle, loop position; advanced: rotate while moving, stop movement at end,
  remove shakes, optimize original cursor types.
- Background types: wallpaper, gradient (from one chosen colour), colour, image. Padding
  0 hides the background; rounded corners, inset frame, shadow.
- Camera: hide, position, mirror, roundness, size, and size behaviour during zoom.
- Export: formats MP4 and GIF; resolutions HD and 4K (we offer 720–2160); FPS 24/30/60;
  compression level does not change export time; GIF > 1 min discouraged.
- Auto zoom: per-zoom Auto or Manual; auto zooms to click locations, does nothing without
  clicks. Manual: move the target dot in the preview, set level in zoom settings.
- Speech enhancement ([technical]): the reference ships a Core ML 48 kHz speech-enhancement
  model; Yapcam needs its own approach (Apple voice processing or an original model).
