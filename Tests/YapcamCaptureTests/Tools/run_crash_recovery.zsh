#!/bin/zsh
# Native encoder/decoder test; injected screen/camera pixels, no app or TCC access.
set -euo pipefail
cd "${0:A:h}/../../.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
capture_crash_root=
capture_crash_cleanup() {
  if [[ -n "$capture_crash_root" ]]; then
    print -r -- "Removing capture-owned crash fixture/build directory: $capture_crash_root"
    ls -ld -- "$capture_crash_root"
    rm -r -- "$capture_crash_root"
  fi
}
trap capture_crash_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
capture_crash_root=$(mktemp -d "${TMPDIR%/}/yapcam-capture-r5-crash.XXXXXXXX")
swiftc -swift-version 6 -j 4 -g -Onone -target arm64-apple-macos15.0 \
  -module-cache-path "$capture_crash_root/module-cache" -enable-testing \
  -emit-library -static -emit-module -module-name YapcamCapture \
  -emit-module-path "$capture_crash_root/YapcamCapture.swiftmodule" \
  Sources/YapcamCapture/*.swift -o "$capture_crash_root/libYapcamCapture.a"
swiftc -parse-as-library -swift-version 6 -g -Onone -target arm64-apple-macos15.0 \
  -DROUND5_CAPTURE_CRASH_HARNESS -module-cache-path "$capture_crash_root/module-cache" \
  -I "$capture_crash_root" -L "$capture_crash_root" -lYapcamCapture \
  Tests/YapcamCaptureTests/Round5CrashHarness.swift -o "$capture_crash_root/capture-crash-fixture"
codesign --force --sign 'Yapcam Dev Signing' --identifier mov.yapcam.Yapcam --timestamp=none "$capture_crash_root/capture-crash-fixture"
if [[ "${1:-}" == --software-fixture ]]; then
  python3 -B Tests/YapcamCaptureTests/Tools/crash_recovery_fixture.py "$capture_crash_root/capture-crash-fixture" "$capture_crash_root"
else
  [[ $# == 0 ]]
  "$capture_crash_root/capture-crash-fixture" --verify "$capture_crash_root"
fi
