# Release packaging

`VERSION` is the marketing version (`0.11.0`). The build number is
`git rev-list --count HEAD` at the start of packaging. The release script stamps
`CFBundleShortVersionString` and `CFBundleVersion` into the **built** app before
signing; it does not edit `Resources/Info.plist`. The ordinary debug build command
continues to work unchanged.

## Prerequisites

- Apple Silicon, macOS 15+, Xcode 26 with its command-line tools and SDK installed,
  and Rust stable. See [SETUP.md](SETUP.md). No new package dependency is required.
- Cargo dependencies already cached. Packaging sets `CARGO_NET_OFFLINE=true` and
  SwiftPM `--skip-update`; the package currently has no remote Swift dependencies.
  Missing dependencies produce a build failure, not an implicit download.
- A signing certificate **and its private key** in an unlocked keychain. For local
  testing, the existing `Yapcam Dev Signing` identity works. It is self-signed and
  cannot produce a distributable/notarized release.
- For distribution: Apple Developer membership and a **Developer ID Application**
  certificate, not Apple Development or Developer ID Installer. In Xcode, use
  Settings → Accounts → your account/team → Manage Certificates → `+` →
  Developer ID Application. Keep the associated private key in Keychain; do not
  put certificates, keys, passwords or account identifiers in the repository.

List available identities with `security find-identity -p codesigning`. The local
self-signed certificate may be omitted by `-v` because it is not Apple-trusted.
The script chooses the first valid Developer ID Application identity; if there
is none, it selects `Yapcam Dev Signing`. `--identity` accepts its full name or
certificate SHA-1. An unavailable identity is an error; there is no ad-hoc fallback.

## Local package, no Apple service requests

```sh
scripts/release/make-release.sh
# Explicit local identity:
scripts/release/make-release.sh --identity "Yapcam Dev Signing"
```

The script calls `scripts/build-app.sh release` twice, each time with a new Swift
scratch directory and a cleaned Rust release target. It uses four build jobs.
The canonical builder still updates `build/Yapcam.app`; the versioned, hardened
release copy is separate at `build/release/Yapcam.app`. Do not run concurrent
builds in this worktree or package while testing that canonical app.

`build/release/` is exclusively generated output. Subsequent runs list and replace
that directory only when it carries this script's ownership marker. An unrelated
directory is refused. A lock prevents concurrent release invocations. Temporary
build/image directories are printed before removal by an EXIT/signal cleanup trap.
An interrupted run can leave partial output; successful checksum verification and
the final `Release DMG:` line distinguish completion. Never distribute partial output.

Outputs:

```text
build/release/Yapcam.app
build/release/Yapcam.app.dSYM
build/release/Yapcam-0.11.0-<build>.dmg
build/release/Yapcam-0.11.0-<build>.dmg.sha256
build/release/reproducibility.txt
build/release/BUILD-INFO.txt
```

The UDZO image contains `Yapcam.app` and an `Applications` symlink to
`/Applications`; its volume is `Yapcam 0.11.0`. The app and DMG are signed with the
same selected identity. Leaf Mach-O code is signed before nested bundles and
finally the outer app. Signing never uses `--deep`. The app uses hardened runtime.
The release copy also includes the repository's Apache license and existing
third-party notices in `Contents/Resources/` before its resource seal is signed.

**Offline packages are NOT DISTRIBUTABLE**, even when a Developer ID identity
is selected. Local mode explicitly uses `--timestamp=none`, performs structural
signature/image/checksum verification, and makes no timestamp, notary, stapler or
Gatekeeper assessment request. The release requirement for secure timestamps
conflicts with its requirement for no Apple contact without `--notarize`:
`codesign --timestamp` contacts Apple's timestamp service (see `man codesign`).
This workflow gives the offline requirement priority and enables secure timestamps
only on the explicit online path below. No certificate-trust settings are changed.

## Distribution and notarization

For the current release-candidate round, notarization is **preparation only**:
do not execute the online commands below or submit anything to Apple. They
document the optional future workflow after separate user authorization and
installation of the Developer ID identity. Local packaging uses Yapcam Dev Signing.

Create a profile interactively, outside the script:

```sh
xcrun notarytool store-credentials "Yapcam-Release"
```

Follow the prompts for the user-owned Apple credentials/team. Do not put passwords
or API keys on command lines in scripts or docs. The release tool receives only
the Keychain profile name, never a credential value.

```sh
scripts/release/make-release.sh \
  --identity "Developer ID Application: YOUR NAME (TEAMID)" \
  --notarize "Yapcam-Release"
```

`--notarize` explicitly opts into network operations: secure timestamping for all
signatures, `notarytool submit ... --keychain-profile ... --wait`, ticket stapling,
ticket validation, and Gatekeeper assessment. A non-Developer-ID identity is
rejected before building or contacting Apple. A rejected submission, missing
ticket, failed assessment or failed signing operation aborts the script. The
notary result must say `Accepted`; the final checksum is generated **after**
stapling changes the DMG. `notarization.json` contains the service result, not
credentials. Without this flag, the script prints the exact release/submission
command template. Submitting a self-signed or untimestamped local DMG alone is
insufficient; rebuild with the distribution command.

