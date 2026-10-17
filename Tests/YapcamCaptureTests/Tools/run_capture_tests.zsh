#!/bin/zsh
# Fresh capture-only debug module/test binary; independent of SwiftPM's shared lock.
set -euo pipefail
cd "${0:A:h}/../../.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
capture_tests_root=
capture_tests_cleanup() {
  if [[ -n "$capture_tests_root" ]]; then
    print -r -- "Removing capture-owned test build directory: $capture_tests_root"
    ls -ld -- "$capture_tests_root"
    rm -r -- "$capture_tests_root"
  fi
}
trap capture_tests_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
capture_tests_root=$(mktemp -d "${TMPDIR%/}/yapcam-capture-r5-tests.XXXXXXXX")
capture_tests_platform="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer"
swiftc -swift-version 6 -j 4 -g -Onone -target arm64-apple-macos15.0 \
  -module-cache-path "$capture_tests_root/module-cache" -enable-testing \
  -emit-library -static -emit-module -module-name YapcamCapture \
  -emit-module-path "$capture_tests_root/YapcamCapture.swiftmodule" \
  Sources/YapcamCapture/*.swift -o "$capture_tests_root/libYapcamCapture.a"
cat > "$capture_tests_root/Runner.swift" <<'SWIFT'
import Testing
@main struct Runner {
    static func main() async { await Testing.__swiftPMEntryPoint() as Never }
}
SWIFT
swiftc -parse-as-library -swift-version 6 -j 4 -g -Onone -target arm64-apple-macos15.0 \
  -module-cache-path "$capture_tests_root/module-cache" \
  -plugin-path "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing" \
  -F "$capture_tests_platform/Library/Frameworks" \
  -I "$capture_tests_root" -L "$capture_tests_root" -lYapcamCapture \
  -Xlinker -rpath -Xlinker "$capture_tests_platform/Library/Frameworks" \
  Tests/YapcamCaptureTests/*.swift "$capture_tests_root/Runner.swift" -o "$capture_tests_root/tests"
env TMPDIR="$capture_tests_root/" "$capture_tests_root/tests" "$@"
