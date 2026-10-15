#!/usr/bin/env python3
"""A/V sync analysis for a recording made while scripts/qa/sync-marker.swift ran.
usage: analyze-sync.py Name.yapcam [flash_x flash_y flash_w flash_h]   (top-left screen px)
Prints per-beep offset (audio onset minus flash onset, ms; positive = audio late), plus the
first/middle/last offsets and drift. Uses ffmpeg/ffprobe; python3 -I compatible, no numpy."""
import json, subprocess, sys, os, struct
pkg = sys.argv[1]
x, y, w, h = (list(map(int, sys.argv[2:6])) if len(sys.argv) >= 6 else (40, 810, 200, 200))
rec = json.load(open(f"{pkg}/recording/session.json"))
seg = rec["segments"][0]
offs = seg.get("track_start_ns", {})
def off(name): return offs.get(name, 0) / 1e9
screen = f"{pkg}/recording/{seg['files']['screen']}"
audio = f"{pkg}/recording/{seg['files']['system_audio']}"
# video: mean luma of the flash square per frame with presentation time
out = subprocess.run(["ffprobe", "-v", "error", "-f", "lavfi", "-i",
    f"movie={screen},crop={w}:{h}:{x}:{y},signalstats", "-show_entries", "frame=pts_time:frame_tags=lavfi.signalstats.YAVG",
    "-of", "csv=p=0"], capture_output=True, text=True).stdout
vt = []
for line in out.splitlines():
    p = line.split(",")
    try: vt.append((float(p[0]), float(p[1])))
    except Exception: pass
flash = []
prev = 0
for t, v in vt:
    if v > 128 and prev <= 128: flash.append(t + off("screen"))
    prev = v
# audio: decode to mono 48k s16 and find onsets of the 1 kHz burst
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", audio, "-ac", "1", "-ar", "48000", "-f", "s16le", "-"], capture_output=True).stdout
n = len(raw) // 2
s = struct.unpack(f"<{n}h", raw[: n * 2])
win = 48  # 1 ms
beeps = []; quiet = True
for i in range(0, n - win, win):
    e = sum(abs(v) for v in s[i:i + win]) / win
    if e > 3000 and quiet: beeps.append(i / 48000 + off("system_audio")); quiet = False
    elif e < 800: quiet = True
m = min(len(flash), len(beeps))
res = [(beeps[i] - flash[i]) * 1000 for i in range(m)]
print(f"flashes={len(flash)} beeps={len(beeps)} paired={m}")
if m:
    print("offsets_ms first/mid/last: %.1f / %.1f / %.1f" % (res[0], res[m // 2], res[-1]))
    print("min/max/mean_ms: %.1f / %.1f / %.1f ; drift last-first %.1f ms" % (min(res), max(res), sum(res) / m, res[-1] - res[0]))