Do not describe local signing success as notarization or Gatekeeper acceptance.
Apple service availability and Developer ID credentials are required for this path.

## Entitlement audit

[Yapcam.entitlements](../scripts/release/Yapcam.entitlements) contains only:

| Key | Reason in this source tree |
|---|---|
| `com.apple.security.device.camera` | AVFoundation camera and USB video-device capture in `AuxiliaryCapture` and `DeviceScreenCapture`. |
| `com.apple.security.device.audio-input` | AVFoundation microphone recording in `AuxiliaryCapture`; audio-input protection also applies with hardened runtime. |

The app is not App Sandbox enabled. ScreenCaptureKit screen/system-audio capture,
Accessibility window resizing and Input Monitoring event taps still require the
user's TCC consent; no private/bypass entitlement is added. The built Info.plist
already contains camera, microphone and Speech usage descriptions. On-device
Speech keeps its ordinary permission/availability checks; no server fallback is
enabled. Source inspection found no AppleScript, ScriptingBridge, `osascript` or
Apple Events sender, so `com.apple.security.automation.apple-events` is omitted.
No JIT, unsigned executable memory, disabled library validation, debugger, sandbox,
network server, or private entitlement is added. The native Swift/Rust executable
uses system frameworks; it does not load an unsigned third-party plug-in.
Future helpers or capabilities need their own entitlement review.

