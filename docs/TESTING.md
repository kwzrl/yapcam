# Testing and Definition of Done

Run on integrated `main` builds. Hardware: Mac mini M4, one 1680×1050 non-Retina
display, no camera, no mic. Captures go to `~/Movies/Yapcam/QA/qa/`; delete afterwards.
Never commit recordings.

## Gates before any work package is "done"
1. `scripts/build-app.sh`, `swift test`, `cargo test --manifest-path core/Cargo.toml` green.
2. `scripts/qa/privacy-scan.sh` clean (no recordings, credentials, personal paths).
3. Feature checked per its acceptance test in `docs/FEATURES.md`; status updated with how.

## Definition of Done checklist (M1 → M3)
| # | Check | How | Script |
|---|---|---|---|
| 1 | Toolbar shows, modes switch, no crash | manual + AX tree | – |
| 2 | Record display + system audio + events → valid package | `qa/verify-package.sh` | yes |
| 3 | Pause/resume duration = active time, A/V in sync | record 3+pause+3; ffprobe | yes |
| 4 | Cursor/click events at scripted times (±50 ms) | `qa/drive-input.swift` (CGEvent) | yes |
| 5 | Editor opens package, preview matches background/padding | screenshot compare | – |
| 6 | Manual zoom, cut, undo/redo exact | core tests + UI drive | – |
| 7 | Autosave: kill -9 then reopen, edits intact | script | – |
| 8 | Export 1080p MP4: duration ±1 frame, tracks present | `qa/verify-export.sh` | yes |
| 9 | Export vs preview frame diff small | ffmpeg ssim/psnr | yes |
| 10 | A/V sync on 10-minute recording (clap/tone markers) | ffmpeg audio onset vs flash frame | partial |
| 11 | Failure paths: no mic, no camera, missing media, low disk, permission denied | manual/sim | – |
| 12 | Yapcam windows absent from exported file | frame check at toolbar location | – |
| 13 | Privacy scan | `qa/privacy-scan.sh` | yes |

Open (cannot test here): real camera/mic, Retina, multi-display, iPhone mirroring.

## Findings
Filed in `docs/status/qa.md` with repro steps and owning team.

## Disk hygiene
Scripts in `scripts/qa/` must not leave temp data behind: any script that creates a
directory uses `mktemp -d` plus `trap 'rm -rf "$TMP"' EXIT`. `run-e2e.sh` creates none;
E2E tests create `yapcam-e2e-*` in the temp dir and remove it in `tearDown` (a killed run can
leave one: delete `$(getconf DARWIN_USER_TEMP_DIR)yapcam-e2e-*`). Raw reference data lives in
`~/yapcam-ref-local/` and is deleted when no longer needed.
