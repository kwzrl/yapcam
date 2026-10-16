#!/bin/zsh
# Build/run a CLI measurement tool, not Yapcam; no app launch, playback or TCC prompt.
set -euo pipefail
cd "${0:A:h}/../../.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CARGO_BUILD_JOBS=4
capture_speech_tools=
capture_speech_cleanup() {
  if [[ -n "$capture_speech_tools" ]]; then
    print -r -- "Removing capture tool directory: $capture_speech_tools"
    rm -r -- "$capture_speech_tools"
  fi
}
trap capture_speech_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
capture_speech_tools="$(mktemp -d "${TMPDIR%/}/yapcam-capture-round3-tools.XXXXXXXX")"
if [[ "${YAPCAM_SPEECH_SKIP_BUILD:-0}" != 1 ]]; then
  cargo build --release --manifest-path core/Cargo.toml -j 4
  swift build --disable-sandbox -j 4
fi
capture_speech_bin="${PWD}/.build/debug"
capture_speech_objects=("$capture_speech_bin"/{YapcamCapture,YapcamCore,YapcamRender,YapcamEditor}.build/*.swift.o)
swiftc -parse-as-library -swift-version 6 -DROUND3_SPEECH_HARNESS \
  -module-cache-path "$capture_speech_tools/module-cache" -I "$capture_speech_bin/Modules" -I Sources/CYapcamCore \
  -L core/target/release -lyapcam_core \
  Tests/YapcamCaptureTests/Round3SpeechHarness.swift \
  "${capture_speech_objects[@]}" -o "$capture_speech_tools/speech-harness"
if [[ "${1:-}" == --prepare-app ]]; then
  python3 - "$capture_speech_tools/speech-harness" "${2:?Provide a new app destination outside the repository}" <<'PYAPP'
import os, plistlib, shutil, sys
from pathlib import Path
source, app = Path(sys.argv[1]), Path(sys.argv[2]).expanduser().resolve()
assert app.suffix == '.app' and not app.exists()
assert not app.is_relative_to(Path.cwd())
(app/'Contents/MacOS').mkdir(parents=True)
shutil.copy2(source, app/'Contents/MacOS/SpeechHarness')
with (app/'Contents/Info.plist').open('wb') as f:
 plistlib.dump(dict(CFBundleIdentifier='mov.yapcam.Yapcam', CFBundleExecutable='SpeechHarness',
  CFBundleName='Yapcam Speech Verification', CFBundlePackageType='APPL', CFBundleVersion='1',
  LSUIElement=True, NSSpeechRecognitionUsageDescription='Transcribe synthetic speech locally for verification.'), f)
PYAPP
  codesign --force --sign 'Yapcam Dev Signing' "$2"
  codesign --verify --deep --strict "$2"
  print -r -- "Prepared signed debug speech harness (not launched): $2"
else
  "$capture_speech_tools/speech-harness" "${1:---probe}"
fi
