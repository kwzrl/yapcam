# Yapcam

A native macOS app for recording your screen, camera and audio and editing the result locally. Apple Silicon, no account, no cloud, no watermark. Apache 2.0.

Status: early development. See [docs/STATUS.md](docs/STATUS.md).

## Build

Requirements: macOS 15+, Apple Silicon, Xcode 26 (or matching Command Line Tools), Rust stable.

```sh
scripts/install-hooks.sh     # secret/media guard for commits
scripts/build-app.sh         # builds and signs build/Yapcam.app
open build/Yapcam.app
```

`build-app.sh` signs with a local identity named `Yapcam Local Dev` if present (stable app identity, so macOS privacy permissions survive rebuilds) and falls back to ad-hoc signing. See [docs/SETUP.md](docs/SETUP.md).
