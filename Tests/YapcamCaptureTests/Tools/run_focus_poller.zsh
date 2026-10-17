#!/bin/zsh
# Five-second metadata-only probe; does not record, activate apps, or request TCC.
set -euo pipefail
cd "${0:A:h}/../../.."
swift build -j 2 --target YapcamCapture
focus_bin_dir=$(swift build --show-bin-path)
focus_harness_dir=$(mktemp -d "${TMPDIR:-/tmp}/yapcam-focus-poller.XXXXXXXX")
trap 'rm -r -- "$focus_harness_dir"' EXIT
swiftc -parse-as-library -swift-version 6 -j 2 -target arm64-apple-macos15.0 \
  -DFOCUS_POLLER_HARNESS -I "$focus_bin_dir/Modules" \
  "$focus_bin_dir"/YapcamCapture.build/*.o \
  Tests/YapcamCaptureTests/FocusPollerHarness.swift -o "$focus_harness_dir/focus-poller"
"$focus_harness_dir/focus-poller"
