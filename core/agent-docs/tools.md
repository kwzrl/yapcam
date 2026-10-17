# Which tool when

Times: SECONDS on the current timeline for intention tools; NANOSECONDS for raw `apply`/`batch`.

## Understand (read, never changes anything)
- `moments {from_s?, to_s?}`: start here. Sentences, clicks (x/y, window/URL, next `view_change_s` or null), `view_changes` rows, shortcuts, printable typing text (even short runs), zooms and cuts. View changes come from metadata and cuts; verify pixels.
- `project_summary`: duration, counts, available signals, undo depth.
- `read_transcript`, `read_events`, `read_project`: raw detail when `moments` is not enough.
- `list_documents`: which editors are open (only when the target is unclear).

## See (eyes)
- `capture {times:[s], separate?, per_sheet?}`: the edit as export renders it, as a labelled contact sheet. Verify.
- `filmstrip {count?, from_s?, to_s?}`: evenly spaced frames; get the shape of a section or the whole video.
- `grab {times:[s], source?:"screen"|"camera"}`: raw source frames, before zoom/layout; read what is on screen.
- `waveform {from_s?, to_s?}`: silence and speech ranges; find dead air the transcript misses.

## Judge
- `check`: craft issues with severity, time and a fix hint, including `zoom_during_typing` warnings and `activity_pause` info. Run after every stage.

## Edit with intent (one undo step each, craft defaults built in)
- `trim_start_to_first_word {lead_s=0.1}`: open tight.
- `cut_words {from_word_index, to_word_index}`: remove a sentence, a false start, a retake. Indices from `moments`.
- `remove_fillers {words?}`: um/uh and friends.
- `tighten_pauses {max_gap_s=0.5, keep_s=0.35, from_s?, to_s?}`: dead air between sentences; preserves whole gaps/tails with typing, clicks or scrolls and reports `activity_pauses_kept`.
- `zoom_on_click {click_index | at_s, scale=1.8, lead_s=0.4, hold_s=1.6, start_s?, end_s?, include?}`: eased zoom; clamps 0.05 s before the next known view change and extends lead to retain ≥ 1 s without crossing a prior view change. Explicit endpoints use seconds and still obey these bounds. `include:[2,{x:0.2,y:0.3,w:0.4,h:0.2}]` fits the click plus other click indices/normalized source rectangles at 1.3–2×; refuses context too wide to fit.
- `transcribe`: no transcript yet? Generate one before cutting by words.

## Raw (last resort)
- `batch {commands:[…]}`: several core commands as ONE undo step (text via `add_annotation`, captions via
  `add_caption`, `update_zoom`, `set`, `auto_speed_typing`, …). Prefer this over many `apply` calls.
- `apply {command}`: one core command.
- `undo` / `redo`: one step. Use to back out your own last step when `capture` shows it was wrong.
- `seek`, `select`: show the user a spot or an item in the editor. Never count as changes.
- `save`: only when asked.
