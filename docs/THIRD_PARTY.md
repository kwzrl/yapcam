# Third-party components

Reviewed and approved by Lead (2026-10-15). Audited from `Package.swift`, `core/Cargo.toml`, `core/Cargo.lock`, `Sources/**` imports,
`Resources/`, `scripts/`. Licenses read from each crate's `Cargo.toml` in the local cargo
registry (2026-10-15). Yapcam itself: Apache-2.0 (`LICENSE`, `NOTICE`).

## 1. Swift Package dependencies
None. `Package.swift` declares no external packages; all Swift targets are first-party.

## 2. Rust crates (linked statically into the app via `libyapcam_core.a`)
Direct: `serde` (derive), `serde_json`. The rest are transitive (12 crates in `Cargo.lock`
including `yapcam-core` itself).

| Crate | Version | License (SPDX) | Role | Distribution impact |
|---|---|---|---|---|
| serde | 1.0.229 | MIT OR Apache-2.0 | (de)serialization | Permissive; include notice |
| serde_core | 1.0.229 | MIT OR Apache-2.0 | serde internals | same |
| serde_derive | 1.0.229 | MIT OR Apache-2.0 | derive macro (build time only) | not linked into the binary |
| serde_json | 1.0.154 | MIT OR Apache-2.0 | JSON | same |
| itoa | 1.0.18 | MIT OR Apache-2.0 | int formatting | same |
| zmij | 1.0.23 | MIT | float formatting (serde_json dep) | MIT notice required |
| memchr | 2.8.3 | Unlicense OR MIT | byte search | choose MIT; notice |
| proc-macro2 | 1.0.107 | MIT OR Apache-2.0 | build-time only | not shipped |
| quote | 1.0.47 | MIT OR Apache-2.0 | build-time only | not shipped |
| syn | 3.0.9 | MIT OR Apache-2.0 | build-time only | not shipped |
| unicode-ident | 1.0.27 | (MIT OR Apache-2.0) AND Unicode-3.0 | build-time only | not shipped; Unicode-3.0 data licence only matters if tables are distributed |
| yapcam-core | 0.1.0 | Apache-2.0 | ours | – |

`tools/yapcam-mcp` (stdio MCP wrapper around the same core, not part of the app bundle, `publish = false`):
direct dependencies `serde_json` and `yapcam-core`; its `Cargo.lock` lists the same 12 third-party crates and
versions as `core/Cargo.lock` (checked by diffing the `name` lines on main 00b7e27; only `yapcam-mcp` itself is extra),
so the table above covers it. No new licences.

Not bundled, not distributed: the in-app agent starts the user's own `claude` command-line tool (Claude Code) when the
user opens the chat; Yapcam ships no model, SDK or credentials. `tools/eval` (QA only, not shipped) uses Python 3 with
Pillow (HPND licence) and macOS `say`; golden packages are generated locally and are not in the repo.

All licenses are permissive and compatible with Apache-2.0. No copyleft, no network/telemetry
components. Action for release: ship the MIT/Apache texts for crates that end up in the
binary (serde, serde_core, serde_json, itoa, zmij, memchr) in an acknowledgements file
(e.g. generated with `cargo about` or `cargo-license`; not run here, no network tooling
installed — **open**).

## 3. Apple system frameworks (no redistribution)
AppKit, SwiftUI, Combine, Foundation, CoreGraphics, CoreImage, CoreMedia, CoreVideo,
CoreText, ImageIO, AVFoundation, AudioToolbox, ScreenCaptureKit, VideoToolbox, Metal,
MetalKit, MetalPerformanceShaders, Vision, Speech (on-device recognition), CryptoKit,
OSLog, Carbon.HIToolbox, ApplicationServices, UniformTypeIdentifiers. Linked dynamically from
macOS 15+; governed by Apple's SDK/Xcode license. Impact: app requires macOS 15; Speech
availability and on-device models depend on the user's system language packs.

## 4. Bundled assets and models
`Resources/` contains only `Info.plist`. All backgrounds, cursors, sounds and music are
generated procedurally or drawn in code (render/core status files: "original", no
third-party images/audio). No ML model weights are bundled (speech enhancement is original
DSP; Vision/Speech come from the OS). **Nothing from Screen Studio** (code, strings, assets,
binaries, models) is included — reference analysis only (TEAMS.md rule 12).
Action: keep a check in review that no file under `Resources/` or generated asset names
mirror reference assets.

## 5. Build / test / dev tooling (not distributed)
| Tool | Use | License note |
|---|---|---|
| Xcode / Swift toolchain | build | Apple |
| rustc / cargo | build core | MIT OR Apache-2.0 |
| gitleaks (pre-commit hook, `scripts/install-hooks.sh`) | secret scan | MIT; dev only |
| ffmpeg / ffprobe (`scripts/qa/*`, E2E tests) | verification of exports | LGPL/GPL depending on build; **dev/test only, not shipped, not linked**. E2E tests shell out to `/opt/homebrew/bin/ffprobe` |
| python3 (`-I`) in QA scripts | helper | PSF; dev only |
| Screen Studio (installed locally) | behavior reference only | proprietary; never copied |

## 6. Decisions and follow-ups
1. `docs/THIRD_PARTY_NOTICES.md` holds the MIT/Apache texts of the shipped crates (generated from
   registry sources); regenerate it when `Cargo.lock` changes. Decision (Lead): bundle its content
   into the app later (ui/Lead), not part of the first release candidate tonight.
2. Minimum macOS: `LSMinimumSystemVersion` is 15.0, matching the "macOS 15+" claim (confirmed by Lead).
3. If a future change adds a dependency (e.g. a Swift package or a model), add it here first
   (TEAMS.md rule 11).
