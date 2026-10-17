# Craft rules for screen recordings

Hard rules. Break one only when the user asks for it, and say so.

## Cuts (the spine)

- Open tight: the first frame is at most 0.1 s before the first word. No "okay so", no mouse wiggle, no setup.
- 0.3–0.5 s between sentences. Pauses longer than 1.2 s are dead air: tighten them, unless the screen is showing
  activity or a result the viewer needs to read. `tighten_pauses` keeps gaps/tails with recorded typing, clicks
  or scrolls; `check` calls these `activity_pause` (info). Review loading visually; events cannot prove inactivity.
- Never cut inside a word. Cut on word boundaries; keep 0.3–0.5 s of breathing room around a cut.
- Never cut away a click or the frame where its result appears, unless the whole step goes.
- Tail ≤ 0.8 s after the last word, or after the last visible result if the video ends on the screen.
- Remove false starts and repeated takes: keep the last clean take. Remove "um", "uh", "erm". Keep "so", "like",
  "also", "actually" when they carry meaning; they are not fillers by default.
- Waiting (spinners, builds, uploads) goes: cut it, or speed it up when the progress matters to the story.
- Fast typing that the viewer does not need to read: speed it up (`auto_speed_typing`) instead of cutting.

## Zooms

- Zoom only on clicks and moments that carry the story: the button that does the thing, the field that changes,
  the result. Not on every click; never on navigation the viewer does not need to follow.
- Scale 1.5–2× typical (1.8× default). Above 2.5× only for tiny UI, and never on a blurry source.
- Lead 0.3–0.5 s: the zoom is in place before the click lands.
- Hold until the result is readable (typically 1.5–3 s), then release. A zoom is 1–8 s long.
- A click that navigates (new page, modal, the view changes) ends the zoom on its button: the zoomed frame would
  sit on empty space of the next page. `moments` exposes event-based `view_change_s`; `zoom_on_click` ends
  0.05 s before it and extends the lead to keep ≥ 1 s. `start_s`/`end_s` override timing in seconds within these
  safety bounds. Verify with `grab`: metadata can miss changes. If there is not 1 s of room, zoom on the result.
  Recordings often carry no window metadata (`view_change_s` null): then call `view_changes` for the clicks you
  will zoom BEFORE zooming and pass `end_s` = change − 0.05 to `zoom_on_click`, never a raw `update_zoom` after.
- Keep nearby context visible with `include:[click_index,{x,y,w,h}]` (normalized source rectangles). The tool
  fits the union at 1.3–2× or refuses if it cannot fit; verify the field/result/toast in `capture`. `include`
  sets the framing only: when an included click comes later, pass `end_s` so the zoom still covers it.
- When the result appears away from the click (a toast, a banner in a corner), end the zoom about 0.5 s after the
  click (keep ≥ 1 s) so the viewer sees the result at 1×, or `include` its rectangle if that still fits.
- Never stack or overlap zooms. Leave at least ~0.5 s at 1× between two zooms, or chain them as one zoom that pans.
- At most about one zoom per 8–10 s of video. A zoom that is everywhere means nothing.
- No zoom during fast typing (the frame jitters with the caret). Zoom on the result of the typing instead; `check` flags `zoom_during_typing`.
- Never zoom past the end of the video or across a cut that changes the scene.
- Entrances and exits are eased and short (< 600 ms).

## Text, highlights, captions

- Visual budget 0: never darken, blur or cover the picture to make text legible. The recording is the content.
- Text is one short line (≤ 6 words), placed where nothing happens, never on the action or the cursor path.
  A title in the padding keeps a margin (rect y ≥ 0.02, not flush with the edge) and appears with the screen it
  names, not over the previous step.
  No boxes, no eyebrows, no badges, no emoji unless asked.
- One flourish per beat: a zoom OR a text OR a highlight, not all three at once.
- Spotlight/highlight only to guide the eye to ONE thing the viewer would otherwise miss.
- Captions are the last layer, generated or adjusted after every cut is final. Never let two captions overlap.
- Entrances < 600 ms, no bounces.

## Before you finish

- `check` shows no errors.
- The first frame shows the screen as it is when the first word starts; the last frame is not a black or half-loaded
  screen.
- Every zoom frames the thing the narration talks about (verify in `capture`, not in your head).
