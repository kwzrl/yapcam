# Example: feature walkthrough with zooms on the key clicks

Calls are written as `{"name","arguments"}` shorthand for the Yapcam MCP tools; call the tools
themselves, and pass numbers as JSON numbers, not strings.

Request: "Make this a walkthrough of the new export dialog." Recording: 58 s, already tight, 1440×900 screen.

## 1. Read and pick the story clicks

```json
{"name":"moments","arguments":{}}
```

```
0.1–3.0   s0 "Here's the new export dialog."
2.4       click #0 (1290, 40) "Export" — toolbar
4.2–8.8   s1 "Pick a format, we now support GIF and WebM."
6.0       click #1 (620, 410) "Format ▾"
7.1       click #2 (640, 470) "WebM"
9.5–14.0  s2 "Quality is now a single slider."
10.8      click #3 (700, 520) slider drag
15.0–19.6 s3 "And you can export just the selection."
17.2      click #4 (560, 600) "Selection only" checkbox
21.0–24.0 s4 "Hit export and you're done."
22.6      click #5 (880, 690) "Export"
24.0–31.0 progress bar, then Finder reveals the file
```

Brief: target same length. Story clicks: #0 (opens the dialog), #1 (format), #3 (slider), #4 (checkbox),
#5 (export). #2 follows #1 within 1.1 s: one zoom covers both. Max ~1 zoom per 8–10 s → 5 zooms in 58 s is the
ceiling; drop #0 (the toolbar button is obvious and the dialog opens full-frame anyway).

## 2. Spine

Already tight. Still run it:

```json
{"name":"check","arguments":{}}
```

`warning pause at 26.1 s: 3.4 s` (progress bar). Keep 1 s of it so the viewer sees it finish:

```json
{"name":"tighten_pauses","arguments":{"max_gap_s":1.0,"keep_s":1.0,"from_s":24,"to_s":31}}
```

## 3. Zooms, one call per zoom, then check

```json
{"name":"zoom_on_click","arguments":{"click_index":1,"scale":1.8,"lead_s":0.4,"hold_s":2.2}}
{"name":"zoom_on_click","arguments":{"click_index":3,"scale":1.8,"lead_s":0.4,"hold_s":2.0}}
{"name":"zoom_on_click","arguments":{"click_index":4,"scale":2.0,"lead_s":0.4,"hold_s":1.6}}
{"name":"zoom_on_click","arguments":{"click_index":5,"scale":1.6,"lead_s":0.4,"hold_s":1.4}}
{"name":"check","arguments":{}}
```

The hold on #1 is 2.2 s so it also covers click #2 (WebM) — one zoom, not two stacked.

## 4. Verify the picture

```json
{"name":"capture","arguments":{"times":[5.6,6.0,8.2,10.4,12.8,16.8,17.2,22.2,22.6,24.5]}}
```

The sheet shows the zoom on #3 framing the slider's left half; the drag goes to the right edge out of frame. Fix
the largest problem: undo that zoom and place it on the drag's midpoint.

```json
{"name":"undo","arguments":{}}
{"name":"zoom_on_click","arguments":{"at_s":11.4,"scale":1.6,"lead_s":0.5,"hold_s":2.0}}
{"name":"capture","arguments":{"times":[11.0,12.6]}}
```

## 5. Reply

"Added 4 zooms: format menu, quality slider, selection checkbox, export. Shortened the progress wait to 1 s."
