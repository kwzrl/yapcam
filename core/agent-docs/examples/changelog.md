# Example: a 30–45 s "what's new" clip

Calls are written as `tool {arguments}`, the same shorthand as `yapcam://tools`. Call the Yapcam MCP tool
of that name; numbers stay JSON numbers.

Request: "Cut a 40-second what's-new clip from this for the changelog." Recording: 4:30 release demo covering
six features; the user named none.

## 1. Read, then write the brief before touching anything

```
moments {}
filmstrip {"count":12}
```

From `moments`, the six features start at s3 (dark mode, 0:18), s11 (search, 0:52), s19 (shortcuts, 1:40),
s27 (sync, 2:30), s35 (export presets, 3:10), s42 (bug fixes list, 3:55). The filmstrip shows that dark mode and
search are the most visual.

Brief (in the reply, since this is destructive for the whole video and the ask names no features):

"Plan: ~40 s, three features at ~12 s each: dark mode, search, export presets. One sentence of narration each plus
the click that shows it. Drop setup, shortcuts, sync and the bug list. OK?"

Wait for the answer. If the user says "go", proceed.

## 2. Spine: keep only the chosen sentences

Work from the END backwards so the earlier word indices stay valid, or re-read `moments` after each cut.

```
cut_words {"from_word_index":541,"to_word_index":702}
cut_words {"from_word_index":402,"to_word_index":470}
cut_words {"from_word_index":168,"to_word_index":388}
cut_words {"from_word_index":121,"to_word_index":150}
cut_words {"from_word_index":61,"to_word_index":95}
cut_words {"from_word_index":0,"to_word_index":38}
trim_start_to_first_word {}
remove_fillers {}
tighten_pauses {}
project_summary {}
check {}
```

Duration 47.2 s: over target. Re-read `moments` and drop the weakest remaining sentence (search: "and it's
really fast too"), then `tighten_pauses` again → 41.0 s.

## 3. Verify the spine before layers

```
moments {}
capture {"times":[0,12.3,12.7,26.4,26.8,40.9]}
```

Each cut point should show a calm screen on both sides. One jump at 12.5 s shows the cursor teleporting across
the screen; acceptable in a montage. A black frame would not be.

## 4. Layers: one zoom per feature, then captions last

```
zoom_on_click {"click_index":2,"scale":1.6}
zoom_on_click {"click_index":5,"scale":1.8}
zoom_on_click {"click_index":9,"scale":1.8}
batch {"commands":[
  {"op":"add_annotation","record":{"text":"Dark mode","tl_start_ns":300000000,"tl_end_ns":2300000000}},
  {"op":"add_annotation","record":{"text":"Instant search","tl_start_ns":12800000000,"tl_end_ns":14800000000}},
  {"op":"add_annotation","record":{"text":"Export presets","tl_start_ns":26900000000,"tl_end_ns":28900000000}}]}
check {}
capture {"times":[0.5,1.8,13.0,27.2,40.9]}
```

One flourish per beat: the title shows during the first second of each feature, the zoom starts after it.
Check in the sheet that no title sits on top of the zoomed area. Captions only if the user wants them, and then last.

## 5. Reply

"41 s clip: dark mode, instant search, export presets, a title and a zoom each. Cut setup, shortcuts, sync and
bug fixes."
