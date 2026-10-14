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
swift build -c "$CONFIG" --product Yapcam
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Yapcam"

APP="$ROOT/build/Yapcam.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Yapcam"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
  echo "warning: signing identity '$IDENTITY' not found; ad-hoc signing (permissions reset on every build)" >&2
  codesign --force --sign - "$APP"
fi
codesign --verify "$APP"
echo "$APP"
