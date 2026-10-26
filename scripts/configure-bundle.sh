#!/bin/zsh
# Change only development metadata; release plists remain byte-for-byte unchanged.
set -euo pipefail
CONFIG="${1:?debug or release required}"
PLIST="${2:?Info.plist required}"
case "$CONFIG" in
  release) exit 0 ;;
  debug) ;;
  *) echo "Unknown build configuration: $CONFIG" >&2; exit 2 ;;
esac
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier mov.yapcam.Yapcam.dev' "$PLIST"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Yapcam Dev' "$PLIST"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Yapcam Dev' "$PLIST"
/usr/libexec/PlistBuddy -c 'Set :SUEnableAutomaticChecks false' "$PLIST"
/usr/libexec/PlistBuddy -c 'Add :YapcamDevelopmentBuild bool true' "$PLIST"
