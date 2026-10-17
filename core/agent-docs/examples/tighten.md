# Example: tighten a raw demo

Request: "Clean this up, it's too long." Recording: 2:14 demo of creating an API key in a dashboard.

## 1. Read

```json
{"name":"moments","arguments":{}}
```

Relevant lines from the result (indices are word indices):

```
0.0–3.8   (silence, cursor wiggle)
3.8–6.1   s0 [w0–w9]   "Okay so um let me just share my screen here."
7.9–11.2  s1 [w10–w19] "Today I'll show you how to create an API key."
11.2      click #0 (412, 88) "Settings" — Dashboard
13.9–16.0 s2 [w20–w27] "First you go to settings, uh, then API keys."
16.4      click #1 (180, 342) "API keys"
19.0–41.5 typing "production-deploy" + 18 s of the page spinner
...
128.2–129.0 s14 [w188–w191] "And that's it."
129.0–134.0 (silence, cursor moves to stop recording)
```

Brief (3 lines): target ~75 s. Keep: s1 onward, both clicks, the key appearing. Go: s0 (setup talk), the dead
start, fillers, the spinner wait, the tail.

## 2. Spine, one step at a time

```json
{"name":"cut_words","arguments":{"from_word_index":0,"to_word_index":9}}
{"name":"trim_start_to_first_word","arguments":{"lead_s":0.1}}
{"name":"remove_fillers","arguments":{}}
{"name":"tighten_pauses","arguments":{"max_gap_s":0.5,"keep_s":0.35}}
```

The spinner is silent screen time, not a pause between words, so cut it with a raw command. Re-read `moments` first:
the cuts above moved it.

```json
{"name":"moments","arguments":{"from_s":10,"to_s":40}}
{"name":"batch","arguments":{"commands":[{"op":"delete_range","tl_start_ns":21400000000,"tl_end_ns":36800000000}]}}
```

## 3. Check and verify

```json
{"name":"check","arguments":{}}
```

`warning tail at 77.9 s: 4.6 s after last word` → fix: the tail is the stop-recording motion.

```json
{"name":"batch","arguments":{"commands":[{"op":"delete_range","tl_start_ns":78300000000,"tl_end_ns":82500000000}]}}
{"name":"check","arguments":{}}
{"name":"capture","arguments":{"times":[0,10.9,11.3,21.2,21.6,78.2]}}
```

Look at the sheet: the first frame shows the dashboard, the cut at 21.4 s lands on the loaded key list, the last
frame is the finished key, not the Stop button.

## 4. Reply

"Trimmed 2:14 to 1:18: removed the intro chatter, fillers, long pauses and the 15 s spinner. Ends on the new key."
