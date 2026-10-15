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

## 4. Live-capture tests (signed build, main b5d1268, 2026-10-15 10:25-11:10, Mac mini M4, 1680x1050)
Method: `build/Yapcam.app --capture-selftest N` (the only live hook; my shell has no Accessibility/Screen
Recording grants, so no UI driving or screenshots). Analysis with `scripts/qa/verify-package.sh`,
`scripts/qa/analyze-sync.py`, `Tests/E2E/LiveRecordingTests.swift`.
| Test | Result | Evidence |
|---|---|---|
| Display record + system audio + events | PASS | 8 s package: HEVC 1680x1050, 470 frames, AAC audio, events.jsonl; verify-package ok |
| 4-min recording stability | PASS | status complete, 240.14 s, 13,838 frames, RSS flat 72 MB (sampled every 10 s) |
| 10-min recording + A/V sync (flash+beep every 2 s, `sync-marker.swift`) | PASS | complete, 600.08 s, 34,476 frames; 300/300 flash/beep pairs; offsets first/mid/last 2.5/-14.2/9.8 ms, range -15.2..24.1 ms (frame quantisation 16.7 ms), mean 12.2 ms, **drift 7.3 ms over 10 min**; RSS max 73 MB; package 97 MB |
| Interrupted recording tail readable | PASS (indirect) | two runs killed by other processes (7.5 min); the partial fragmented MOV was still analyzable: 223/223 pairs, drift 1.3 ms; session stays status=recording (needs RecordingSession.recover, not run) |
| Open real package in core, cut/zoom/padding edits, undo/redo, save/reopen | PASS | testOpenRealRecording (duration 600.083 s == recorded) |
| Export vs preview frame diff (real recording, 720p, t=2 s) | PASS | mean abs luma diff 0.50/255 (threshold 6) |
| Export 1080p of real recording with edits and audio | **FAIL (F6)** | decode error after 137 s when the range includes the final ~100 ms with audio; last 15 s with tail-100ms OK; full tail without audio OK |
| Area capture (`--live-e2e area`) | PASS | 800x500 selection -> video 800x500, 241 frames, complete |
| Window capture (`--live-e2e window`) | PASS (minor F8) | Terminal 1627x1015 pt -> video 1626x1014 (even-size rounding); session.json pixel_size says 1627x1015 |
| Pause/resume (`--live-e2e pause`) | PASS | 2 segments 2.15 s + 1.93 s, pause excluded |
| Default flow (toolbar, countdown, record, stop, editor, export) | PASS up to export; export with audio FAIL (F6) | editor opened on the new package; export without audio OK |
| Toolbar/HUD/countdown excluded from video | PASS (ui team evidence) | ui extracted frames at 0.3/2/4 s; not repeated by qa |
| Scripted input vs events.jsonl | NOT RUN | CGEvent posting from my shell is not delivered (no Accessibility); needs in-app `--drive-input` (Request to Lead) |
| Toolbar excluded from exported video | NOT RUN | selftest shows no toolbar; needs UI-driven recording |
| Autosave / kill -9 / reopen via UI, undo/redo via UI, toolbar interaction | NOT RUN | needs UI automation (no AX for qa) |
| Failure paths live (permission revoked, low disk, device lost) | NOT RUN | covered by capture injected-fault tests only |

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
| 2026-10-15 11:10 | b5d1268 | Section 4 filled with live results (display, 4/10-min, A/V sync, export diff, F6 tail-export failure) |
| 2026-10-15 | 7d545a1 | Editor export sheet now exposes MP4/MOV/GIF, 4K, 24 fps, quality (EXP-02/04 integrated); no new test results by qa |
