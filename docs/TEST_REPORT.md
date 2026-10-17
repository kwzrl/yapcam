# Yapcam test report — structure (draft; fill at handover)

Build under test: `<main sha>` · date · machine (Mac mini M4, macOS `<ver>`, 1680x1050) ·
signing identity · permissions granted: `<list>`.
Build and signing setup: see `docs/SETUP.md` (`scripts/setup-signing.sh` creates the local
"Yapcam Dev Signing" identity; `scripts/build-app.sh` builds and signs `build/Yapcam.app`).
A fresh clone builds without manual steps (Lead check 05:05, main aa70d91).

## 0. Release candidate 0.9.0 summary (2026-10-16, Lead)

Build under test: main `7e3af60` (code = `4f97d8d` + docs), Mac mini M4, macOS 26.3, one 1680×1050
non-Retina display, no camera, no microphone. Signed "Yapcam Dev Signing", not notarized.

| Area | Procedure | Result |
|---|---|---|
| Automated suites (4f97d8d) | `cargo test`; `swift test -j 4` | Rust 113 pass / 1 ignored; XCTest 251 (16 skipped, 0 failures); Swift Testing 598 in 120 suites pass |
| Render on Metal, strict | `YAPCAM_REQUIRE_RENDER_HARDWARE=1 swift test --filter YapcamRenderTests` | 230 run, 10 skipped (opt-in long runs), 0 failures |
| Privacy / secrets | `scripts/qa/privacy-scan.sh`; `gitleaks git` (full history) | clean (after removing two home paths from status files); no leaks |
| Release package | `scripts/release/make-release.sh` | app + DMG + sha256; two clean release builds bit-identical before signing; no personal paths in the binary; hardened runtime; camera + audio-input entitlements only |
| Speech, native (Lead, generated speech files, Apple on-device only) | capture harness + `speech_metrics.py` | after F13 fix: DE 163/163 words, WER 8.6 %; EN 154–156/162, WER 9.3–9.9 %; sentence boundaries median 45–70 ms, max 810 ms. Fillers recognised 0–1 of 3. Unsupported locale → typed error in <1 ms |
| Speech clean-up (F14), native | same fixtures, 10 dB SNR noise | before fix SI-SDR 10 → 0.5/2.0 dB and pause noise +10–12 dB (defect); after fix SI-SDR 10 → 15.5 (DE) / 15.7 (EN) dB, pause noise −30 / −34 dB, no clipping, −16 LUFS. Not judged by ear |
| Performance, release build (render harness `run_round3.py --mode all`, Lead native) | recorded 1680×1050 HEVC (17 s, looped to 21 min timeline) and synthetic 3840×2160 HEVC 60 fps (120 s) | preview 1080p/4K output 57.9–59.9 fps, 0–20 dropped submissions / 30 s; 20-min soak 59.3–59.9 fps, no RSS growth (peak 116 MB recorded, 208 MB 4K); random seek p95 133 ms (recorded), 232 ms (4K after F17 work, was 466 ms); sequential scrub p95 33 ms; export 1080p 3.5×, 4K60 0.98× realtime (F18 open); cancel + re-export: original intact, re-export valid |
| User flows | QA, programmatic only (section "Round 3") | Flow A/C equivalents, low disk, disk full, kill -9 recovery pass; F11 Esc 15/15, Return 28/33 before the F16 fix |
| Not done | — | real mouse/keyboard flows, area drag, permission loss, VoiceOver/AX, Screen Studio comparison, camera/mic, Retina/multi-display, clean second-Mac install, notarization |

Defects this round: F11, F13, F14, F16 fixed; F15 explained (stale incremental build, no product
defect); F17 improved, open (medium); F18 open (medium); review round 3: 21 ui/editor findings and
1 high core finding fixed.

## 1. Summary
Status 2026-10-15 ~21:05, main 97b9d82 (Mac mini M4, 1680x1050, signed build, all permissions granted).
- **Automated:** Rust 100 pass (1 ignored); Swift: XCTest 207 run (10 skipped, 0 failures), Swift Testing 501 tests in 99 suites pass; render on Metal 86/86 (Lead run); E2E 11/11 plus 5 live-recording tests.
- **Live (real captures):** display, window, area, pause/resume, 10-minute recording with A/V sync (drift 7.3 ms), crash recovery, scripted input (max 15 ms / 0.98 pt), auto-zoom from real clicks, toolbar/HUD/countdown excluded, export with audio of a real 10-min recording at 1080p (4.3x realtime): all PASS.
- **Defects found:** F6 export with audio failed on real recordings (**fixed, re-verified**); F8 window `pixel_size` mismatch (**fixed, re-verified with a 201x151 window: pixel_size [200,150] == video**); F9 completed window recordings could not be opened in core (**fixed on main badc4e4, re-verified**); F4 absolute home path in docs/status/editor.md (low, open).
- **Also verified live now:** hotkey-driven recording (start/pause/resume/stop), UI-driven editor sequence (split, delete, zoom, padding, undo/redo via menu), crash after autosave and crash with only the journal (edits restored on reopen), UI export with audio (1920x1080).
- **Not tested:** real camera/mic, Retina/multi-display, permission-revoked and low-disk live (deliberately not done: injected-fault tests only), mouse-level toolbar/editor clicking (self-tests call the same actions), reference observation of Screen Studio.
- **Go/no-go:** M1 (record -> edit -> export 1080p) works end to end for display and area recordings. **Window recordings are blocked by F9** until capture/core fix `display_name`; all other recording modes pass. M2 rows: 113 in FEATURES.md (38 verified, 47 integrated, 18 implemented, 10 limited, 0 todo). M3 hardening: long export, soak, recovery, sync verified; see section 9 for limits.