Apple documents the resource-access choices in
[Enable hardened runtime](https://help.apple.com/xcode/mac/current/en.lproj/devf87a2ac8f.html)
and [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events).

## Verification

```sh
bash -n scripts/release/make-release.sh
zsh -n scripts/release/make-release.sh
plutil -lint scripts/release/Yapcam.entitlements
codesign --verify --strict --verbose=2 build/release/Yapcam.app
codesign -dvv build/release/Yapcam.app
codesign -d --entitlements :- build/release/Yapcam.app
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/release/Yapcam.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build/release/Yapcam.app/Contents/Info.plist
release_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build/release/Yapcam.app/Contents/Info.plist)
release_image="Yapcam-$(cat VERSION)-$release_build.dmg"
codesign --verify --strict --verbose=2 "build/release/$release_image"
hdiutil verify "build/release/$release_image"
(cd build/release && shasum -a 256 -c "$release_image.sha256")
```

`codesign -dvv` must show flag `runtime` and the selected authority. A Developer ID
release must have the expected TeamIdentifier and secure timestamp. A self-signed
local build normally prints `TeamIdentifier=not set`; that is not distribution proof.
After the **online** release only:

```sh
xcrun stapler validate "build/release/$release_image"
spctl -a -t open --context context:primary-signature -vv "build/release/$release_image"
```

The verification block reads the build number from the produced app, so a later
documentation checkpoint does not accidentally select a different DMG filename.

## Reproducibility

Every packaging run builds the same checkout twice from separate fresh Swift
scratch directories and clean Rust release artifacts. Release-only settings are:

- `ZERO_AR_DATE=1` and `SOURCE_DATE_EPOCH=$(git show -s --format=%ct HEAD)` fix
  archive/build-time metadata to a reproducible source revision.
- Swift `-file-prefix-map` and `-debug-prefix-map` replace checkout, home and
  each pass's scratch directory with `/yapcam/src`, `/yapcam/home` and
  `/yapcam/build`. Both logical and physical scratch paths are mapped. The
  equivalent Clang importer flags and serialized-debug-option mapping are used.
- Rust `--remap-path-prefix` maps home, Cargo registry and checkout paths to
  `/yapcam/home`, `/yapcam/cargo` and `/yapcam/src`. These flags use Cargo's
  encoded argument format so spaces in paths are retained. Release packaging
  deliberately sets its own Rust flag configuration instead of inheriting
  arbitrary `RUSTFLAGS`/`CARGO_ENCODED_RUSTFLAGS` from the invoking shell.
- Apple's linker receives `-reproducible` and `-oso_prefix` for each pass's
  scratch directory. Removing that variable prefix from debug-map object paths
  before linking also stabilizes the computed UUID. UUIDs remain real
  linker-generated identifiers, not a hardcoded value or a field masked out
  of the comparison.

After the first link, `dsymutil` creates **`build/release/Yapcam.app.dSYM`** while
its Swift and Rust object files still exist. It runs from the scratch directory
to resolve relative Swift objects and absolute Rust archives correctly;
`--object-prefix-map` resolves virtual module-cache paths without changing the
remapped source paths in the dSYM. The script then removes code
signatures and uses `strip -S -x` on each executable copy, removing debug-map and
local-symbol paths from the executable. It compares **all resulting Mach-O
bytes**, including the UUID, and writes both SHA-256 digests into
`reproducibility.txt`. The app uses the first compared executable, re-signed only
after version stamping and resource assembly. Its UUID must match the saved dSYM.

`unsigned_macho_identical=yes` means those complete unsigned, stripped executable
bytes match; it does not mean the signed app or DMG is identical. If comparison
fails, packaging stops and records UUIDs plus the exact differing byte offsets
(decimal, one-based) and old/new octal values in `reproducibility-differences.txt`.
No signatures or binaries are published as a successful reproducible release in
that case. Sources must remain unchanged throughout the two builds; this check
is for the same checkout, toolchain, architecture, SDK and release settings.

Privacy is checked on **both** unsigned executables, the separate dSYM and again
on the signed app.
`strings -` scans every byte, including the symbol table: Apple's `strings -a`
only scans Mach-O sections and missed N_OSO paths in the original report.
Any user-directory, actual checkout or run-directory path aborts packaging.
Rust source/panic strings need prefix mapping even after stripping; stripping
alone is insufficient. This replaces the initial workflow, which only explained
the timestamp/path/UUID differences and retained personal build paths.

The separate dSYM is an internal debugging artifact. It is kept alongside the
app and excluded from the DMG (the image staging directory receives only the app
and Applications symlink). Archive it together with the commit/build metadata
for crash symbolication. The ordinary debug builder and its symbols are unchanged.
For source-level debugging against the matching checkout, map the virtual source
prefix in LLDB: `settings set target.source-map /yapcam/src /path/to/checkout`.

```sh
cat build/release/reproducibility.txt
xcrun dwarfdump --uuid build/release/Yapcam.app/Contents/MacOS/Yapcam
xcrun dwarfdump --uuid build/release/Yapcam.app.dSYM
/usr/bin/strings - build/release/Yapcam.app/Contents/MacOS/Yapcam |
  awk 'index($0,"/Users/") { n++ } END { print "private_path_strings=" n+0; exit(n!=0) }'
```

The complete signed artifacts are not expected to be identical: source checkout
changes affect the build count, code signatures include signing times, online
signatures include timestamp tickets, notarization adds a stapled ticket, and the
DMG filesystem carries creation/modification metadata and its own signature.
Checksum files describe the exact produced/stapled image, not future rebuilds.

If `hdiutil create` reports a disk-image device error in a restricted agent
sandbox, the script stops, leaves the verified app/report for inspection, and
cleans its temporary directories. There is no fake DMG, checksum, or fallback
archive. Run the same release command on the native host to finish acceptance;
no `sudo`, permission reset or security bypass is needed. `BUILD-INFO.txt` remains
at `artifact_state=app-verified; disk image pending` until the image and checksum
steps complete.

## First-install acceptance (Lead on the native host)

1. Keep a development copy at `build/Yapcam.app`; use `/Applications/Yapcam.app`
   for the chosen installed release identity. Do not alternate signing identities
   at one installed path or run two copies simultaneously: both use bundle ID
   `mov.yapcam.Yapcam`. A signing-identity change changes the Designated Requirement
   and can make macOS ask for permission again. Never reset TCC or remove the
   user's existing permissions as part of this procedure.
2. Confirm no Yapcam instance is running and `~/Movies/Yapcam/QA/.app-lock` is absent.
   Acquire that lock for your team before launching; if another team owns it, stop
   the live check. Mount the DMG read-only (`hdiutil attach -readonly -nobrowse ...`),
   inspect both contents, and verify the app signature from the mounted image.
3. Drag/copy the app to Applications. Launch through LaunchServices only:
   `open -n -W /Applications/Yapcam.app`. Do not execute `Contents/MacOS/Yapcam`.
   For the local self-signed image, ordinary Gatekeeper trust is not promised; do
   not disable system protection or add a trust exception automatically. Also
   verify a LaunchServices launch of the mounted app, recording any rejection.
4. Check About shows `0.11.0` and the expected build. Verify first-run permission
   guidance, deny/cancel paths, then grant permissions through normal system UI.
   Record display and area, pause/resume, open the resulting project, edit, save,
   reopen and export MP4. Check file playback, cursor timing and system audio.
   Programmatic self-tests are separate evidence, not physical interaction proof.
5. Camera/microphone, USB devices, Retina and additional displays remain
   **untested (no hardware)** on the current one-display Mac mini. Check graceful
   unavailable states; do not claim those physical features passed.
6. Quit only your own launched instance, detach only your own mounted image and
   remove only your own app lock. Do not signal any other team's process.

## Update acceptance

1. Back up a synthetic project and use a prior installed build signed with the
   same release identity. Save edits, close the app, then install the newer app
   at the same release path with Finder. Do not overwrite a running app.
2. Verify version/build changed, previously saved projects open, edits/defaults
   are retained, undo/save/reopen and export still work, and recovery/missing-media
   guidance remains usable. Never modify recordings to make an update test pass.
3. Check permissions with the same certificate and with a deliberate dev→release
   identity transition as separate cases. Record actual prompts and permission
   states; an unchanged bundle ID alone does not guarantee TCC continuity.
4. Test a quarantined, downloaded **notarized** DMG on a clean account/machine
   before public distribution. A local non-quarantined self-signed DMG is not a
   substitute. Keep the previous release available for rollback; there is no
   automatic update mechanism.

See [CHANGELOG.md](../CHANGELOG.md) and [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)
before tester sign-off. Packaging success is separate from install/TCC acceptance.
