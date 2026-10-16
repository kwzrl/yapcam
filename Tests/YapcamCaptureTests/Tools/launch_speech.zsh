#!/bin/zsh
# Host only. LaunchServices preserves the signed app identity used for Speech TCC.
set -euo pipefail
capture_speech_app="${1:?Provide the signed speech harness .app}"
capture_speech_fixtures="${2:?Provide the generated speech fixture root}"
capture_speech_permission="${3:-}"
[[ -d "$capture_speech_app" && -f "$capture_speech_fixtures/en-US/ground-truth.json" && -f "$capture_speech_fixtures/de-DE/ground-truth.json" ]]
[[ -z "$capture_speech_permission" || "$capture_speech_permission" == --request-speech ]]
capture_speech_lock="$HOME/Movies/Yapcam/QA/.app-lock"
capture_speech_token="capture round3 speech $$"
capture_speech_completed=0
capture_speech_lock_owned=0
capture_speech_release() {
  if (( capture_speech_lock_owned )); then
    if (( capture_speech_completed )); then
      python3 - "$capture_speech_lock" "$capture_speech_token" <<'PYLOCK'
from pathlib import Path
import sys
p=Path(sys.argv[1])
if p.exists() and p.read_text().strip()==sys.argv[2]: p.unlink()
PYLOCK
    else
      print -u2 -- "Launch interrupted; keep .app-lock until this speech app has exited."
    fi
  fi
}
trap capture_speech_release EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
# O_EXCL is atomic: never replace QA's or another team's ownership file.
python3 - "$capture_speech_lock" "$capture_speech_token" <<'PYLOCK'
import os,sys
fd=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as f: f.write(sys.argv[2]+'\n')
PYLOCK
capture_speech_lock_owned=1
for capture_process in Yapcam SpeechHarness; do
  capture_process_result=0
  pgrep -x "$capture_process" >/dev/null || capture_process_result=$?
  if (( capture_process_result != 1 )); then
    print -u2 -- 'Another app is running, or the process list is unavailable. No launch.'
    capture_speech_completed=1
    exit 1
  fi
done
capture_speech_args=("$capture_speech_fixtures")
[[ -z "$capture_speech_permission" ]] || capture_speech_args+=("$capture_speech_permission")
open -n -W "$capture_speech_app" --stdout "$capture_speech_fixtures/harness.stdout.log" \
  --stderr "$capture_speech_fixtures/harness.stderr.log" --args "${capture_speech_args[@]}"
capture_speech_completed=1