## 2. Automated suites
Run 2026-10-15 21:05 on main 97b9d82 outside any sandbox (machine under load: load average about 6 from other teams' runs).
| Suite | Command | Result | Skips (why) |
|---|---|---|---|
| Rust core | `CARGO_BUILD_JOBS=4 cargo test --manifest-path core/Cargo.toml` | 100 passed, 0 failed | 1 ignored (intentional) |
| Swift, whole package | `swift test --disable-sandbox -j 4` | XCTest 207 run, 0 failures; Swift Testing 501 tests / 99 suites passed; 40 s + 60 s | 10 XCTest skipped (live tests needing `YAPCAM_LIVE_PACKAGE`, hardware gates) |
| Render on Metal (strict) | `YAPCAM_REQUIRE_RENDER_HARDWARE=1 swift test --filter YapcamRenderTests` | 86/86 (Lead run 03:15) | none |
| E2E pipeline (fixture) | `scripts/qa/run-e2e.sh` | 11/11 | - |
| Live-recording tests | `YAPCAM_LIVE_PACKAGE=<pkg> swift test --filter LiveRecordingTests` | 4/4 on the real 10-min package (+ testAutoZoomFromRealClicks 1/1 on a drive-input recording) | need a real package |
| Crash recovery check | `scripts/qa/run-recover-check.sh <interrupted pkg>` | PASS (kill -9); fails on window packages because of F9 | needs a package |
| Privacy scan | `scripts/qa/privacy-scan.sh` | FAILED: 1 finding, absolute home path in docs/status/editor.md (F4) | - |
| Benchmark line (from the full run) | `RENDER_BENCHMARK` | 1080p 2.7x, 4K 0.75x realtime (synthetic source, now 120 frames at the new 60 fps default, no audio; run under load average ~6, NOT comparable with the earlier 6.3x / 1.9x at 30 fps/60 frames; re-measure on an idle machine) | - |
| UI self-tests | `--editor-selftest`, `--editor-reopen-check`, `--editor-export-selftest`, `--live-e2e hotkey` | all PASS (section 4) | - |

## 3. Definition of Done checklist (docs/TESTING.md)
| # | Check | Result | Evidence / owner |
|---|---|---|---|
| 1 | Toolbar shows, modes switch, no crash | PASS (controller level) | `--ui-record-selftest`, `--live-e2e` default/area/window/pause/hotkey drive the real controller; physical mouse clicking on the toolbar not automated |
| 2 | Record display + system audio + events -> valid package | PASS | section 4, verify-package ok |
| 3 | Pause/resume duration = active time, A/V in sync | PASS | 10.18 s + 14.02 s, 12/12 pairs, drift 2.8 ms |
| 4 | Cursor/click events at scripted times (+-50 ms) | PASS | 38/38, max 15.4 ms, 0.98 pt |
| 5 | Editor opens package; preview matches background/padding | PASS for display/area; **FAIL for window (F9)** | LiveRecordingTests, `--live-e2e` editor opened; window: core refuses the package |
| 6 | Manual zoom, cut, undo/redo exact | PASS | E2E testCutUndoRedoDuration, 300-edit no-drift, real 10-min edit test; UI menu actions via --editor-selftest |
| 7 | Autosave: kill -9 then reopen, edits intact | PASS | `--editor-selftest --crash-after-autosave` and `--crash-now` then `--editor-reopen-check`; recording kill -9 + recover PASS |
| 8 | Export 1080p MP4: duration +-1 frame, tracks present | PASS | 599.1 s vs 599.08 expected, video+audio, 4.3x realtime |
| 9 | Export vs preview frame diff small | PASS | 0.50/255 mean abs luma at 720p |
| 10 | A/V sync on 10-minute recording | PASS | 300/300 pairs, -15..+24 ms, drift 7.3 ms over 10 min |
| 11 | Failure paths: no mic/camera, missing media, low disk, permission denied, source lost | PARTIAL | no devices: unit/injected; missing media: E2E PASS; source lost live: PASS (window closed mid-recording -> failed(sourceUnavailable), 5.79 s package kept as interrupted); low disk and permission revoked: capture injected-fault tests only (not done live by design) |
| 12 | Yapcam windows absent from exported file | PASS | frames of the recording viewed; export derives from them |
| 13 | Privacy scan | FAIL (low) | F4: docs/status/editor.md home path (editor) |

## 4. Live-capture tests (signed build, main b5d1268 -> c504858, 2026-10-15 10:25-12:25, Mac mini M4, 1680x1050)
Method: the app's own launch flags (`--capture-selftest N [--target window:<id>|area:x,y,w,h] [--pause-after S]`, `--ui-record-selftest`, `--drive-input-selftest`, `--live-e2e`), started with `open -n -W` under `~/Movies/Yapcam/QA/.app-lock` (my shell itself has no Accessibility/Screen Recording grants). Analysis with `scripts/qa/verify-package.sh`,
`scripts/qa/analyze-sync.py`, `Tests/E2E/LiveRecordingTests.swift`.
| Test | Result | Evidence |
|---|---|---|
| Display record + system audio + events | PASS | 8 s package: HEVC 1680x1050, 470 frames, AAC audio, events.jsonl; verify-package ok |
| 4-min recording stability | PASS | status complete, 240.14 s, 13,838 frames, RSS flat 72 MB (sampled every 10 s) |
| 10-min recording + A/V sync (flash+beep every 2 s, `sync-marker.swift`) | PASS | complete, 600.08 s, 34,476 frames; 300/300 flash/beep pairs; offsets first/mid/last 2.5/-14.2/9.8 ms, range -15.2..24.1 ms (frame quantisation 16.7 ms), mean 12.2 ms, **drift 7.3 ms over 10 min**; RSS max 73 MB; package 97 MB |
| kill -9 mid-recording, then `RecordingSession.recover` (`scripts/qa/run-recover-check.sh`) | PASS | 25 s recording, app killed with SIGKILL: package left at status=recording; `interruptedPackages` lists it; `recover` -> status complete, 1 segment, 24.01 s (<= ~1 s tail lost); opens in core (24.01 s); screen.mov decodes with ffmpeg. App-level relaunch prompt (UI) not exercised |
| Interrupted recording tail readable (earlier 7.5-min runs killed externally) | PASS (indirect) | two runs killed by other processes (7.5 min); the partial fragmented MOV was still analyzable: 223/223 pairs, drift 1.3 ms; session stays status=recording (needs RecordingSession.recover, not run) |
| Open real package in core, cut/zoom/padding edits, undo/redo, save/reopen | PASS | testOpenRealRecording (duration 600.083 s == recorded) |
| Export vs preview frame diff (real recording, 720p, t=2 s) | PASS | mean abs luma diff 0.50/255 (threshold 6) |
| Export 1080p of real recording with edits and audio | **PASS after F6 fix** (was FAIL) | main 529f208: 10-min package, cut + zoom + padding + undo/redo + save, export 599.1 s (expected 599.08), 1080p video + audio, 4.3x realtime; reopened project keeps edits; tail diagnostics all OK |
| Window capture via `--capture-selftest --target window:<id>` (200x200 marker window) | PASS | video exactly 200x200, 13 frames/8.2 s (VFR, changes only on flash), luma 16..235 = only that window |
| Area capture via `--capture-selftest --target area:100,100,640,360` | PASS | video exactly 640x360, 350 frames, complete |
| Area capture (`--live-e2e area`) | PASS | 800x500 selection -> video 800x500, 241 frames, complete |
| Window capture (`--live-e2e window`) | PASS (minor F8) | Terminal 1627x1015 pt -> video 1626x1014 (even-size rounding); session.json pixel_size says 1627x1015 |
| Pause/resume (`--live-e2e pause`) | PASS | 2 segments 2.15 s + 1.93 s, pause excluded |
| Default flow via the UI controller (`--live-e2e`: toolbar, 3 s countdown, record 5 s, stop, editor opens, export with audio) | PASS (F6 fixed) | main c504858: editor opened on the new package, export state done (verified by Exporter reopen); earlier run on b5d1268 failed with decode error |
| Toolbar/HUD/countdown excluded from video (`--ui-record-selftest 6`) | PASS | qa viewed frames at 0.4 s (countdown phase) and 4.5 s (recording): none of the Yapcam windows visible; frames deleted (they show the desktop) |
| Pause + resume with A/V sync (`--capture-selftest 24 --pause-after 10` with sync-marker) | PASS | 2 segments (10.18 s, 14.02 s); 12/12 flash/beep pairs, offsets 4.1/15.2/6.9 ms first/mid/last, drift 2.8 ms |
| Scripted input vs events.jsonl (`--drive-input-selftest 10`, all permissions granted, launched with `open -n -W`) | PASS | 38 scripted events (34 moves, 4 clicks) all found; time error events.t - sent hostNs: min 0.40 / max 15.43 / mean 2.33 ms; position error max 0.98 pt; down=4 up=4 (`scripts/qa/compare-input.py`) |
| Cursor + click -> auto zoom -> export (same recording, `LiveRecordingTests.testAutoZoomFromRealClicks`) | PASS | 4 clicks -> 4 auto zooms (x2.0, 1.3 s, start 0.3-0.4 s before click), target = click point exactly; frame crop narrower mid-zoom; export 10.2 s video+audio |
| Source disappears (target window closed 6 s into a 12 s window recording) | PASS for capture; **recovery of window packages FAIL (F9)** | state failed(sourceUnavailable), package kept with status interrupted and 5.79 s of media; `recover` finalizes, but core cannot open any window package: `missing field display_name` |
| Completed window recording opens in core | **PASS after F9 fix** (was FAIL; retested on main badc4e4: session now has display_name, opens, edit+export 1080p with audio OK) |  (original failure: `Project.create` on a complete `--target window` package: `status(2, "missing field `display_name`")`; area and display packages open fine |
| Editor UI sequence via real menu/model actions (`--editor-selftest`): split, delete clip, add zoom, padding, undo/redo | PASS | clips 1->2->1, duration 8085 -> 2695 ms, zoom added, padding 48->72, undo/redo 72->48->72 |
| Source overlay + Start (`--drive-input-selftest 12 --source display`, main c1bf553) | PASS | overlay shown (1 window), recording started on Start, overlay gone while recording, stop -> package complete 12.19 s, editor opened; default countdown 0 (None) |
| Editor opens in front after Stop | **PASS after F10 fix** (was FAIL) | `--ui-record-selftest 5 --source display` on main 3dd0d3b: `editorOpened=true editorInFront=true` (LiveEngine.openEditor -> EditorBridge.bringEditorsToFront) |
| Scripted input on the new build | PASS | 47/47 events, time error 0.27-8.67 ms (mean 1.95), position <= 0.98 pt, 5 clicks down+up |
| Auto-zoom rule on a real recording (5 clicks every 2 s) | PASS | one merged range 2.176-11.390 s = first click -300 ms to duration -0.8 s, x2.0, auto, target = click point |
| Area / window / pause on the redesigned controller (`--live-e2e area|window|pause`) | PASS | 800x500 video; window video 1626x1014 with session pixel_size [1626,1014] (F8 fixed); pause 2.17 s + 1.85 s |
| Export option sets (library, `ExportOptionSetsTests`, 5 tests) | PASS | catalogs/defaults/quantisers, default MP4 h264 720p 60 fps, Both = paired h264 + hevc files, GIF 480p HQ and play-once (loop count 1 vs 0) |
| Copy to clipboard (library) | PASS | exported FILE on a private pasteboard, previous-exports list, missing file rejected |
| Inspector order and Cmd+1..0 (editor Swift Testing, model level) | PASS | InspectorSectionOrderTests / ReferenceAlignmentTests pass; no physical key presses |
| Global hotkeys posted from inside the app (`--ui-record-selftest 10 --hotkey-script ...`, main 97b9d82) | PASS for start/stop, marker, pause, resume; PARTIAL for pick and restart | all 15 combos registered, 0 refusals, every press logged `global=true`. Ctrl-Cmd-Return: idle -> recording and recording -> idle (package complete 4.72 s, editor opened in front). Ctrl-Opt-Cmd-F: markers 0 -> 1 while recording. Opt-Cmd-P: recording -> paused -> recording (expect OK both). Pick hotkeys Opt-Cmd-3/4/5: delivered, phase stays idle, but the following posted Return did NOT start a recording from the overlay, and Ctrl-Cmd-Return in window/area mode answers "Choose a window / Select an area to record first". Restart (Opt-Cmd-Backspace): the script stalls on its confirmation dialog (see F11) |
| F12 reproduction loop (`--ui-record-selftest 4 --after-recording save --save-to <file> --watchdog 120`, 20 runs, main 27d27e9, exclusive window) | PASS 20/20 | every run logged `saved file ... exists=true` (1.11-1.14 MB), no watchdog, no hang sample files, about 7 s per run |
| Hotkey full cycle with restart (`--hotkey-script "startStop,...,restart,..." --auto-confirm`) | PASS | start, marker (markers=1), pause (paused), resume, restart auto-confirmed ("Restart entire recording?") -> recording continues with markers reset to 0, stop -> idle; package complete |
| Window pick hotkey + Return | PASS | Opt-Cmd-4: window overlay shown; posted Return: idle -> recording; stop hotkey -> idle |
| Display pick hotkey + Return | **FAIL (F11)** | Opt-Cmd-3: display overlay shown (sourceOverlayWindows=1); posted Return: phase stays idle (expect:recording MISMATCH); Ctrl-Cmd-Return then starts a recording |
| Area pick hotkey + Return | **FAIL (F11)** | Opt-Cmd-5: area overlay active; posted Return: phase stays idle; Ctrl-Cmd-Return answers "Select an area to record first, or pick Display instead." |
| Other Yapcam instance vs hotkeys | checked | before each run a Carbon probe registered all 8 reference combos successfully (nothing else held them), so posted keys could only reach the test instance |
| After-recording choices (`--ui-record-selftest 6 --after-recording ...`, main 97b9d82) | PASS (create, widget, copy, save) | create: editor opened and in front. widget: quickExportWidgetVisible=true, editor not opened. copy: export state done, clipboard holds 1 file URL (1.43 MB mp4, in ~/Library/Caches/Yapcam/QuickExport). save with `--save-to`: file written, 1728x1080 H.264 + AAC, 6.2 s; 4 of 5 runs fine, 1 run hung after the package with no outcome line (F12, not reproduced in 4 retries) |
| Autosave then kill (exit 9) then reopen (`--editor-selftest --crash-after-autosave` + `--editor-reopen-check`) | PASS | save state clean before crash; reopened with clips=1 zooms=1 duration 2695 ms padding 72 |
| Autosave 30 s policy (main 01f05df, `--editor-selftest --crash-after-autosave`) | PARTIAL (F13) | the hook waited ~32 s and logged `autosave DID NOT complete` (save=dirty): its wait is shorter than the new 30 s autosave delay; the crash then left the journal and the reopen check PASSED (unsavedJournalPresent=true, clips=1 zooms=1 padding 72). Whether the 30 s save itself completes was not verified live |
| Kill with only the journal (`--crash-now` + reopen check) | PASS | unsavedJournalPresent=true; restore path recovers clips=1 zooms=1 padding 72 (state dirty = unsaved restore) |
| Editor export via the export model (`--editor-export-selftest`) | PASS | 1920x1080, 2.700 s (project 2.695 s), 1 audio track |
| Hotkey-driven recording (`--live-e2e hotkey`) | PASS | start, pause (paused), resume (recording), stop (idle); package complete |
| Odd-size window 201x151 (F8 re-check) | PASS | session pixel_size [200,150] == screen.mov 200x150; recording/.capture.lock removed after the clean finish |
| Permission revoked / low disk (live) | NOT RUN by design | no TCC reset, no disk filling; capture injected-fault tests cover both (SessionLifecycleTests, SegmentFailureTests) |

## 5. Performance (Apple M4, debug build unless noted)
| Metric | Value | Source |
|---|---|---|
| Export 1080p30, real 10-min recording with audio and edits | 599.1 s output in 138 s = **4.3x realtime** | qa, LiveRecordingTests |
| Export 1080p / 4K, synthetic source, 120 frames at 60 fps, no audio, machine under load | 2.7x / 0.75x realtime (earlier at 30 fps / 60 frames: 6.3x / 1.9x) | full-suite RENDER_BENCHMARK, 21:05; re-measure idle |
| Export 10-min synthetic with audio (render team) | 4.4x realtime, peak RSS 137 MB, A/V offset <0.05 ms | docs/STATUS.md |
| Export 30-min soak | 2.2x realtime, RSS growth -2.5 MB (no leak) | docs/STATUS.md |
| Preview with audio, 30 s | 1080p 58.3 fps, 4K 58.9 fps | docs/STATUS.md |
| Scrub latency (real window + Metal view) | median 16.5 ms, p95 20 ms | editor LiveWindowTests |
| Recording app memory | RSS flat 72-73 MB over 4 and 10 min | qa sampling every 10 s |
| Recording size / write rate | 97 MB for 10 min (static desktop plus a flashing square) = about 0.16 MB/s | qa |
| Recording frame rate | VFR HEVC, 57.5 fps average over 600 s (static desktop), 34,476 frames | qa |
| Scripted input latency | events.jsonl timestamp - delivery: mean 2.3 ms, max 15.4 ms | qa |
Not measured: real busy-screen content (static desktop only), release-build speed, thermal behaviour, 4K recording, disk write under load.

## 6. Feature matrix
From docs/FEATURES.md (113 rows): verified 38, integrated 47, implemented 18, limited 10, todo 0. Delta since the first audit (81 todo): all rows moved; live verification added REC-01/02/03/06/08/09/10/11/18, AUD-01, CUR-01/02, ZOM-01, EXP-08/01.

## 7. Findings
| ID | Severity | Owner | Repro | Status |
|---|---|---|---|---|
| F9 | HIGH (FIXED, verified on badc4e4) | capture + core | `--capture-selftest 6 --target window:<id>` then open the package in core (`YAPCAM_LIVE_PACKAGE=<pkg> swift test --filter LiveRecordingTests/testOpenRealRecording`) -> `missing field display_name` | open |
| F6 | HIGH | render + core | export real recording with audio over the final ~100 ms | fixed, verified on main 529f208+ (10-min export, UI default flow) |
| F8 | LOW | capture | window recording: session.json pixel_size 1627x1015, video 1626x1014 | fixed in 3b68bde, verified (201x151 window -> [200,150]) |
| F7 | MEDIUM | process | other processes killed two long runs | resolved by .app-lock rule |
| F10 | LOW | ui | after Stop the editor was not in front | fixed, verified on 3dd0d3b |
| F11 | LOW (narrowed) | ui | hook (RESTART PART FIXED, verified 27d27e9): `--hotkey-script "startStop,wait:3,restart,wait:1,return,..."`: after the restart hotkey the script produces no further log lines (stalls) - the confirmation dialog probably blocks the script's own `return` step; also pick hotkeys + `return` do not start from the overlay | open (hook limitation or real: ui to check whether the overlay window is key so a real Return starts recording) |
| F12 | LOW | ui | `--after-recording save --save-to <file>` hung once (process alive 9 min, killed by qa) | not reproducible: 20/20 pass on main 27d27e9 with ui's off-main-thread export + watchdog; closed unless it recurs |
| F13 | LOW | ui (hook) | `--editor-selftest --crash-after-autosave` waits about 30 s for save=clean, but autosave now fires 30 s after the last edit: the wait must be >= 45 s (or the hook should trigger the autosave) | open |
| F4 | LOW | editor | privacy-scan flags an absolute home path in docs/status/editor.md | open |
Details and repros: docs/status/qa.md.

## 8. Reference observation (morning session with the user)
Checklist of Screen Studio panels/menus to observe, values captured, rows updated.

## 9. Not tested / limitations
Link docs/KNOWN_LIMITATIONS.md; list anything new.

## 10. Privacy and licence
Scan results (`scripts/qa/privacy-scan.sh`), THIRD_PARTY.md (approved) and THIRD_PARTY_NOTICES.md status, confirmation that no reference assets are included.

## Round 3 (2026-10-16, release candidate): programmatic checks only

**Decision (user, 2026-10-16):** the round closes WITHOUT real mouse/keyboard tests. QADriver (CGEvent + screenshot driver, `scripts/qa/qadriver/`) never received Accessibility / Screen Recording permission, so **nothing below is "verified by real interaction"**. Every row is *programmatic*: the signed app's own launch-flag self-tests (`--ui-record-selftest`, `--hotkey-script` posts the global shortcuts and Return/Escape through the HID tap from inside the app, `--capture-selftest`, `--editor-selftest`, `--editor-export-selftest`, `--drive-input-selftest`) plus outside verification of the outputs with ffprobe/ffmpeg.

Environment: Mac mini M4, one non-Retina 1680x1050 display, no camera, no microphone. Build: `scripts/build-app.sh` at main 3c6279f (configuration as the script default), signed "Yapcam Dev Signing", launched only via `open -n -W build/Yapcam.app --args ...` under the app lock. Runner: `scripts/qa/round3-wrapup.sh <block>` (blocks f11, f11-display-repeat, flows, interrupt, src-display, cap-display); logs in `~/Movies/Yapcam/QA/round3/` (local only). **Environment confound:** a Screen Studio picker overlay (PID 92591, not mine) was on screen during all runs, so it appears in every display recording; frame checks therefore cannot prove the absence of Yapcam's own overlay (none of Yapcam's overlay windows was seen in addition to it).

| # | Item | Procedure (programmatic) | Result |
|---|------|--------------------------|--------|
| Q1a | Display pick hotkey (Opt-Cmd-3) -> Esc -> pick again -> Return -> record -> stop, editor to front | `--hotkey-script`, 3 runs + 6 repeats | Esc cancels 9/9 (phase idle, overlay gone); Return starts 7/9. The two misses were the first run of a batch (see F16); editor opens in front after stop 9/9 |
| Q1b | Window pick (Opt-Cmd-4) same sequence | 3 runs | Esc 3/3, Return starts 3/3, editor in front 3/3 |
| Q1c | Area pick (Opt-Cmd-5): Esc cancels, start without selection | 3 runs | Esc cancels 3/3 (overlay gone, toolbar usable, start says "Select an area to record first"). A drag + Return could not be posted (needs real input) -> `--source area` confirm hook 3/3 starts, editor in front 3/3. **Area drag + Return: not done** |
| Q1d | Focus case (other app frontmost, hotkey, Return) | the runs above start with Terminal frontmost | 9/12 Return starts; see F16 |
| Q1e | Overlay absent from video | frame extraction | inconclusive, see confound above |
| Q2 | Flow A equivalents: record display with pause (24.4 s), split + delete, export, outside check | `flows` block | export 1728x1080 h264+aac, duration 8.167 s vs project 8.134 s; frames carry a running timecode (`scripts/qa/timecode.swift`): last exported frame T+9.12 s, cut at source 8.134 s -> no frame from the removed section; with a 440 Hz tone playing the audio runs to the cut at -21 dB (no drop-out). Mic step: untested (no hardware) |
| Q4 | Flow C equivalents: edit, autosave, reopen, re-export, crash + reopen | `flows` block | edits survive reopen (PASS), re-export of the edited package 8.167 s, the first export (24.43 s file) unchanged, crash after autosave -> journal/reopen PASS (autosave completes inside the 30 s wait: F13 closed). Cmd-Q, File > Open, recent list, keyboard/button undo-redo: **not done** (the self-test calls the menu actions) |
| Q3 | Flow B equivalents: zoom from 6 scripted clicks | `--drive-input-selftest 14`, `LiveRecordingTests` | 6 clicks -> one merged zoom x2.0 centred on the first click, edit+export OK, export-vs-preview frame diff test passes; dragging zoom bars, inspector, background/camera UI: **not done** |
| Q5a | Low disk: recording refuses below 1 GB free | 400 MB APFS image, free 12 MB | refused at start with "Recording stopped because less than 1 GB of disk space remains", no package, no hang |
| Q5b | Disk fills during recording | 1.5 GB image, a `dd` filling it 10 s into the recording | capture fails with `diskFull` (no hang, no crash), package kept (3 MB), `RecordingSession.recover` -> complete, 9.9 s |
| Q5c | Export onto a full volume, then re-export | 30 MB free, then freed | export fails at once with state "Disk Full", no partial file; re-export after freeing 24.43 s, 7.57 MB OK |
| Q5d | kill -9 of my own app PID mid-recording | `interrupt` block | package recovered, 8.015 s |
| Q5e | Export cancel -> re-export | no launch flag | not independently tested; render's perf run reports "in order" |
| Q5f | Permission revocation, VoiceOver, AX audit | - | **not done** (no real-input permission; user decision) |
| Q6 | Screen Studio comparison | - | **not done** (same reason; also see section 8) |

Observations: in the harness the disk-full failure reads "Cannot stop in state failed(... diskFull ...)" because the self-test calls stop after the failure; the user-facing wording on that path was not seen. The second `--editor-selftest` undo/redo line prints FAIL only because padding is already 72 (setting it again is a no-op): script artefact, not a defect.

Defects: **F16** (ui, low, intermittent): the first Return after a hotkey-opened display overlay in a fresh launch did not start recording in 2 of 9 runs (phase stayed idle for 2 s; a later startStop worked). Steps: `scripts/qa/round3-wrapup.sh f11` and `f11-display-repeat`, logs `f11-recordDisplay-1.log`, `f11-disp-rep-1.log`. Possibly caused by the Screen Studio overlay holding the keyboard; re-run when no other recorder UI is open. After a fix: re-run exactly `f11-display-repeat`.

Not done: everything that needs a person: real mouse/keyboard flows, area drag, Cmd-Q relaunch, recent list, zoom/trim dragging, background/camera UI, permission loss, VoiceOver, AX audit, Screen Studio comparison, microphone, camera.

## Round 4 (2026-10-17, night): programmatic checks on main c6ae74a

Environment: Mac mini M4, macOS 26.3, one 1680x1050 display, no camera, no microphone. Debug build, Rust core rebuilt from the same tree
(a stale core library had made core's own blur test fail until relinked: delete the xctest bundle after `build-core.sh`).
These are programmatic checks (core project, render exporter, ffprobe, frame comparison). Nobody operated a window, menu or shortcut.
The signed app was NOT launched: a Yapcam instance of the user (pid 9035) was running and the F16 batch posts real global shortcuts that it would receive.

| Check | Procedure | Result |
|---|---|---|
| Blur mask in export (GAP-ED-16) | `Tests/E2E/Round4Tests.swift` testBlurMaskIsBlurNotOpaque: fixture project, `insertTimelineItem(.mask, kind blur)` 1.0-3.0 s, export 720p/30, frame at 1.5 s vs unmasked export, plus 0.3 s | PASS. Mask area differs (mean abs diff 14.6 of 255), outside the mask 0.2, texture kept (std 66.9 vs 76.8, an opaque cover would be near 0), frame before the mask unchanged |
| Cursor sets Original / Touch in export (CUR-06/17) | testCursorSetsOriginalAndTouchInExport: `cursor.set_id` unset / "touch" / "coral" vs a `cursor.visible=false` export, frames at 1.0 and 2.0 s | PASS. Each set draws a cursor (4.1k-8.3k px differ from cursor-less), original vs touch differ by 12.4k / 13.8k px, original vs coral 7.8k / 7.3k px. `cursor.style`/shape/size alone changed nothing in the export when no set is chosen (recorded artwork is used); sets are the working control |
| VFR export (GAP-RND-9) | testVariableFrameRateTimestamps: same project exported constant-rate and with `variableFrameRate`, `ffprobe -show_entries packet=pts_time` | PASS for validity: strictly increasing PTS, 150 frames, last PTS 4.967 s in both. Not shown: a saving on duplicate frames (synthetic source has none) |
| Autosave off / on | Existing unit tests, not mine: `autosaveSwitchStopsTheTimerButNotSaveOrClose`, `autosaveDefaultsOnPersistsAndReachesTheEditor` | PASS (8 tests with the queue ones, 6.3 s). Off: no timer save, Cmd-S saves; on: debounce saves. Not exercised in the running app |
| Export queue readouts / remembered contexts | `queuePhasesReachTheModelAndClearWhenDone`, `realExportFinishesAndClearsTheQueueStatus`, `dialogAndQuickExportRememberSeparately` | PASS as unit tests. Open: `ExportModel.remember(in: .quick, ...)` is never called by the app (only `.dialog` in EditorDocument.swift:40), so quick-export settings are not remembered |
| F16 (display pick + Return) | not re-run | OPEN. ui also did not run it. Needs a free app slot (no other Yapcam instance): `scripts/qa/round3-wrapup.sh f11-display-repeat` |
| F17 / F18 (scrub latency, 4K export speed) | took Lead's results from `~/Library/Logs/Yapcam/render-round4/*/result.json` | No new numbers: all three result files are `"status": "blocked"` ("Another session owns Yapcam" / "No Cocoa application session is visible"). Latest numbers stay those from main b1859a4 (render/Lead): scrub p95 232 ms (p50 149 ms) vs target 150 ms, 4K export 0.98x vs target 1.3x. Both OPEN-medium |

Also run: `swift test --filter Round4Tests` (3 tests) green; FEATURES.md updated (GAP-ED-16, CUR-06, CUR-17 verified; GAP-RND-9, GAP-UI-10 integrated; GAP-RND-4 stays partial; counts: verified 29, integrated 70, partial 7).
Still not done (no real input / hardware): pointer-driven editor flows (mask handles, carousel, settings), area drag, VoiceOver, permission loss, camera and microphone.

## Round 5 (2026-10-17, night): parity pass on main abe4e6a, nothing live
Environment: Mac mini M4, debug build, merged tree abe4e6a, Rust core rebuilt and test bundle relinked. The user's Yapcam instance was running, so no app was launched (no self-test, no hotkeys).

| What | How | Result |
|---|---|---|
| Swift Testing | `swift test --disable-sandbox -j 6` on abe4e6a | 741 tests in 153 suites passed |
| XCTest incl. E2E Round4Tests (blur, cursor sets, VFR) | same run; last count I captured: 270 on a96173e. Lead reports 276 on abe4e6a | Lead's number; my abe4e6a XCTest count not captured |
| Rust core | Lead reports 133 on abe4e6a | not re-run by qa |
| Parity matrix | 135 rows from reference-spec + website features, states from code reading and the teams' R5 tables | 117 match, 12 gaps, 6 out of scope |
| Privacy scan | scripts/qa/privacy-scan.sh | ui test file Round5Tests.swift uses fake /Users/a paths (false positive, request to ui) |

Parity score (match/total): Recording flow 39/44, Settings 7/9, Editor 44/50, Project/timeline 5/6, Export 8/10, Project handling 6/6, Website 8/10; all 117/135 (117/129 without out-of-scope rows). "Match" is a code/test reading, not user verification.

Not verified: any live app behaviour, hardware (camera, microphone), real input, VoiceOver, Screen Studio side-by-side, F16, F17 (p95 232 ms vs 150 ms), F18 (4K 0.98x vs 1.3x), the HW acceleration toggle (stored, not wired).

## Update log (keep current with each Lead integration)
| Date | Main | What changed in this report |
|---|---|---|
| 2026-10-15 | b90ee0d | Structure only; Metal 86/86, M3 long-export/soak, fresh-checkout build recorded in docs/STATUS.md; live capture still blocked (TCC) |
| 2026-10-16 10:25 | 27d27e9 | F12 loop 20/20 pass; F11 restart verified with --auto-confirm; Window pick + Return starts recording, Display and Area pick + Return do not (F11 narrowed) |
| 2026-10-15 21:20 | 01f05df | 30 s autosave: journal recovery PASS, autosave-complete wait in the hook too short (F13) |
| 2026-10-15 21:10 | 97b9d82 | Suites re-run: Rust 100, XCTest 207 (0 failures), Swift Testing 501; render benchmark lower but not comparable (60 fps default, 120 frames, machine under load) |
| 2026-10-15 20:55 | 97b9d82 | Hotkeys live (start/stop/marker/pause/resume PASS; pick+restart partial, F11) and after-recording create/widget/copy/save PASS (F12 one intermittent hang) |
| 2026-10-15 19:55 | 3dd0d3b | F10 verified fixed (editor in front after Stop); hotkey and after-recording live checks blocked on missing in-app hooks |
| 2026-10-15 19:45 | c1bf553 | Live DoD re-run on the integrated gap list: overlay+Start, scripted input, auto-zoom rule, area/window/pause, export option sets, clipboard, inspector order PASS; F10 editor not in front (low); hotkeys and after-recording buttons not run live |
| 2026-10-15 14:00 | badc4e4 | F9 fixed and verified (window package opens, edit+export OK); default live flow still OK after ui/editor redesigns |
| 2026-10-15 13:00 | 511f831 | F9 retested: still fails; only the decision doc is on main |
| 2026-10-15 12:40 | 3b68bde | Final handover pass: suites re-run (Swift 340 + XCTest 129, Rust 68), editor UI rows PASS (autosave/kill/reopen, export), hotkeys PASS, F8 verified fixed, F9 still open |
| 2026-10-15 12:30 | fc29d18 | Permissions granted: scripted input vs events PASS (max 15 ms / 0.98 pt), auto-zoom from real clicks PASS |
| 2026-10-15 12:00 | 529f208 | F6 fixed and re-verified (10-min export with audio); window/area via selftest targets PASS; pause A/V, toolbar exclusion PASS; scripted input BLOCKED on Accessibility |
| 2026-10-15 11:10 | b5d1268 | Section 4 filled with live results (display, 4/10-min, A/V sync, export diff, F6 tail-export failure) |
| 2026-10-15 | 7d545a1 | Editor export sheet now exposes MP4/MOV/GIF, 4K, 24 fps, quality (EXP-02/04 integrated); no new test results by qa |

- 2026-10-16: Round 3 section added (programmatic only; real-input tests not possible, QADriver never granted).
- 2026-10-17: Round 4 section added (blur, cursor sets, VFR, autosave/queue unit tests; F16 and F17/F18 not re-measured, reasons in the table).

- 2026-10-17: Round 5 section added (parity matrix, suites on abe4e6a, nothing live).
