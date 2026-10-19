#!/bin/zsh
# Writes a one-item Sparkle appcast for a stapled release DMG, signed with the EdDSA key in the login keychain
# (account "yapcam"). Usage: make-appcast.sh <dmg> <short version> <build> <enclosure url> <out.xml> [release notes url]
set -euo pipefail
DMG="$1"; SHORT="$2"; BUILD="$3"; URL="$4"; OUT="$5"; NOTES="${6:-https://github.com/kwzrl/yapcam/releases/tag/v$SHORT}"
ROOT="${0:A:h:h:h}"
SIG="$("$ROOT/Vendor/Sparkle/bin/sign_update" --account yapcam "$DMG")"   # sparkle:edSignature="…" length="…"
[[ "$SIG" == *edSignature=* && "$SIG" == *length=* ]] || { echo "make-appcast: signing failed" >&2; exit 1; }
DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
cat > "$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Yapcam</title>
    <link>https://yapcam.app/appcast.xml</link>
    <language>en</language>
    <item>
      <title>Yapcam $SHORT</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$SHORT</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$NOTES</sparkle:releaseNotesLink>
      <enclosure url="$URL" $SIG type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$OUT"
echo "$OUT"
