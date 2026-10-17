# Agent eval rubric

How a Yapcam agent edit is judged. `run_eval.py` scores the automatic rows into `score.json`; the visual rows
need a human (or a vision model) looking at `after-capture-*.png` / `after-filmstrip-*.png` of the run.

Golden packages come from `make_golden.py` (`~/yapcam-spike/eval/golden/<name>.yapcam`, labels in `golden.json`).
Times in golden.json are SOURCE seconds; the scorer maps them through the edited clip list.

## Automatic (score.json)

| Item | Key | Good | Notes |
|---|---|---|---|
| Structural issues after | `check_errors`, `check_warnings`, `check_kinds` | 0 errors; warnings only where the agent said why | from `check` after the last prompt |
| Cut inside a word | `cut_inside_words` | empty | a golden word kept 5–95 % |
| Dead air at start | `lead_s` | ≤ 0.5 (craft: ≤ 0.1) | timeline start of the first fully kept word |
| Pauses | `max_pause_s`, `pauses_over_1_2` | ≤ 1.2 / 0 | gaps between consecutive kept words; a deliberate pause over shown typing/loading may be fine — judge |
| Tail | `tail_s` | ≤ 0.8 | after the last kept word |
| Fillers removed | `fillers_left` of `fillers_total` | empty | golden um/uh/erm |
| False starts removed | `false_starts_left` | empty | golden `false_start` beats |
| Zooms on meaningful clicks | `meaningful_clicks_zoomed`, `zooms` | scenario-dependent (walkthrough: all story clicks) | a click is covered when it falls inside an enabled manual zoom |
| No zoom on accidental clicks | `zooms_on_accidental` | 0 | zoom whose only clicks are golden-accidental |
| Zooms on nothing | `zooms_on_nothing` | 0 unless intended | zoom containing no click |
| Zoom past end / overlap | `zooms_past_end`, `zoom_overlaps` | 0 / 0 | |
| Zoom length | `zoom_len_out_of_1_8` | 0 | craft: 1–8 s |
| Changelog content | `sentences_kept_by_role`, `duration_s` | all `feature` kept, `ramble`/`intro`/`outro` gone, 25–35 s | changelog scenario |
| Verified with capture | `verified_with_capture` | `true` for edits beyond a tweak | a capture/filmstrip after the LAST mutating call of the prompt; `null` = no edit |
| Effort | `turns`, `tool_calls`, `tool_errors`, `time_s`, `cost_usd` | lower is better at equal quality | from the stream-json `result` event |
| Reply length | `answer_lines`, `answer_words` | ≤ 3 lines, ≲ 50 words | chat.md asks for 1–3 short lines |

## Visual judgement (look at the PNGs)

- First frame: the screen as it is when the first word starts (no setup, no black).
- Each cut point: no jarring jump of the cursor or a half-finished UI state; no click lost.
- Each zoom: frames the thing the narration talks about, includes the result, does not sit on empty space after
  the click navigated away, is not cropped so the label becomes unreadable.
- Text/titles: one short line, in the padding or in empty space, never over the action; nothing darkened.
- Last frame: shows the final result (toast, loaded page), not a blank or half-loaded screen.
- Score each 0 (broken) / 1 (noticeable) / 2 (fine) and note what you saw.

## Conversation (scenario e)

- Prompt 2 ("make that zoom shorter") edits the SAME zoom id created in prompt 1 and makes it shorter.
- Prompt 3 ("undo the last change") restores exactly the prompt-1 state (compare `after1`/`after3.project.json`).
- Tweaks need no capture (playbook: "a tweak needs one call and `check`").
