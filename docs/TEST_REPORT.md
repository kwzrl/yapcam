# Yapcam test report — structure (draft; fill at handover)

Build under test: `<main sha>` · date · machine (Mac mini M4, macOS `<ver>`, 1680x1050) ·
signing identity · permissions granted: `<list>`.
Build and signing setup: see `docs/SETUP.md` (`scripts/setup-signing.sh` creates the local
"Yapcam Dev Signing" identity; `scripts/build-app.sh` builds and signs `build/Yapcam.app`).
A fresh clone builds without manual steps (Lead check 05:05, main aa70d91).

## 1. Summary (fill last)
Pass/fail counts per suite, headline risks, go/no-go per milestone (M1, M2, M3).

## 2. Automated suites
| Suite | Command | Result | Skips (why) |
|---|---|---|---|
| Rust core | `cargo test --manifest-path core/Cargo.toml` | `<n pass>` | – |
| Swift (all) | `swift test --disable-sandbox -j 4` | `<n>` | Metal/media gated |
| Render on Metal | `YAPCAM_REQUIRE_RENDER_HARDWARE=1 swift test --filter YapcamRenderTests` | 86/86 (03:15) | – |
| E2E pipeline | `scripts/qa/run-e2e.sh` | 11/11 | – |
| Privacy scan | `scripts/qa/privacy-scan.sh` | `<clean/findings>` | – |

## 3. Definition of Done checklist (docs/TESTING.md)
One row per item 1-13: result, evidence (log/command/file), owner of any defect.

## 4. Live-capture tests (needs TCC grant)
| Test | Procedure | Result | Evidence |
|---|---|---|---|
| Display record + system audio + events | `--capture-selftest`, `scripts/qa/verify-package.sh` | | |
| Pause/resume | 3 s + pause + 3 s | | duration, sync |
| Scripted input vs events.jsonl | `scripts/qa/drive-input.swift` | | max error ms |
| Own windows absent in export | frame check at toolbar position | | |
| Export vs preview diff | ffmpeg ssim/psnr | | |
| 10-minute A/V sync | tone + flash markers | | offset ms start/end |
| Kill -9 recovery | | | |
| Low disk / permission revoked / source lost | | | |

## 5. Performance
Export speed (1080p, 4K), preview fps and dropped frames, scrub latency, memory on 10-min
project, disk write rate. Synthetic baseline: see docs/STATUS.md.

## 6. Feature matrix
Counts by status from docs/FEATURES.md (verified / integrated / implemented / limited /
todo) and the delta since last report. Link rows that moved.

## 7. Findings
| ID | Severity | Owner | Repro | Status |
|---|---|---|---|---|
(F1-F4 from docs/status/qa.md carried over with current state.)

## 8. Reference observation (morning session with the user)
Checklist of Screen Studio panels/menus to observe, values captured, rows updated.

## 9. Not tested / limitations
Link docs/KNOWN_LIMITATIONS.md; list anything new.

## 10. Privacy and licence
Scan results (`scripts/qa/privacy-scan.sh`), THIRD_PARTY.md (approved) and THIRD_PARTY_NOTICES.md status, confirmation that no reference assets are included.

## Update log (keep current with each Lead integration)
| Date | Main | What changed in this report |
|---|---|---|
| 2026-10-15 | b90ee0d | Structure only; Metal 86/86, M3 long-export/soak, fresh-checkout build recorded in docs/STATUS.md; live capture still blocked (TCC) |
