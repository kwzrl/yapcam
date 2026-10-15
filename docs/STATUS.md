# Yapcam status

Maintained by Lead. Team detail: `docs/status/<team>.md`. Feature state: `docs/FEATURES.md`.

## Morning handover (2026-10-15 06:55)

State: main 64645c3 — 316 Swift + 114 XCTest (4 skipped) + 68 Rust tests green; render
86/86 on Metal; fresh clone builds. FEATURES.md: 119 rows — 24 verified, 48 integrated,
24 implemented, 23 limited, none todo. App: `~/yapcam/build/Yapcam.app`.

Not done / not verified (honest list):
- No live screen/window/area recording has been verified with the integrated app: the
  screen-recording grant was lost when signing moved to `Yapcam Dev Signing` (23:30) and
  was not re-granted. All REC rows are implemented/limited only; capture is tested with
  injected sample buffers and synthetic packages, the setup probe recorded once before
  the switch.
- Toolbar exclusion from the exported video, cursor/zoom from real input, real-recording
  A/V sync and performance on real 1080p/4K captures: not verified.
- Camera, microphone, multi-display, Retina: no hardware; math/unit tests only.
- Screen Studio [observed] rows: need a session with screen access.
- VoiceOver: labels implemented, not exercised.

Needs the user (≈10 min):
1. System Settings → Privacy & Security → remove + re-add `~/yapcam/build/Yapcam.app` in
   Screen & System Audio Recording, Accessibility, Input Monitoring.
2. Then Lead/QA run the live DoD list (docs/TESTING.md): record, pause/resume, cursor/zoom,
   edit, export vs preview, 10-min A/V sync, window exclusion.
3. Observation of Screen Studio 4.0.4 for the [observed] rows.

## Live verification (2026-10-15 from 10:25, screen recording granted)
- Display recording + system audio + events: complete packages (HEVC 1680×1050 ~58 fps, AAC).
- 10-min recording: 600.08 s, 34 476 frames, RSS ≤ 73 MB; A/V sync over 300 flash/beep pairs:
  offsets 2.5 / −14.2 / 9.8 ms (first/mid/last), drift 7.3 ms (frame quantisation 16.7 ms).
- Real recording opened in core, cut/zoom/padding, undo/redo, save/reopen: pass.
- Export vs preview (real recording, 720p): mean abs luma diff 0.50/255.
- F6 (export with audio failed on the last ~100 ms of real recordings): fixed by render,
  verified by Lead on main 529f208 — LiveRecordingTests 4/4 incl. full edit+export (156 s).
- ui: toolbar → record → stop → editor opens, verified live; toolbar/HUD absent from the video.
- Still open: Accessibility/Input Monitoring not granted to the app (clicks/keys, scripted
  input), window/area/pause live runs, recovery of an interrupted package.

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

- Integration 9 (03:13): main a02a89e — 256 Swift + 97 XCTest + 61 Rust green; no
  FEATURES row left `todo`. Render on Metal (M4, `YAPCAM_REQUIRE_RENDER_HARDWARE=1`): 86/86
  incl. text, reactions, captions, highlights, camera effects. Benchmarks (synthetic decoded
  source, 60 frames, no audio): export 1080p 4.7×, 4K 1.9× realtime; preview 1080p 57.6 fps
  (3 dropped / 2 s), 4K 58.9 fps (2 dropped / 2 s).
- Reviews round 2: 14/15 ui/editor round-1 findings fixed, 6/6 core/capture fixed; new
  findings (7 ui/editor, 2 render/capture) handed to owners. M3 hardening started 03:15.

- M3 render on hardware (04:40, debug build, Apple M4):
  - 10-min export 1080p30 with audio (procedural flash + beep): A/V offset start 0.04 ms,
    middle 0.02 ms, end 0.02 ms; 4.4× realtime; peak RSS 137 MB.
  - 30-min export soak (looping 320×200 decoded source + PCM, 1080p30): 2.2× realtime,
    peak RSS 183 MB, steady RSS growth −2.5 MB (no leak).
  - Preview with audio, 30 s: 1080p 58.3 fps (45 dropped submissions), 4K 58.9 fps (31).
  Limitation: sources are synthetic/low-resolution; real 1080p/4K screen recordings are not
  measured yet (needs the screen-recording grant).

- Fresh checkout (05:05): `git clone https://github.com/kwzrl/yapcam` → `scripts/build-app.sh`
  builds Rust + Swift and signs `build/Yapcam.app` (15 MB) without manual steps on this Mac.

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
