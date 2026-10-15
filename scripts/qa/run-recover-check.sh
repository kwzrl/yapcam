#!/bin/zsh
# usage: run-recover-check.sh /path/to/interrupted.yapcam
# Package.swift is Lead-owned and the E2E target has no YapcamCapture dependency, so this runs the
# test from a scratch copy with an extra target. The scratch dir is removed on exit.
set -euo pipefail
ROOT="${0:A:h:h:h}"; S="$(mktemp -d)"; trap 'rm -rf "$S"' EXIT
rsync -a --exclude build --exclude .build --exclude core/target --exclude .git "$ROOT/" "$S/"
ln -sfn "$ROOT/core/target" "$S/core/target"
mkdir -p "$S/Tests/RecoverCheck"; cp "$ROOT/scripts/qa/recover-check/RecoverCheckTests.swift" "$S/Tests/RecoverCheck/"
python3 -I - "$S/Package.swift" <<'PY'
import sys
f=sys.argv[1]; p=open(f).read()
p=p.replace('        .testTarget(name: "YapcamEditorTests"','        .testTarget(name: "RecoverCheck", dependencies: ["YapcamCapture", "YapcamCore"], path: "Tests/RecoverCheck"),\n        .testTarget(name: "YapcamEditorTests"')
open(f,'w').write(p)
PY
cd "$S" && YAPCAM_INTERRUPTED_PACKAGE="$1" swift test --disable-sandbox -j 4 --filter RecoverCheck
