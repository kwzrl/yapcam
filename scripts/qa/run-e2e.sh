#!/bin/zsh
# Runs Tests/E2E against the current checkout without touching Package.swift (Lead-owned):
# copies the repo to a scratch dir, adds an "E2E" test target there, runs it.
set -euo pipefail
ROOT="${0:A:h:h:h}"; S="$(mktemp -d)/e2e"; mkdir -p "$S"
rsync -a --exclude build --exclude .build --exclude core/target "$ROOT/" "$S/"
ln -sfn "$ROOT/core/target" "$S/core/target"
python3 -I - "$S/Package.swift" <<'PY'
import sys
f=sys.argv[1]; p=open(f).read()
p=p.replace('        .testTarget(name: "YapcamEditorTests"','        .testTarget(name: "E2E", dependencies: ["YapcamRender", "YapcamCore"], path: "Tests/E2E"),\n        .testTarget(name: "YapcamEditorTests"')
open(f,'w').write(p)
PY
cd "$S" && swift test --disable-sandbox -j 4 --filter E2E
