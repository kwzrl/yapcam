#!/usr/bin/env python3
"""A/V sync analysis for a recording made while scripts/qa/sync-marker.swift ran.
usage: analyze-sync.py Name.yapcam [flash_x flash_y flash_w flash_h]   (top-left screen px)
Prints per-beep offset (audio onset minus flash onset, ms; positive = audio late), plus the
first/middle/last offsets and drift. Uses ffmpeg/ffprobe; python3 -I compatible, no numpy."""
import json, subprocess, sys, os, struct
pkg = sys.argv[1]
x, y, w, h = (list(map(int, sys.argv[2:6])) if len(sys.argv) >= 6 else (40, 810, 200, 200))
rec = json.load(open(f"{pkg}/recording/session.json"))
def detect(seg):
    offs = seg.get("track_start_ns", {})
    def off(name): return offs.get(name, 0) / 1e9
    base = seg.get("src_start_ns", 0) / 1e9
    screen = f"{pkg}/recording/{seg['files']['screen']}"
    audio = f"{pkg}/recording/{seg['files']['system_audio']}"
    out = subprocess.run(["ffprobe", "-v", "error", "-f", "lavfi", "-i",
        f"movie={screen},crop={w}:{h}:{x}:{y},signalstats", "-show_entries", "frame=pts_time:frame_tags=lavfi.signalstats.YAVG",
        "-of", "csv=p=0"], capture_output=True, text=True).stdout
    vt = []
    for line in out.splitlines():
        p = line.split(",")
        try: vt.append((float(p[0]), float(p[1])))
        except Exception: pass
    flash = []; prev = 0
    for t, v in vt:
        if v > 128 and prev <= 128: flash.append(base + t + off("screen"))
        prev = v
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", audio, "-ac", "1", "-ar", "48000", "-f", "s16le", "-"], capture_output=True).stdout
    n = len(raw) // 2
    smp = struct.unpack(f"<{n}h", raw[: n * 2])
    win = 48; beeps = []; quiet = True
    for i in range(0, n - win, win):
        e = sum(abs(v) for v in smp[i:i + win]) / win
        if e > 3000 and quiet: beeps.append(base + i / 48000 + off("system_audio")); quiet = False
        elif e < 800: quiet = True
    return flash, beeps
flash = []; beeps = []
for seg in rec["segments"]:
    f_, b_ = detect(seg); flash += f_; beeps += b_
# pair each flash with the nearest beep within 300 ms (flashes during a pause exist in neither stream)
res = []
for t in flash:
    near = min(beeps, key=lambda b: abs(b - t), default=None)
    if near is not None and abs(near - t) < 0.3: res.append((near - t) * 1000)
m = len(res)
m = min(len(flash), len(beeps))
print(f"segments={len(rec['segments'])} flashes={len(flash)} beeps={len(beeps)} paired={m}")
if m:
    print("offsets_ms first/mid/last: %.1f / %.1f / %.1f" % (res[0], res[m // 2], res[-1]))
    print("min/max/mean_ms: %.1f / %.1f / %.1f ; drift last-first %.1f ms" % (min(res), max(res), sum(res) / m, res[-1] - res[0]))
