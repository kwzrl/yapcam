# Setup

Reproducible build setup for Yapcam on an Apple Silicon Mac.

## Requirements

- macOS 15 or newer, Apple Silicon (verified on macOS 26.3, Mac mini M4).
- Xcode 26 selected as the active developer directory:
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
  (`scripts/build-app.sh` also sets `DEVELOPER_DIR` to that path if unset).
- Rust stable via rustup (verified with 1.95), target `aarch64-apple-darwin`.
- Optional for QA scripts: `ffmpeg`/`ffprobe` (Homebrew), `gitleaks` for the commit hook.

## One-time steps

```sh
git clone https://github.com/kwzrl/yapcam.git && cd yapcam
scripts/install-hooks.sh      # gitleaks + media/key guard for commits
scripts/setup-signing.sh      # local self-signed identity "Yapcam Dev Signing"
scripts/build-app.sh          # builds core (Rust) + app (Swift), signs build/Yapcam.app
open build/Yapcam.app
```

`setup-signing.sh` creates a dedicated keychain
(`~/Library/Keychains/yapcam-signing.keychain-db`, password in
`~/.config/yapcam/signing-keychain-pass`, mode 600) so `codesign` never shows keychain
dialogs and the app keeps a stable designated requirement
(`identifier "mov.yapcam.Yapcam"` + certificate hash). Without it, the build falls back to
ad-hoc signing and macOS asks for privacy permissions again after every build.
A paid Apple Developer account is not needed for local use; distribution signing and
notarization are not set up.

Then grant `build/Yapcam.app` in System Settings → Privacy & Security:
**Screen & System Audio Recording**, **Accessibility**, **Input Monitoring**; the app asks
for **Microphone** and **Camera** itself. If you ever regenerate the identity, remove and
re-add the app in those lists (macOS remembers the old signature).

## Tests

```sh
cargo test --manifest-path core/Cargo.toml          # Rust core
swift test                                          # Swift modules + E2E
YAPCAM_REQUIRE_RENDER_HARDWARE=1 swift test --filter YapcamRenderTests   # Metal, fails instead of skipping
YAPCAM_RENDER_M3=1 YAPCAM_REQUIRE_RENDER_HARDWARE=1 swift test --filter LongExportTests  # ~15 min
```

Tests that need real capture (screen recording permission) are opt-in; see
`docs/TESTING.md`.
