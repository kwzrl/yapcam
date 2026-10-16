#!/bin/zsh
# Independent debug build: no SwiftPM lock and no native screen/audio device work.
set -euo pipefail
cd "${0:A:h}/../../.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
capture_policy_root=
capture_policy_cleanup() {
  if [[ -n "$capture_policy_root" ]]; then
    print -r -- "Removing capture policy test directory: $capture_policy_root"
    rm -r -- "$capture_policy_root"
  fi
}
trap capture_policy_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
capture_policy_root="$(mktemp -d "${TMPDIR%/}/yapcam-capture-round3-policy.XXXXXXXX")"
capture_policy_platform="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer"
swiftc -swift-version 6 -j 4 -g -Onone -target arm64-apple-macos15.0 \
  -module-cache-path "$capture_policy_root/module-cache" -enable-testing \
  -emit-library -static -emit-module -module-name YapcamCapture \
  -emit-module-path "$capture_policy_root/YapcamCapture.swiftmodule" \
  Sources/YapcamCapture/*.swift -o "$capture_policy_root/libYapcamCapture.a"
cat > "$capture_policy_root/Runner.swift" <<'SWIFT'
import Testing
@main struct Runner {
    static func main() async { await Testing.__swiftPMEntryPoint() as Never }
}
SWIFT
swiftc -parse-as-library -swift-version 6 -g -Onone -target arm64-apple-macos15.0 \
  -module-cache-path "$capture_policy_root/module-cache" \
  -plugin-path "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing" \
  -F "$capture_policy_platform/Library/Frameworks" \
  -I "$capture_policy_root" -L "$capture_policy_root" -lYapcamCapture \
  -Xlinker -rpath -Xlinker "$capture_policy_platform/Library/Frameworks" \
  Tests/YapcamCaptureTests/OnDeviceSpeechPolicyTests.swift \
  Tests/YapcamCaptureTests/TranscriptionTests.swift \
  "$capture_policy_root/Runner.swift" -o "$capture_policy_root/tests"
"$capture_policy_root/tests"
