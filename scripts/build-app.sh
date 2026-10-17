#!/bin/zsh
# Builds build/Yapcam.app and signs it with a stable local identity so macOS
# privacy permissions survive rebuilds. Usage: scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="${0:A:h:h}"
IDENTITY="${YAPCAM_SIGN_IDENTITY:-Yapcam Dev Signing}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$ROOT"
"$ROOT/scripts/build-core.sh"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/Yapcam"
# SwiftPM does not track the external Rust archive as a link input.
RUST_LIB="$ROOT/core/target/release/libyapcam_core.a"
# Tests link the same archive, even when the app has not been built yet.
for LINKED_PRODUCT in "$BIN" "$BIN_DIR/YapcamPackageTests.xctest/Contents/MacOS/YapcamPackageTests"; do
  if [[ -f "$LINKED_PRODUCT" && "$RUST_LIB" -nt "$LINKED_PRODUCT" ]]; then
    rm "$LINKED_PRODUCT"
  fi
done
swift build -j 2 -c "$CONFIG" --product Yapcam

APP="$ROOT/build/Yapcam.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Yapcam"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
xcrun actool "$ROOT/Resources/Accent.xcassets" --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 15.0
# Third-party notices travel with the app (Help menu and About open this file). Plain text so any viewer shows it.
cp "$ROOT/docs/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
test -s "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt" || { echo "build-app: THIRD_PARTY_NOTICES missing from bundle" >&2; exit 1; }

# Optional dedicated signing keychain; unlock it if a password file exists.
KEYCHAIN="${YAPCAM_SIGN_KEYCHAIN:-$HOME/Library/Keychains/yapcam-signing.keychain-db}"
PASS_FILE="${YAPCAM_SIGN_KEYCHAIN_PASS_FILE:-$HOME/.config/yapcam/signing-keychain-pass}"
if [[ -f "$KEYCHAIN" && -f "$PASS_FILE" ]]; then
  security unlock-keychain -p "$(<"$PASS_FILE")" "$KEYCHAIN" 2>/dev/null || true
fi

if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
  echo "warning: signing identity '$IDENTITY' not found; ad-hoc signing (permissions reset on every build)" >&2
  codesign --force --sign - "$APP"
fi
codesign --verify "$APP"
echo "$APP"
