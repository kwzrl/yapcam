#!/bin/zsh
# Signs build/Yapcam.app (or the given bundle) inside out, without --deep: Sparkle's helpers first, then the
# framework, then the app with its entitlements. Usage: scripts/sign-app.sh <app> <identity> [entitlements] [--timestamp]
set -euo pipefail
APP="$1"; ID="$2"; ENT="${3:-}"; TS="${4:---timestamp=none}"
# Hardened runtime only with a Developer ID: its library validation needs a Team ID, which the local
# self-signed dev identity (and ad-hoc "-") does not have, so Sparkle would fail to load in dev builds.
RT=(); [[ "$ID" == "Developer ID Application:"* ]] && RT=(-o runtime)
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -d "$SP" ]]; then
  # Order from Sparkle's documentation for non-sandboxed apps; the Downloader keeps its own entitlements.
  codesign -f -s "$ID" "${RT[@]}" "$TS" "$SP/XPCServices/Installer.xpc"
  codesign -f -s "$ID" "${RT[@]}" "$TS" --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
  codesign -f -s "$ID" "${RT[@]}" "$TS" "$SP/Autoupdate"
  codesign -f -s "$ID" "${RT[@]}" "$TS" "$SP/Updater.app"
  codesign -f -s "$ID" "${RT[@]}" "$TS" "$APP/Contents/Frameworks/Sparkle.framework"
fi
if [[ -n "$ENT" ]]; then
  codesign -f -s "$ID" "${RT[@]}" "$TS" --entitlements "$ENT" "$APP"
else
  codesign -f -s "$ID" "${RT[@]}" "$TS" "$APP"
fi
codesign --verify --strict --deep "$APP"
