#!/bin/sh
# usage: verify-package.sh Name.yapcam  — checks structure and media decodability
p=$1; set -e
[ -f "$p/recording/session.json" ] || { echo "missing session.json"; exit 1; }
[ -f "$p/project.json" ] || echo "note: no project.json yet (fresh recording / fixture)"
python3 -I - "$p" <<'PY'
import json,sys,os
p=sys.argv[1]; s=json.load(open(p+"/recording/session.json"))
assert s["schema_version"]>=1; assert s["segments"], "no segments"
prev=0
for seg in s["segments"]:
    assert seg["src_start_ns"]==prev, "segment gap"
    prev=seg["src_start_ns"]+seg["duration_ns"]
    for k,f in seg["files"].items():
        assert os.path.exists(p+"/recording/"+f), "missing "+f
print("session ok, duration_ns",prev)
PY
for f in "$p"/recording/seg-*/screen.mov; do ffmpeg -v error -i "$f" -f null - ; done
echo "package ok"
