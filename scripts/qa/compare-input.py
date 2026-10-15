#!/usr/bin/env python3
"""Compare scripted input (probe.log 'drive-input-selftest event ...' lines of the LAST run) with
events.jsonl of its package. usage: compare-input.py Recording.yapcam [probe.log]
Time error = (logged hostNs - segment host origin) - events.jsonl t, matched by type and nearest position."""
import json, re, sys, os
pkg = sys.argv[1]
log = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~/Library/Logs/Yapcam/probe.log")
seg = os.path.join(pkg, "recording/seg-000")
origin = int(json.load(open(os.path.join(seg, "host-start.json")))["host_start_ns"] if isinstance(json.load(open(os.path.join(seg, "host-start.json"))), dict) else open(os.path.join(seg, "host-start.json")).read().strip())
lines = open(log).read().splitlines()
start = max(i for i, l in enumerate(lines) if "drive-input-selftest start" in l)
sent = []
for l in lines[start:]:
    m = re.search(r"event (move|click) x=([-\d.]+) y=([-\d.]+) hostNs=(\d+)", l)
    if m: sent.append((m.group(1), float(m.group(2)), float(m.group(3)), int(m.group(4)) - origin))
ev = [json.loads(l) for l in open(os.path.join(seg, "events.jsonl"))]
downs = [e for e in ev if e["type"] == "down"]; moves = [e for e in ev if e["type"] == "move"]
terr, perr, missing = [], [], 0
for kind, x, y, t in sent:
    pool = downs if kind == "click" else moves
    cand = [e for e in pool if abs(e["x"] - x) < 3 and abs(e["y"] - y) < 3 and abs(e["t"] - t) < 400e6]
    if not cand: missing += 1; continue
    e = min(cand, key=lambda e: abs(e["t"] - t))
    terr.append((e["t"] - t) / 1e6); perr.append(max(abs(e["x"] - x), abs(e["y"] - y)))
print(f"scripted={len(sent)} (moves={sum(1 for s in sent if s[0]=='move')} clicks={sum(1 for s in sent if s[0]=='click')}) matched={len(terr)} missing={missing}")
if terr:
    print("time error ms (events.t - sent): min %.2f max %.2f mean %.2f" % (min(terr), max(terr), sum(terr)/len(terr)))
    print("position error pts: max %.2f" % max(perr))
print("clicks in events.jsonl: down=%d up=%d" % (len(downs), sum(1 for e in ev if e['type'] == 'up')))
