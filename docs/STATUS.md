# Yapcam status

Maintained by Lead. Team detail: `docs/status/<team>.md`. Feature state: `docs/FEATURES.md`.

## Reference
Screen Studio **4.0.4-4926** (installed 2026-10-14) is the fixed reference for this build-out.

## Teams and branches
| Team | Agent | Branch | Worktree |
|---|---|---|---|
| Lead | Claude Opus 5.5 | `main` | `~/yapcam` |
| ui | Claude Sonnet 5.5 | `team/ui` | `~/yapcam-team/ui` |
| editor | Claude Sonnet 5.5 | `team/editor` | `~/yapcam-team/editor` |
| capture | Codex gpt-6.1-sol high | `team/capture` | `~/yapcam-team/capture` |
| core | Codex gpt-6.1-sol high | `team/core` | `~/yapcam-team/core` |
| render | Codex gpt-6.1-sol high | `team/render` | `~/yapcam-team/render` |
| qa (ref first) | Claude Sonnet 5.5; reviews: Codex gpt-6-astra, Claude Opus | `team/qa` | `~/yapcam-team/qa` |

Model choice: workhorse models for implementation; gpt-6-astra / Opus only for
architecture, A/V sync debugging, platform problems and independent reviews.

## Done and verified (on main)
- Repo setup: Apache 2.0, gitignore for media/credentials, gitleaks pre-commit hook.
- Build: `scripts/build-app.sh` builds the Rust static lib + Swift app and signs it with
  the stable local identity (`mov.yapcam.Yapcam`). `swift test` green (ABI version test).
- Setup probe: real 5 s display recording via ScreenCaptureKit (HEVC 1680×1050, VFR,
  AAC system audio) decoded without errors.
- Contracts: `docs/ARCHITECTURE.md`, `docs/FORMATS.md`, `core/include/yapcam_core.h`,
  `docs/SWIFT_API.md`; synthetic fixture `Tests/Fixtures/synthetic/basic.yapcam`.

- Integration 2 (2026-10-15 00:05): all six team branches merged; 115 Swift + 23 Rust
  tests; E2E (`swift test --filter PipelineE2E`): synthetic package → open → cut/undo/redo →
  Metal compositor → MP4 export, no drift over many edits, save/reopen, missing media — all
  green. Known flaky: editor ExportModelTests under `-j 6` (assigned to editor).
- Codex teams cannot write `.git` from their sandbox: Lead commits/rebases their worktrees
  each cycle (commits titled "checkpoint (committed by Lead …)").

- Integration 4 (01:00): main 6d91a7f — 151 Swift + 54 XCTest + 39 Rust green.
  Render hardware run (`YAPCAM_REQUIRE_RENDER_HARDWARE=1`, M4): 43/43 incl. A/V sync
  within one frame after export, cancelled export keeps existing file, ffprobe agrees.
  Measured (synthetic decoded source, no audio, 60 frames): export 1080p 3.7× realtime,
  4K 1.9× realtime; live preview 1080p 58.7 fps, 4K 59.5 fps (1 dropped frame / 2 s).
- Reviews round 1: Codex gpt-6-astra on ui/editor (15 findings), Claude Opus on
  core/capture (6 findings); all handed to owners (fleet-local review files).

## Open
Everything in `docs/FEATURES.md` (being written by qa). First integration target: M1
(see `docs/briefs/common.md`).

## Blockers / limits
- Reference analysis: REA 6.5.0 + Ghidra 12.1.4 work (native Mach-O analysis verified).
  Screen Studio is Electron; REA's JS analysis of the full app.asar exceeded its resource
  limit, the own-sources run (226 files) finished but its graph is truncated and yields
  few feature-level facts. Remaining inventory relies on official docs + observation
  (observation of the running app needs a session with screen access → morning, with user).
- Screen-recording permission must be re-granted for the new signing identity
  (`Yapcam Dev Signing`, dedicated keychain). Until then no live capture tests.
- No camera and no microphone on this Mac → real-device tests open.
- One non-Retina display (1680×1050) → Retina/multi-display only by math/unit tests.

## Next integration steps
1. core: model + persistence + time model → merge.
2. capture: display recording writing the package format → merge.
3. render: compositor + export against core → merge.
4. ui + editor: toolbar → record → editor → export (M1 end-to-end).

## Resume
```sh
cd ~/yapcam && git log --oneline -5 && cat docs/STATUS.md docs/status/*.md
herdr workspace list            # fleet panes: workspace label "Yapcam · <team>"
scripts/build-app.sh && swift test && cargo test --manifest-path core/Cargo.toml
```
