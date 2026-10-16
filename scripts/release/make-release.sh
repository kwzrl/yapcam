#!/bin/bash
# Local packaging is offline. Only --notarize opts into Apple network services.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
IDENTITY=""
PROFILE=""
usage() {
    echo 'Usage: scripts/release/make-release.sh [--identity "<codesign identity>"] [--notarize <keychain-profile>]'
}
die() { echo "Release error: $*" >&2; exit 1; }
while (( $# )); do
    case "$1" in
        --identity|--notarize)
            (( $# >= 2 )) && [[ -n "$2" && "$2" != --* ]] || { usage >&2; exit 2; }
            if [[ "$1" == --identity ]]; then IDENTITY="$2"; else PROFILE="$2"; fi
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || die 'Requires an Apple Silicon Mac.'
cd "$ROOT"
VERSION="$(cat VERSION)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'VERSION must contain a numeric marketing version.'
BUILD="$(git rev-list --count HEAD)"
REVISION="$(git rev-parse HEAD)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CARGO_BUILD_JOBS=4 CARGO_NET_OFFLINE=true

# Include untrusted self-signed identities: find-identity -v omits our local cert.
IDENTITIES="$(security find-identity -p codesigning)"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)"
    IDENTITY="${IDENTITY:-Yapcam Dev Signing}"
fi
RECORD="$(printf '%s\n' "$IDENTITIES" | awk -v requested="$IDENTITY" '
    $2 ~ /^[0-9A-Fa-f]+$/ && length($2) == 40 {
        name=$0; sub(/^[^"]*"/, "", name); sub(/".*$/, "", name)
        if (name == requested || toupper($2) == toupper(requested)) { print $2; print name; exit }
    }')"
[[ -n "$RECORD" ]] || die "Signing identity not found: $IDENTITY (no ad-hoc fallback)."
SIGNING_HASH="${RECORD%%$'\n'*}"
SIGNING_NAME="${RECORD#*$'\n'}"
TIMESTAMP=--timestamp=none
if [[ -n "$PROFILE" ]]; then
    [[ "$SIGNING_NAME" == 'Developer ID Application: '* ]] || die '--notarize requires a Developer ID Application identity.'
    TIMESTAMP=--timestamp
else
    echo 'OFFLINE LOCAL PACKAGE: NOT DISTRIBUTABLE (no secure timestamp or notarization).'
    echo 'Timestamping contacts Apple; it is enabled only together with --notarize.'
fi
echo "Signing identity: $SIGNING_NAME"
echo "Release: $VERSION ($BUILD), commit $REVISION"

mkdir -p "$ROOT/build"
LOCK="$ROOT/build/.yapcam-release.lock"
mkdir "$LOCK" 2>/dev/null || die 'Another release owns build/.yapcam-release.lock; do not remove a live lock.'
RUN=""
cleanup() {
    if [[ -n "$RUN" && -d "$RUN" ]]; then
        echo "Release temp cleanup: $RUN"
        rm -rf -- "$RUN"
    fi
    rmdir "$LOCK"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
RELEASE_TMP="${TMPDIR:-/private/tmp}"
RUN="$(mktemp -d "${RELEASE_TMP%/}/yapcam-core-release.XXXXXXXX")"
OUT="$ROOT/build/release"
MARKER='Yapcam release script output v1'
if [[ -e "$OUT" ]]; then
    [[ -d "$OUT" && ! -L "$OUT" && -f "$OUT/.yapcam-release-output" ]] || die 'Refusing to replace an unowned build/release directory.'
    [[ "$(cat "$OUT/.yapcam-release-output")" == "$MARKER" ]] || die 'Unrecognized release output marker.'
    echo "Replacing previous owned release output (listed before removal): $OUT"
    find "$OUT" -mindepth 1 -maxdepth 1 -print
    rm -rf -- "$OUT"
fi
mkdir "$OUT"
printf '%s\n' "$MARKER" > "$OUT/.yapcam-release-output"

# Give the unchanged canonical builder a fresh Swift scratch directory per build.
# Rust is cleaned separately because Package.swift links core/target/release.
mkdir "$RUN/bin"
cat > "$RUN/bin/swift" <<'SWIFT'
#!/bin/bash
set -euo pipefail
exec /usr/bin/swift "$@" --scratch-path "$YAPCAM_RELEASE_SWIFT_SCRATCH" --disable-sandbox --skip-update -j 4
SWIFT
chmod +x "$RUN/bin/swift"
export PATH="$RUN/bin:$PATH"
build_release() {
    export YAPCAM_RELEASE_SWIFT_SCRATCH="$RUN/swift-$1"
    cargo clean --release --manifest-path "$ROOT/core/Cargo.toml"
    "$ROOT/scripts/build-app.sh" release
}
build_release first
ditto "$ROOT/build/Yapcam.app" "$OUT/Yapcam.app"
cp "$OUT/Yapcam.app/Contents/MacOS/Yapcam" "$RUN/first-unsigned"
codesign --remove-signature "$RUN/first-unsigned"
build_release second
cp "$ROOT/build/Yapcam.app/Contents/MacOS/Yapcam" "$RUN/second-unsigned"
codesign --remove-signature "$RUN/second-unsigned"
{
    echo "commit=$REVISION"
    echo 'configuration=release; two clean Swift/Rust builds; signatures removed from main Mach-O copies'
    shasum -a 256 "$RUN/first-unsigned" "$RUN/second-unsigned" | sed "s|$RUN/||g"
    if cmp -s "$RUN/first-unsigned" "$RUN/second-unsigned"; then
        echo 'unsigned_macho_identical=yes'
    else
        echo 'unsigned_macho_identical=no'
        echo 'Inspect UUIDs and build-path evidence below; this is not a claim of bit reproducibility.'
        xcrun dwarfdump --uuid "$RUN/first-unsigned" "$RUN/second-unsigned" | sed "s|$RUN/||g"
        for pass in first second; do
            echo "$pass N_OSO debug-map evidence (object timestamps and scratch references):"
            nm -ap "$RUN/$pass-unsigned" | awk -v root="$RUN" '
                / OSO / {
                    n++; if (index($0, root)) scratch++
                    if (n<=3) print "object_mtime_hex=" $1
                }
                END { print "object_entries=" n+0 " scratch_entries=" scratch+0 }'
        done
        echo 'N_OSO debug-map timestamps and scratch paths differ between clean builds; linker UUIDs differ too.'
        echo 'These link/debug metadata differences explain nonidentical unsigned executables; no bit-reproducibility claim.'
    fi
} | tee "$OUT/reproducibility.txt"

APP="$OUT/Yapcam.app"
PLIST="$APP/Contents/Info.plist"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/docs/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
plutil -lint "$PLIST" "$ROOT/scripts/release/Yapcam.entitlements"

# Sign leaf Mach-Os, then containing bundles in depth order, then the main app.
# No --deep signing. Helpers/libraries get no new resource-access entitlements.
while IFS= read -r -d '' path; do
    [[ "$path" != "$APP/Contents/MacOS/Yapcam" ]] || continue
    if [[ "$(/usr/bin/file -b "$path")" == *Mach-O* ]]; then
        codesign --force --options runtime "$TIMESTAMP" --sign "$SIGNING_HASH" "$path"
    fi
done < <(find "$APP/Contents" -type f -print0)
while IFS= read -r -d '' path; do
    codesign --force --options runtime "$TIMESTAMP" --sign "$SIGNING_HASH" "$path"
done < <(find "$APP/Contents" -depth -type d \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' -o -name '*.appex' -o -name '*.bundle' \) -print0)
codesign --force --options runtime "$TIMESTAMP" --entitlements "$ROOT/scripts/release/Yapcam.entitlements" --sign "$SIGNING_HASH" "$APP"
codesign --verify --strict --verbose=2 "$APP"
DETAILS="$(codesign -dvv "$APP" 2>&1)"
printf '%s\n' "$DETAILS"
[[ "$DETAILS" == *'runtime)'* ]] || die 'Hardened runtime flag missing.'
if [[ "$SIGNING_NAME" == 'Developer ID Application: '* ]]; then
    [[ "$DETAILS" == *TeamIdentifier=* && "$DETAILS" != *'TeamIdentifier=not set'* ]] || die 'Developer ID team identifier missing.'
fi
if [[ -n "$PROFILE" ]]; then
    [[ "$DETAILS" == *Timestamp=* ]] || die 'Secure timestamp missing.'
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" == "$VERSION" ]] || die 'Marketing version mismatch.'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")" == "$BUILD" ]] || die 'Build number mismatch.'
echo "Verified plist: CFBundleShortVersionString=$VERSION CFBundleVersion=$BUILD"
{
    echo "version=$VERSION"
    echo "build=$BUILD"
    echo "commit=$REVISION"
    echo 'configuration=release'
    echo "signing_identity=$SIGNING_NAME"
    echo "timestamp=$TIMESTAMP"
    echo 'artifact_state=app-verified; disk image pending'
    echo "macos=$(sw_vers -productVersion)"
    echo "architecture=$(uname -m)"
    /usr/bin/swift --version
    cargo --version
    echo "tracked_dirty_files=$(git diff HEAD --name-only | wc -l | tr -d ' ')"
} > "$OUT/BUILD-INFO.txt"

mkdir "$RUN/image"
ditto "$APP" "$RUN/image/Yapcam.app"
ln -s /Applications "$RUN/image/Applications"
DMG="$OUT/Yapcam-$VERSION-$BUILD.dmg"
hdiutil create -format UDZO -volname "Yapcam $VERSION" -srcfolder "$RUN/image" "$DMG"
codesign --force "$TIMESTAMP" --sign "$SIGNING_HASH" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
hdiutil verify "$DMG"
if [[ -n "$PROFILE" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --output-format json | tee "$OUT/notarization.json"
    [[ "$(plutil -extract status raw -o - "$OUT/notarization.json")" == Accepted ]] || die 'Notarization was not accepted; package must not be distributed.'
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl -a -t open --context context:primary-signature -vv "$DMG"
else
    echo 'No Apple timestamp/notary/stapler/spctl request was made. To build a distributable package, run:'
    printf 'scripts/release/make-release.sh --identity %q --notarize %q\n' 'Developer ID Application: YOUR NAME (TEAMID)' 'YOUR_KEYCHAIN_PROFILE'
    echo 'For an already Developer-ID-signed, securely timestamped DMG, the submission command is:'
    printf 'xcrun notarytool submit %q --keychain-profile %q --wait\n' "build/release/$(basename "$DMG")" 'YOUR_KEYCHAIN_PROFILE'
    echo 'A local self-signed/untimestamped DMG must be rebuilt first; submitting it alone is insufficient.'
fi
(
    cd "$OUT"
    shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256"
    shasum -a 256 -c "$(basename "$DMG").sha256"
)
{
    echo 'artifact_state=complete'
    if [[ -n "$PROFILE" ]]; then echo 'notarization=accepted-and-stapled'; else echo 'notarization=not-requested; NOT DISTRIBUTABLE'; fi
} >> "$OUT/BUILD-INFO.txt"
echo "Release app: $APP"
echo "Release DMG: $DMG"
echo "Checksum: $DMG.sha256"
