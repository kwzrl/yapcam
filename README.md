<img src="docs/assets/yapcam-icon.png" width="128" alt="Yapcam icon">

# Yapcam

A native macOS app for recording your screen, camera and audio and editing the result locally. Apple Silicon, no account, no cloud, no watermark. Apache 2.0.

## Download

**[Download Yapcam for Mac (DMG)](https://github.com/kwzrl/yapcam/releases/latest/download/Yapcam.dmg)**

Requires macOS 15 or later on a Mac with Apple Silicon (M1 or newer). Intel Macs are not supported.
The app is signed with a Developer ID and notarized by Apple. Each release lists the SHA-256 of its DMG.

1. Open the DMG and drag Yapcam to Applications.
2. Start Yapcam. It walks you through the macOS permissions it needs, one per page, starting with Screen Recording.
3. Pick a display, window or area in the toolbar and press record. Stop, and the editor opens.

New versions appear on [GitHub Releases](https://github.com/kwzrl/yapcam/releases). There is no automatic update check yet: download the new DMG and replace the app in Applications. Your projects stay where they are.

## What it does

- Record a display, a window or an area, with system audio, microphone and camera.
- Automatic zoom on clicks, smooth cursor, click effects, cursor size and style.
- Trim and cut on a timeline, backgrounds, padding, rounded corners and shadows.
- On-device captions (Apple speech recognition), vertical 9:16 and other aspect ratios.
- Export MP4, MOV or GIF, or copy the exported file straight to the clipboard.
- Everything stays on your Mac: no account, no upload, no telemetry, no watermark.

## Known limitations

See [docs/KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md). In short: Apple Silicon and macOS 15+ only, no automatic updates, no cloud sharing links.

## Support

Report bugs and questions in [GitHub Issues](https://github.com/kwzrl/yapcam/issues). Please include your macOS version, your Mac model and the Yapcam version (Yapcam ▸ About Yapcam).

## Build from source

Requirements: macOS 15+, Apple Silicon, Xcode 26 (or matching Command Line Tools), Rust stable.

```sh
scripts/install-hooks.sh     # secret/media guard for commits
scripts/build-app.sh         # builds and signs build/Yapcam.app
open build/Yapcam.app
```

`build-app.sh` signs with a local identity named `Yapcam Dev Signing` if present (stable app identity, so macOS privacy permissions survive rebuilds) and falls back to ad-hoc signing. See [docs/SETUP.md](docs/SETUP.md). Release packaging, signing and notarization: [docs/RELEASE.md](docs/RELEASE.md). Project status: [docs/STATUS.md](docs/STATUS.md).

## License

Apache License 2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE). Third-party components and their licenses: [docs/THIRD_PARTY.md](docs/THIRD_PARTY.md). The app bundle carries the same notices (Help ▸ Third-Party Notices).
