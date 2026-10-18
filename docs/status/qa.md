R7 qa-4 integration-2 59fd0bc | suites green (Swift Testing 958, core 162); live under app lock ui-record display/window/area x create + drive-input-selftest 2 each = 8/8 PASS, no crash, user's instance untouched; FEATURES section S status update + recount deferred to the final pass after integration 3 (06:30)
R7b qa | KNOWN_LIMITATIONS now lists B-18/B-19/Quick Look (not in 0.11.0), disconnect placeholder, B-14/B-15 hooks; no open requests addressed to qa in other status files; next: FEATURES section S status update at integration 2 (~04:45), soak 05:30
R7 qa-3 integration-1 fff0368 | built app, suites green (Swift Testing 941, core 162, yapcam-mcp 12); live under app lock: ui-record-selftest display/window/area x create + drive-input-selftest, 3 runs each = 12/12 PASS, no new crash reports, recordings deleted, user's instance untouched | P0 items checked by code wiring + named tests (Dock menu, picker-first start/stop, camera preview in take, speaker notes, Save/Open Recent, timeline menus, edge trim, cut markers, cmd-C frame): all wired and tested; NOT live-verified: real Dock click, global cmd-ctrl-return (not posted while user's instance runs), right-click menus, camera | findings: editor palette label says shift-cmd-C for Copy frame but cmd-C is the key (both work), cosmetic; ui: Camera-disconnected placeholder not done (declared)
R7 qa-1 DONE 01:05 | reference answers in ~/yapcam-fleet/round7/qa-reference-answers.md: springs+simulated settle times, BS-3 use Smooth 170/50/3 clamped (settles 0.93 s = measured ~1 s), BS-4 reference has one screen spring for zoom+pan, BS-1 smoothing on by default (Smooth 470/70/3), BS-5 NOT confirmed in the reference -> core skip, S-04 Web/Web(Low) disabled at 4K (shown, not hidden); unknowns marked; deeper bundle decode refused by permission classifier, not worked around
R7 qa-2 DONE 01:20 | FEATURES.md: 9 overstated rows corrected to partial (ANI-03, PRJ-02, CUR-03/04, ANI-01, ZOM-06/07, CAM-07, EDT-08), AUD-10 note fixed (keyterms/language wired), section S with 88 research rows (REC B-01..19, CZ BS-1..16, CAM, EXP S-01..15, EDIT S-EDT), counts 276 rows: 70 integrated, 106 partial, 7 excluded; recount at READY R7
R7 prep 00b7e27 | read handoff 2026-10-18; rebuilt debug app, suites on merged tree: Swift Testing 840 passed, XCTest 288 executed, 17 skipped, Rust core 162, tools/yapcam-mcp 12, all green (flaky tests named in the handoff are ui/editor-owned, none flaked in this run); THIRD_PARTY.md now covers tools/yapcam-mcp crates (same 12 as core by lock diff), user-installed claude CLI (not bundled) and tools/eval Python/Pillow; tools/eval compiles (py_compile) but not run (costs real Claude calls) | next: tasks.md when it lands
R6 follow-up 0f01e40 | chime crash fix 1a9c309 re-checked on rebuilt debug app (M4, app lock, open -n -W, user instance untouched): drive-input soak 40/40 pass, no new .ips (before fix: 19/20 and 1 SIGSEGV; the race was 1 in 260, so 40 clean runs are consistent with the fix but do not prove it; the fix's own regression test is ui's) | suites on 0f01e40: Swift Testing 783 passed, XCTest 278 executed 0 failures (16 skipped) | no restyle of laptop-owned design files
READY R6 f5f9101+qa | click-path audit (19 untested button targets + untested timeline/RectEdit/AreaSelector/hotkey-recorder gesture paths; requests R6-QA-E1/E2/E3/U1/U2), soak 240/240 ui-record pass + 19/20 drive-input with 1 NEW crash (SIGSEGV in -[AVAudioPlayer finishedPlaying:], chime player, routed to ui R6-QA-U2 high), parity re-verification: A3.3 downgraded to partial, matrix 126/135 match (126/129 excl. out of scope) | debug build 11ce970, M4, app lock + open -n -W, user instance untouched; programmatic only, no repo test added (my files cannot reach the private view code); docs: TEST_REPORT Round 6, FEATURES R5-12 (188 rows, 10 partial)
READY R5 a12448c+qa | final recount on main a12448c: 127/135 match (127/129 excl. 6 out of scope); per area Recording 41/44, Settings 7/9, Editor 49/50, Timeline 6/6, Export 9/10, Handling 6/6, Website 9/10; 2 open, both ui: B.Shortcuts (Editing keys still read-only, SettingsWindow.swift:194; editor KeyBindings API ready) and B.Advanced (editor hook EditorWindows.hardwareEncodingEnabled landed, EditorWindows.swift:33, but nothing in YapcamUI assigns it: one line in AppDelegate) | merged tree, debug, M4: qa ran Swift Testing 747 passed, XCTest 277 executed 0 failures (16 skipped), Rust core rebuilt; nothing live (user instance running); matrix = code reading | docs updated: FEATURES section R, TEST_REPORT Round 5, KNOWN_LIMITATIONS
R5 04:25 9c67775 | qa: matrix recounted on main 9c67775: 113/135 match (129 excl. out of scope 6), 16 mismatch, all class a; list in ~/yapcam-fleet/round5/remaining.md; suites not re-run after this merge, app checks blocked: user instance running | next: suites on next integration, FEATURES/TEST_REPORT at close
READY R4 0737f0f | main c6ae74a, debug, M4, programmatic only (no app launch: user's Yapcam pid 9035 running): E2E Round4Tests blur mask (diff 14.6 inside / 0.2 outside, not opaque), cursor Original/Touch/coral differ in export, VFR PTS valid (no duplicate-frame saving shown); autosave + queue readouts = existing unit tests pass; FEATURES ED-16/CUR-06/CUR-17 verified, RND-9/UI-10 integrated, RND-4 partial (quick remember() unwired); OPEN: F16 not re-run (needs free app slot, ui neither), F17/F18 no new numbers (render result.json all 'blocked'; stay 232 ms / 0.98x open-medium) | swift test --filter Round4Tests 3/3 + 8 unit tests green
READY RC 0.9.0 qa (freeze 22:10): nothing new beyond the FEATURES audit and round-3 wrap-up below; branch team/qa at the commit after 2e53e03. Open items for RC notes: F16 (ui, low; Return fix landed, NOT re-run live: needs `round3-wrapup.sh f11-display-repeat` with no Screen Studio overlay), F17 scrub latency open-medium (render, main b1859a4, synthetic 4K60 per render: p95 232 ms, was 466; p50 149 ms; reported by render, not re-measured by qa), F18 4K export 0.98x open-medium (render, same source), F4 home-path text in docs/status files, unwired GAP-CAP-1 / GAP-CAP-6 / AUD-10 keyterm+language pickers. Not done: real-input flows, area drag, VoiceOver/AX audit, permission loss, Screen Studio comparison (user decision / no hardware).
READY FEATURES audit vs main 63e239b: 176 rows normalised (verified live 21, verified 26, integrated 68, implemented 33, partial 12, limited (no hardware) 10, excluded by user 6; extra 8 listed in section M). Stale rows fixed with git-grep evidence. REALLY unwired: GAP-CAP-1, GAP-CAP-6, AUD-10 keyterms/language hooks. Round-3 evidence (F13/F14/perf/qa programmatic) added. No row verified by user interaction.
READY round3 qa: main 3c6279f, signed build, programmatic only (no real input, user decision). F11 Esc/Return pass 28/33 incl. window 3/3, display 7/9 (F16 low), area Esc 3/3 + confirm hook 3/3 (drag untested); Flow A/C equivalents + low disk + disk-full recovery + kill -9 recovery + export checks outside the editor: pass. Not done: real input, area drag, VoiceOver/AX, permission loss, Screen Studio comparison. See TEST_REPORT "Round 3".
REQUEST (Lead): Screen Studio picker overlay (PID 92591) was on screen during my runs; close it and I re-run f11-display-repeat for F16.

READY c45398b qa: F12 20/20 pass, F11 narrowed (display/area pick+Return), exclusive window released
READY 930128d qa: scripted input + auto-zoom verified live F9 window packages
READY b6bf19b qa: pause A/V + toolbar exclusion verified live; drive-input needs Accessibility
READY 769e499 qa: live QA results (TEST_REPORT section 4), findings F6/F7


## R6 click-path audit (qa, main 11ce970; method: every `Button`/gesture/key handler in YapcamEditor and YapcamUI vs. test sources; "tested" = a test calls the same function the closure calls, which is weaker than driving the closure)

Untested action targets found by script (closure calls a function no test mentions):
- editor Inspector.swift:412 Duplicate (`duplicateSelectedZoom`); :528/:535/:538 silence suggestions OK/Dismiss (`dismissSilences`); :697 Remove motion (`removeRegionKeyframes`); :860 Open audio library folder (`revealUserMusicFolder`); Transcript.swift:120 export formats (`chooseTranscriptExport`); ExportSheet.swift:117 Copy again (`copyAgain`); EditorChrome.swift:152/164/170 preset Create/Rename/Remove (`promptName`, `removePreset`).
- ui SourceOverlay.swift:259 Custom size, :260 Save current size, :274 Ignore this window, :282 Adjust recording area; SettingsWindow.swift:275 Export diagnostics; PostRecording.swift:410 and RecentProjects.swift:181/210 Show in Finder.

Gesture/key paths with NO test at all (the class that hid the scissors bug):
- editor TimelineView.swift:352-450 `timelineDrag` + `begin(at:)` (private `DragKind`, decisions depend on lane geometry, selection, `cutToolActive`, modifier keys): click routing for scrub, zoom create, zoom/layout/highlight select/move/trim, multi-select, typing popover, scissors on clip/zoom/layout/highlight. commit fcd6238 (scissors on zooms) shipped with no test; LayoutTests.swift:44 only covers the clip case through the model. Repro for a likely UX bug: with the scissors active, click an unselected layout or highlight lane item: `begin` only cuts when `model.selection` is already that item (TimelineView.swift:404-406), so the first click selects and drags, the cut needs a second click (zooms and clips cut on the first click).
- editor Background.swift:130 inset-origin pad drag; EditorView.swift:77 option-drag pan; :171 zoom focus drag (model `previewFocus` is tested, the point mapping in the closure is not); :233 RectEdit overlay corner/move hit logic (no test mentions RectEdit); Transcript.swift:137 double-click word edit; CommandPalette.swift:109 click row.
- ui AreaSelector.swift:173 mouseDown create/move/resize decision (`hitHandle`), SourceOverlay.swift:338 click-to-pick window (`start(w.id)`), SettingsWindow.swift:322/353 hotkey recorder key monitors, SourceOverlay.swift:358 and RecordingController.swift:533 `keyDown` (SourcePicker.escape is unit-tested, the NSView key routing is not).

REQUEST editor (R6-QA-E1): extract the timeline click decision into a pure function (e.g. `TimelineHitRouter.route(point:, layout:, geometry:, selection:, cutToolActive:, modifiers:) -> Action`) and test every lane x cutToolActive x selection combination, including scissors on an unselected layout/highlight (should cut on the first click, like zooms).
REQUEST editor (R6-QA-E2): same for RectEdit (corner/move hit) and the focus/inset pads: test the point -> value mapping, incl. drag outside the view and zero-size geometry.
REQUEST ui (R6-QA-U1): extract `AreaSelector` mouseDown decision (resize handle / move / create) and the hotkey-recorder key handling into pure functions with tests; add one test per unlisted menu action above that calls the real closure target.


### R6 soak (qa, debug build of 11ce970, M4, app lock, `open -n -W`, user's own instance untouched)
`scripts/qa/round6-soak.sh 20`: `--ui-record-selftest 4 --source display|window|area --after-recording create|widget|copy|save` 12 combos x 20 = 240/240 PASS (pass = "selftest ok" line, no "failed" line); `--drive-input-selftest 4 --source display --after-recording create` 19/20 (run 6 crashed). Not counted as user interaction. The copy runs overwrote the clipboard.
NEW CRASH Yapcam-2026-10-17-123624.ips (copy kept outside the repo in ~/Movies/Yapcam/QA/round6/): EXC_BAD_ACCESS SIGSEGV at 0x131 on the main thread; frames: `AVAudioPlayerCpp::DoAction` <- `-[AVAudioPlayer stop]` <- `-[AVAudioPlayer(AVAudioPlayerPriv) finishedPlaying:]` <- `__NSThreadPerformPerform` <- run loop. Happened ~4 s into recording (probe log ends at "script events=11"), i.e. when the stop chime/start chime finished. Only AVAudioPlayer users in Sources: ChimePlayer.play (Sources/YapcamUI/Recording/StartSound.swift:113-121) and the editor music preview (Sources/YapcamEditor/Music.swift:205). Likely cause (not proven): ChimePlayer.play holds the player in a local; when the caller's time limit cancels the task the `Task.sleep` throws, the function returns, the player is released while AVFAudio still has `finishedPlaying:` queued on the main run loop. 1 in 260 runs, so it is a race.
REQUEST ui (R6-QA-U2, high): in ChimePlayer.play keep the player alive until `finishedPlaying` ran (delegate + continuation), call `player.stop()` on the main thread before releasing it, and make the cancel path do the same; regression test with a fake CuePlayer that cancels mid-play is not enough, so also add a loop test that plays and cancels 200 short chimes in-process (crashes without the fix if the race is real).
REQUEST editor (R6-QA-E3, low): Music.swift:205 same pattern: `stopMusicPreview` stops and releases the player; give it a delegate that clears `musicPlayer` on finish so a release never races finishedPlaying.

## R5 parity matrix

REQUEST ui: Tests/YapcamUITests/Round5Tests.swift:314-316 uses fake home-style fixture paths; privacy-scan flags them (false positive). Use `/tmp/fixture/...` style paths so the scan stays clean.
 (qa, 2026-10-17 ~02:20, main 10aaca6 + round 4)
Source: reference-spec.md (A1-A9, B, 2a, 5, 3, 4) + website features.txt. One row per reference item; owner = team that must fill/close it.
States: **match** = Yapcam value/behaviour found equal in code (evidence in last column; still not user-verified), **mismatch** = found different, **missing** = not found, **unaudited (owner)** = qa could not decide from code alone, owner audits in its own "## R5 parity", **out of scope** = cloud/device frames/iPhone/updater.
Own artwork/names are allowed to differ (wallpapers, cursor sets, sounds, preset names); structure, ranges, defaults and option lists must match.
qa cross-check is a code/grep reading, not a run of the app; owner verdicts are taken from the teams' own '## R5 parity' tables on main a96173e (code reading, not live); where a team table is silent the row says so.

### Requests from qa (mismatches found by cross-check; owner decides, details in table)
- **core (defaults in core/src/model.rs):** background default 'solid' (ref wallpaper) E4.1; background blur 24 (ref 0) E4.5; padding 48 px, ref 10 % E4.6; screen radius 18 (ref 16) E4.7; shadow style default classic (ref directional) E4.9; click effect default 'ring' (ref none) E5.7; cursor tilt default 1.0/static (ref velocity 0.5), remove_shakes/optimize_types default false (ref on/on) E5.9/E5.10; camera mirrored default true (ref off), overlay size 0.22 / position .82,.78 (ref 0.5 / bottom-right) E6.2/E7.2; caption growth 'full' (ref expanding) and size E8.2; animation springs 250/28/1 (ref 125/12/1.5 migration, presets Focused 250/40/2.25, Smooth 170/50/3) E11.1; mask default kind highlight, dim 0.4 (ref 0.5) E13.3; inset colour white (ref #888888, alpha .25) E4.8. Each needs an existing-project migration decision (do not change saved projects).
- **editor:** cursor size 16-128 slider (E5.2), wallpaper categories + favourites + hue slider/randomize/preset grid (E4.2/E4.3), avoid-empty-area toggle (E6.5), fullscreen-camera / screen-only per-range layouts (E6.6), Reel mode preview (W3), Settings tab order (ui) B.order.
- **render:** wallpaper library 12 own presets / 3 categories vs 9 categories + favourites (E4.2); bundled background music tracks by 4 genres (E9.1).
- **ui:** tab order Experimental before Storage? (B.order); super-resolution default quality vs off (B.Experimental); picker rows A1-A9 unaudited.

| ID | Reference behaviour / value | Owner | State | Yapcam now (qa cross-check) |
|---|---|---|---|---|
| A1.1 | Picker bar: source modes Display/Window/Area/Device, input devices camera/mic/system audio, recent-projects + gear buttons, close x at left | ui | match (ui table; not run live: user instance running) | RecordingPicker exists (YapcamUI); layout order not compared |
| A1.2 | Recent projects panel toggled from picker, choice persisted (default off) | ui | match (ui table; not run live: user instance running) | FEATURES REC/UI rows; persistence key not checked |
| A1.3 | Update banner over picker | ui | out of scope | needs updater/cloud: out of scope |
| A1.4 | Unfinished-recording recovery button in picker + File > Recover recording | ui | match (ui table; not run live: user instance running) | AppDelegate.offerRecovery at launch (alert Recover); picker button / File menu entry not found |
| A1.5 | Esc clears selected mode, Esc again closes picker | ui | match (PickerSupport.swift:29 SourcePicker.escape two-stage, unit-tested; live pending) | F16: Esc cancels 15/15 in qa runs; 'clear mode first, then close' two-step not verified |
| A2.1 | Display mode: auto-select with one display; multi-display overlay with hover highlight; card shows name, WxH, '• N FPS', start button; right-click lists displays | ui | match (ui table); capture lists verification R5-CAP-UI*, hardware items untested (no camera/mic) | single-display hardware only; card content not compared |
| A2.2 | Window mode: highlight window under cursor, card with app/title + editable size field + Resize; filters system/own windows; click selected again deselects | ui | match (ui table); capture lists verification R5-CAP-UI*, hardware items untested (no camera/mic) | window pick Return 3/3 (qa); size field not checked |
| A2.3 | Window context menu: Bring to front, Ignore this window, Reset ignored windows, Adjust recording area..., Select window submenu, Record entire display | ui | match (ui table); capture lists verification R5-CAP-UI*, hardware items untested (no camera/mic) | SourceOverlay.swift:251 has Ignore this window; other entries not verified |
| A2.4 | Window resize presets 16:9/4:3/9:16/16:10/Square/Custom + save/delete sizes (Accessibility resize) | ui | match (ui table); capture lists verification R5-CAP-UI*, hardware items untested (no camera/mic) | gear menu resize exists? owner to audit |
| A2.5 | Area mode: 150x150 min with message, drag/resize/move, arrows 1px, Shift 10px, Cmd resize 1px, Cmd+Shift 10px, Esc cancels | ui | match (ui table); capture lists verification R5-CAP-UI*, hardware items untested (no camera/mic) | GAP-UI-6 partial in FEATURES; drag untestable (no real input) |
| A2.6 | Area toolbar: Position/Size numeric fields, aspect lock Any/16:9/4:3/1:1/3:4/9:16/custom, save/delete dimensions | ui | match (R6: AreaSelector.swift:385-399 save/delete dimensions; AreaGeometry.saving tested Round5Tests.swift:69) | GAP-UI-6 custom ratio landed (ui-final); saved dimensions not verified |
| A2.7 | Device (iOS) source mode | ui | out of scope | device frames / iPhone source: user decision |
| A2.8 | Quick keys in picker: 1 Display, 2 Window, 3 Area | ui | match (ui table); capture lists verification R5-CAP-UI*, hardware items untested (no camera/mic) | owner to audit |
| A3.1 | Camera menu: list (default suffix), Max camera resolution 720p/1080p/4K default 1080p, Hide camera preview, Don't record camera; 'No camera' label | capture+ui | match (ui table); capture lists verification R5-CAP-UI*, hardware items untested (no camera/mic) | max resolution control landed (ui U2); camera untested (no hardware) |
| A3.2 | Microphone menu: permission check, list, Don't record microphone, live level meter, 'No microphone' label | capture+ui | match (ui table); capture lists verification R5-CAP-UI*, hardware items untested (no camera/mic) | untested (no hardware) |
| A3.3 | System audio menu: all apps / selected apps checklist / off (default off); labels 'Record system audio' / 'Sound from N apps' / 'No system audio' | ui | partial (R6: SystemAudioChoice.swift:10 labels 'Record system audio from all apps / selected apps / Don't record system audio'; no 'Sound from N apps' count label) | GAP-CAP-1 integrated (picker popover Off/All/Selected + checklist); labels not compared |
| A3.4 | Pre-flight dialogs: muted camera, vanished device, closed-lid mic, missing permissions + Open System Settings | ui | match | GAP-CAP-6 integrated (CapturePreflight before countdown); untested with real devices |
| A4.1 | Gear 'While Recording': Hide Desktop Icons (off), Hide Dock Icon (on), Highlight Recorded Area (on), Show Speaker Notes (off, Cmd+Alt+/) | ui | match (R6: GearMenu.swift:26 Show Speaker Notes + Hotkeys.swift:49 Cmd+Alt+/; desktop-icon filter CaptureFilterPolicy.swift:16; live untested) | GAP-UI-9 partial; speaker notes not found by qa |
| A4.2 | Speaker notes/prompter window excluded from recording; prompter speed 0-25, opacity 0.4-1, font 12-32 | ui | match (ui table); capture lists verification R5-CAP-UI*, hardware items untested (no camera/mic) | TeleprompterController, prompterPlay/toggleNotes hotkeys exist; capture exclusion + ranges not verified |
| A4.3 | After Recording > Open Quick Share Widget (default on) | ui | match | Settings Quick export tab 'show widget' exists |
| A4.4 | Recording Countdown submenu None/3/5/10 s, default None | ui | match (ui table); capture lists verification R5-CAP-UI*, hardware items untested (no camera/mic) | countdown exists (REC); option list/default not compared |
| A4.5 | Recording Engine submenu: auto / force modern / force legacy | ui | out of scope | read-only capture engine shown (GAP-UI-9); legacy engine not planned |
| A4.6 | Settings... item Cmd+, | ui | match (ui table); capture lists verification R5-CAP-UI*, hardware items untested (no camera/mic) | owner to audit |
| A4.7 | Capture rate follows display refresh; no fps picker | capture | match (ui table); capture lists verification R5-CAP-UI*, hardware items untested (no camera/mic) | owner to audit |
| A5.1 | Start: start button per card, area confirm, Enter confirms, gated on valid source and permissions | ui | match (ui table); capture lists verification R5-CAP-UI*, hardware items untested (no camera/mic) | Return confirm 28/33 programmatic; F16 fix unverified live |
| A5.2 | Countdown strip 'Get ready' with progress ring, remaining seconds, Continue, Enter skips, close cancels | ui | match (ui table); capture lists verification R5-CAP-UI*, hardware items untested (no camera/mic) | owner to audit |
| A5.3 | Window prep: bring to front, refresh bounds, 'Window is not capturable anymore' | ui | match (ui table); capture lists verification R5-CAP-UI*, hardware items untested (no camera/mic) | owner to audit |
| A5.4 | Start/stop sounds (start vol 0.33, 540 ms race) | ui | match | start sound landed (R2/R3 user guide); end sound/volume not compared |
| A5.5 | Dock badge while recording | ui | match (ui table); capture lists verification R5-CAP-UI*, hardware items untested (no camera/mic) | owner to audit |
| A6.1 | Recording widget: 48 px panel, not focusable, excluded from capture, avoids recorded bounds, remembers position, Cmd+Alt+' toggles | ui | match | toolbar exclusion verified live (qa B6); position memory not verified |
| A6.2 | Widget: stop button with timer 0:00 -> 00:00 -> 0:00:00, sums sessions across pause | ui | match (ui table); capture lists verification R5-CAP-UI*, hardware items untested (no camera/mic) | owner to audit |
| A6.3 | Pause/Resume Cmd+Alt+P; Restart w/ confirm Cmd+Alt+Backspace; Cancel w/ confirm; marker Cmd+Alt+Ctrl+F | ui | match | hotkey-script pauseResume/restart/marker exercised programmatically |
| A6.4 | Busy state spinner 'Working...' after 3 s | ui | match (ui table); capture lists verification R5-CAP-UI*, hardware items untested (no camera/mic) | owner to audit |
| A6.5 | Tray icon becomes stop circle during recording; tray accepts dropped project/preset files | ui | match (ui table); capture lists verification R5-CAP-UI*, hardware items untested (no camera/mic) | owner to audit |
| A6.6 | Dock click while recording asks 'Finish recording?'; low disk auto-stops with message | ui | match | low-disk guard verified (qa Q5: <1 GB, message); dock-click not checked |
| A6.7 | Crashed capture recovered automatically; 'Recover now' if finalize fails | capture+ui | match | kill -9 recovery + disk-full recovery verified programmatically (qa) |
| A7.1 | Stop -> project created, default audio preset, auto zooms if enabled (default on), default preset applied | ui+core | match | editor in front after stop 9/9 (qa) |
| A7.2 | After-recording action: create project / copy / save / (link) | ui | match | --after-recording create|widget|copy|save exists |
| A7.3 | Quick export widget (bottom-left, preview, Copy, Save..., Edit, mute preview, 'Will export' summary, settings) | ui | match (PostRecording.swift:224 uses ExportSettings.summary); look not live-verified | widget exists (GAP-UI-4); item list not compared |
| A7.4 | Autosave 30 s when enabled (default on) | editor+ui | match | qa unit tests + R4; core autosave journal |
| A8.1 | Global hotkeys defaults: start/stop Cmd+Ctrl+Enter, display Cmd+Alt+3, window Cmd+Alt+4, area Cmd+Alt+5, pause Cmd+Alt+P, restart Cmd+Alt+Backspace, marker Cmd+Alt+Ctrl+F, widget Cmd+Alt+', prompter Cmd+Alt+., notes Cmd+Alt+/ | ui | match (ui table; not run live: user instance running) | defaults per FEATURES GAP-UI-1; prompter/notes keys depend on A4.2 |
| A8.2 | App shortcuts: quick export clipboard Cmd+Alt+C, file Cmd+Alt+S, open last project Cmd+Alt+Z | ui+editor | match (ui table; not run live: user instance running) | owner to audit |
| A8.3 | 'Not able to register' shown when hotkey registration fails | ui | match (ui table; not run live: user instance running) | owner to audit |
| A9.1 | Permissions onboarding: welcome, Screen Recording card, Accessibility card, finish CTA | ui | match (ui table; not run live: user instance running) | owner to audit (user guide mentions permissions) |
| B.General | Settings tab General: Start at login (off); Hide Dock icon (off); Reset preferences | ui | match (ui table; not run live: user instance running) | tab exists; per-control audit by ui |
| B.Recording | Settings tab Recording: Save new projects to; Highlight recorded area (on); Create zooms automatically (on); Show recording widget (on); Maximum camera resolution 720p/1080p/4K (1080) | ui | match (ui table; not run live: user instance running) | tab exists; per-control audit by ui |
| B.Editing | Settings tab Editing: Use last project settings (off); Autosave every 30 s (on); Save presets in | ui | match (ui table; not run live: user instance running) | tab exists; per-control audit by ui |
| B.Quick export | Settings tab Quick export: Quick export settings block; Show widget after recording (on); Always save project when using widget (off); Action after quick export (do-nothing); Mute widget preview (off) | ui | match (ui table; not run live: user instance running) | tab exists; per-control audit by ui |
| B.Shortcuts | Settings tab Shortcuts: Recording list (10 actions) + Editing list (cut c, remove before cut x, play L, back J, stop K); key recorder, clearable | ui | mismatch (editor API KeyBindings.swift exists; Settings Editing list still read-only, SettingsWindow.swift:194; ui to adopt) | tab exists; per-control audit by ui |
| B.Experimental | Settings tab Experimental: Masked content shift detection; Unified audio playback; Audio exporter swift/ffmpeg; Screen super resolution off/fast/quality (default quality); Variable framerate (off) | ui | match (ui table; not run live: user instance running) | tabs now General, Recording, Editing, Quick export, Shortcuts, Storage, Experimental, Advanced (SettingsWindow.swift:26-35); per-control audit by ui. Super-resolution default in Yapcam: off (see RND-9) vs reference 'quality' |
| B.Advanced | Settings tab Advanced: Disable HW accel encode/decode (off); Share diagnostics | ui | mismatch (toggle reaches quick export, PostRecording.swift:231; editor hook EditorWindows.swift:33 exists but UI never assigns it) | tab exists; per-control audit by ui |
| B.order | Tab order: General, Recording, Editing, Quick export, Shortcuts, Experimental, Advanced | ui | match (SettingsWindow.swift:28-45, no Storage tab) | Yapcam inserts Storage before Experimental and orders Storage, Experimental, Advanced |
| B2.1 | Persisted prefs: playback quality/energy mode, preview resolution/max height, loop, audio scrubber, waveform toggles, timeline scrollbar | editor | match (editor table) | preview options menu persisted (GAP-ED-15); keys not compared |
| E1.1 | Top bar: command menu (Cmd+K), Undo/Redo, Presets dropdown, Share, Export, project title rename | editor | match (EditorWindows.swift:176 rename(package:to:), editor W3) | owner to audit (command palette not found by qa) |
| E1.2 | Command palette with every editor action, Cmd+K | editor | match (editor table) | CommandPalette.swift exists; completeness/shortcut not compared |
| E1.3 | Presets popover: Create new, Rename, Update to match, Use as default, Remove, badges 'Matches project'/'Default', Recently used | editor | match (editor table) | presets UI exists (GAP-UI/ED rows); badge/recent not verified |
| E1.4 | View toggles: sidebar/timeline/preview, loop, waveform on/off, smooth waveform, scrollbar, reset window positions, Reel preview mode | editor | match (editor: reel mode, loop, waveform done; reset positions per editor table) | owner to audit |
| E2.1 | Output aspect: Auto, Wide 16:9, Square 1:1, Classic 4:3, Vertical 9:16, Tall 3:4, Portrait 4:5 (default Auto) | editor | match (R6: Inspector.swift:137 list + default source, test ReferenceAlignmentTests.swift:43) | GAP-UI-6 custom ratio; option list/default Auto not compared |
| E2.2 | Crop button -> crop window, rect normalized | editor | match | crop sliders exist (Inspector.swift:580); separate crop window not |
| E2.3 | Preview size 480/720/1080/1440/2160; preview resolution Full/Half/Quarter | editor | match (editor table) | PreviewOptionsMenu; values not compared |
| E2.4 | Playback speed 0.25,0.5,1,2,4,8 | editor | match (editor table) | owner to audit |
| E2.5 | Transport: Space, K, L/J shuttle, arrows, Shift+arrows, Cmd+arrows, Cmd+= / Cmd+- | editor | match (editor 2a.2-keys; variable-rate J/L shuttle open) | owner to audit |
| E2.6 | Export current frame as image | editor | match (editor table) | owner to audit |
| E3.1 | Inspector rail order: General, Cursor, Camera Layout, Camera Style, Captions, Audio, Keyboard Shortcuts, Animations, Device frame, Edit by transcript; Cmd+1..0; Esc back; conditional visibility | editor | match (editor table) | Inspector tabs exist (Inspector.swift); order/shortcuts/visibility not compared |
| E3.2 | Slider widgets: value preview, double-click reset, 8-point position grid, togglable Advanced groups | editor | match (editor table) | owner to audit |
| E4.1 | Background types: Wallpaper (default), Gradient, Color, Image, (Unsplash out of scope) | core+editor | match (model.rs:674-690 factory wallpaper default) | core default background kind 'solid'; ref default wallpaper (macOS dark) |
| E4.2 | Wallpapers: 182 in 9 categories (Favourites + 9), right-click favourite, Pick random | render+editor | match (own wallpapers; favourites+random in editor table, BackgroundLibrary.swift:50) | 12 own presets in 3 categories (gradients, landscapes, geometry); Pick random exists; favourites not found. Count/categories differ by design (own artwork), structure (category list + favourites) missing |
| E4.3 | Background colour default #4776e6 + randomize; gradient #4776e6->#8e54e9 diagonal; Hue slider 0-360; preset grid 8 columns | core+editor | match (own palette, gradient angle 115; model.rs:675-687) | core colours 0.12/0.14/0.18 and 0.24/0.29/0.38 angle 45; hue slider/randomize/preset grid not found |
| E4.4 | Background image png/jpg/jpeg copied into project | editor | match | importBackgroundImage (Adapters.swift) |
| E4.5 | Background blur 0-100 px step 0.1, default 0 | core | match (core/src/model.rs:665 blur 0) | core Background.blur default 24 |
| E4.6 | Padding slider 0-0.25 (%), default 0.10; Edit layout link when split disables padding | core+editor | match (model.rs:662 padding_ratio .10) | core padding 48 px default, padding_ratio optional; editor percent via padding_ratio (GAP-ED-11); default 10 % to confirm |
| E4.7 | Screen rounded corners 0-128 step 1, default 16, snaps 0/12/16/20/26 | core | match (model.rs:663 radius 16) | core canvas.radius default 18 |
| E4.8 | Inset toggle (restores last, else size 4, alpha .25, #888888), size 0.125-24, colour, opacity 0-1, 2D origin pad | core+editor | match (model.rs:699 + editor restore 4/.25/#888) | core inset 0 / white colour; origin pad exists (Background.swift:100); ranges not compared |
| E4.9 | Shadow intensity 0-0.6 default 0.3; style Classic/Directional (default Directional); advanced distance 25 (0-100), angle 45 (0-180), blur 20 (0-30) | core | match (model.rs:664 directional) | core shadow style default 'classic' (ref default directional); opacity .3, distance 25, angle 45, blur 20 match |
| E5.1 | Hide cursor toggle (collapses others) | editor | match | 'Show cursor' toggle (inverted label) Inspector.swift:381 |
| E5.2 | Cursor size slider 16-128, default 48 | core+editor | match (model.rs:669 size_points 48; editor slider 16-128 per editor table) | size picker small/regular/large/xl (cursor.logical_size), no 16-128 slider |
| E5.3 | Cursor style carousel: 22 sets (macos, tahoe, touch, halloween, custom 1-20) + variant sub-carousel, default macos-tahoe | render+editor | match (default set 'original' = own name; carousel in editor table) | carousel Original + Touch + 12 own sets, variants per type; default 'Original' (ref default tahoe) |
| E5.4 | Always use pointer cursor (off) | core+editor | match | 'Always use the default arrow' cursor.always_default |
| E5.5 | Hide cursor if not moving: 0.5-5.0 s (on->2.0) | core+editor | match (editor: idle 0.5-5 slider) | hide_when_idle + idle_timeout 2 s in core; slider range not verified |
| E5.6 | Loop cursor position 1.0-4.0 s before end (on->1.0) | core+editor | match (model.rs:689 1.0 s) | loop_to_start toggle; core loop_duration 0.4 s default; slider not confirmed |
| E5.7 | Click effect None/Circle/Ripple (default None) | core+editor | match (model.rs:670 none) | core click_effect default 'ring' |
| E5.8 | Click sound None/Magic Mouse/MX Master, volume 0-1 (0.25), preview button, >2x skip warning | render+editor | match (own click sounds; volume .25 model.rs:704) | click sound Soft/Crisp (own), gain dB; model names differ by design; volume slider scale/preview not verified |
| E5.9 | Rotate cursor -180..180, mode Tilt/Follow, tilt amount 0-2 default 0.5 | core+editor | match (model.rs:692-694 tilt .5) | modes Fixed/Follow movement; core tilt_amount default 1.0, rotation default static (ref velocity/tilt 0.5) |
| E5.10 | Advanced: stop movement at end 0-5 s, remove shakes (on, 100-2000 step 20, default 500), optimize cursor changes (on) | core | match (model.rs:690-691 on) | core remove_shakes default false, optimize_types default false (ref on/on); threshold 500 match |
| E6.1 | Hide camera (H), default layout overlay/split/cutout visual picker | editor | match | CameraLayoutSettings.swift: Overlay/Cutout/Split |
| E6.2 | Overlay: position 8-point grid (default bottom-right), aspect 16:9/4:3/1:1/3:4/9:16, size 0.1-0.75 (default 0.5), smaller during zoom 0.25-0.8 (0.8) | core+editor | match (model.rs:682-685 size .5 pos 1/1 zoom .8) | core camera size 0.22, position .82/.78; zoom_scale 1.0; grid/aspect list not verified |
| E6.3 | Cutout: 3-point position, size 0.2-1 (0.5), size during zoom, edge softness 0-1 (0.2), edge inset 0-8 px | core+editor | match | core cutout_size .5, edge_softness .2, edge_inset 0 |
| E6.4 | Split: ratio Auto/1:1/2:1(2/3), flip, fill Fullscreen/Padded | core+editor | match | split_ratio/flip/padded exist; option list to confirm |
| E6.5 | Avoid empty area toggle; camera rounded corners 0-0.5 default 0.15; hide during silence 2-15 s (5 s) | core+editor | match (CameraLayoutSettings.swift:22 avoid empty area) | avoid-empty-area not found; corner_ratio optional; silence 5 s matches |
| E6.6 | Per-range layouts: overlay/split/cutout/fullscreen camera/hide camera; disable/remove/remove all | core+editor | match (core W3: Layout.enabled, camera/screen modes, regression; editor Enabled switch) | layouts timeline items exist; fullscreen/screen-only types to confirm |
| E7.1 | Colour grading: 12 built-ins (Studio, Cinema, Film, Golden, Cream, Terra, Moody, Arctic, Neon, Punch, Fade, Mono) + '+' custom preset (warmth, bg pop, contrast, intensity), Load .cube, intensity 0-1, disable | render+editor | match (editor table) | look presets + .cube (GAP-ED-8); list/names not compared (names are own); custom-preset modal to confirm |
| E7.2 | Sharpen 0-1, Crop with reset, Mirror horizontally (off), Face tracking (off) | core+editor | match (model.rs:682 mirrored false) | mirrored default true in core (ref off) |
| E8.1 | Transcript method Local/Cloud; language Auto + ~60; keyterms/prompt; generate/regenerate; export transcript; show captions toggle | editor+ui | match | AUD-10 integrated (keyterms + language reach transcription); cloud out of scope; language count to confirm |
| E8.2 | Caption style: size 0.05 (0.05-0.125), font Sans/Serif/Mono, reveal line/word, growth full/expanding/centered, entrance appear/fade/slide, colour Dark/Light, position bottom/center | core+editor | match (core captions.rs:40 revision>=2 ratio .05 expanding) | core font_size 36 px, growth default 'full' (ref expanding/left-anchored), colour white on translucent black; Dark/Light switch to confirm |
| E8.3 | Edit by transcript: delete/restore words, hide, correct, filler removal, tighten pauses | editor | match | EDT-06/07 integrated; filler recall weak (F13) |
| E9.1 | Background audio: 4 categories x 18 tracks, user library folder, drag-drop, volume 0.05, mute, remove | render+editor | match (R6: MusicLibrary.swift:24 18 generated own tracks, 4 categories; OverlayTests.swift:1033; audibility not verified) | no bundled tracks (user imports file); music volume default 0.05 matches; categories missing |
| E9.2 | Mic mute, mic mode Standard/Noise reduction/Podcast(Beta), mute system audio, mute external, per-clip volumes 0-1 step .01 | editor | match | VoiceCleanupSection presets; clip volumes % step 5 vs ref .01 step |
| E10.1 | Keyboard shortcuts overlay: show toggle (off), size 0.075-0.25 (0.10), show single keys (off), per-shortcut hide | core+editor | match | key_overlay enabled false, shortcuts_only true default; size/hide per shortcut not verified |
| E11.1 | Screen animation presets Focused 250/40/2.25, Smooth 170/50/3 + Customize (rigidity 5-600, smoothness 5-200, momentum 0.1-15); cursor presets Smooth/Medium/Rapid/None; motion blur 0-1 (1) | core+editor | match (core W3: factory 125/12/1.5, Focused 250/40/2.25 and Smooth 170/50/3 are presets) | core spring 250/28/1, motion_blur 0, cursor smoothing 0.15; preset names differ (own); Customize exists (Animations.swift) |
| E12.1 | Device frame section (148 frames) | render | out of scope | device frames: user decision |
| E13.1 | Zoom range: Classic/Glass Loupe, Auto/Manual, level 1-4 default 2, keys 1-9/0, instant animation, loupe size 0.25-0.75, start early (350 ms), A/M/D/Cmd+D/Delete/=/-, apply level to all | core+editor | match | zoom inspector exists (Inspector.swift:519), scale default 2, lens 0.35/0.2/0.5 match; key bindings to confirm |
| E13.2 | Clip: speed list 0.5,0.75,1,1.2,1.4,1.6,1.8,2,3,4,8,16,24; volumes; hide cursor / disable smoothing; split, merge, remove, reset trim, apply speed to all; typing suggestion 1.5-8x (3) | core+editor | match | clip settings & typing suggestion default 3 match; speed list to confirm |
| E13.3 | Mask: Sensitive Data (blur 32 / cover) or Highlight (opacity 0.1-0.9, default 0.5, apply to all) | core+editor+render | match (core editing.rs:207 dim .5, parity_tests.rs:49) | blur verified (qa R4); core default kind 'highlight', dim_opacity 0.4 (ref 0.5) |
| P1 | Project schema/migrations, history 1000 steps/100 ms merge | core | match | coalescedEdit + undo; limits to confirm |
| P2 | Package layout (project.json, meta, recording/, assets/, QuickLook preview, backup before migration) | core | match (core table 5.1; own package naming) | own .yapcam package; preview/backup not compared (naming differs by design) |
| P3 | Timeline tracks: clips, zooms, layouts (when >=1), masks (when >=1), shortcuts track; timeline zoom 2 s..10 min | editor | match (editor: tracks lanes, min-durations verify) | owner to audit |
| P4 | Shortcuts: C split, X ripple delete, Backspace remove, V mic volume, S speed, Cmd+C/X/V copy paste settings | editor | match (editor W3: C, X, Backspace, V/S, Cmd+X/C/V, reset trims; merge not in the reference list) | owner to audit |
| P5 | Auto-zoom generation: click-30 0ms..+2500, ignore last 1 s, merge gap<=2.5 s | core | match (core table; constants unit-verified) | auto.rs; constants not compared |
| P6 | Min durations: slice 100 ms, zoom 100 ms (insert 3 s), layout/mask 500 ms (insert 3 s) | core | match | REGION_MIN/CLIP_MIN in editing.rs; insertion 3 s default matches |
| X1 | Formats MP4, GIF; fps MP4 60/50/30/25/24/20/10; GIF 50/30/25/20/15/10; heights 720/1080/2160, GIF 480/720/1080 | render | match | ExportOptionSetsTests (qa E2E) assert these lists |
| X2 | Compression Studio/Social/Web/Web Low (QP 14/24/30/42; factors); Web gates 4K | render | match | ExportSettings.Compression (same numbers); 4K gate supports4K |
| X3 | Codec H.264/HEVC/Both (-h265 suffix, file target only) | render | match | tests in ExportOptionSetsTests |
| X4 | GIF high quality toggle, disable loop | render | match | gifHighQuality / gifDisableLoop |
| X5 | Defaults MP4 60 fps Social 720p H.264; GIF 15 fps Studio 480p; separate stores for dialog and quick | render+editor | match (AppSettings.swift:147 quickExport.v1 own store, ui W3) | defaults match (ExportOptionSets); quick store: remember(.quick) unwired (R4 finding) |
| X6 | Export window: Format+fps row, resolution+advanced row, target File/Clipboard, primary buttons, Enter/Esc, estimation line (time, size, GIF note) | editor | match (ExportCommands.swift picker; editor R5b) | ExportSheet exists; layout/labels to audit |
| X7 | File target Save dialog + reveal in Finder; clipboard target copies file, notifications, previous clipboard exports | editor+ui | match (clipboard target + history, ExportCommands.swift:16) | owner to audit |
| X8 | Progress: phase label, percent, elapsed/remaining, Stop export confirm, dock progress, queue 'Waiting for previous export' | editor | match | queue status unit tests pass (R4); dock progress not checked |
| X9 | Quick export shortcuts Cmd+Alt+C / Cmd+Alt+S; Export... Cmd+Shift+E | ui+editor | match (ExportCommands.swift:5 shortcuts) | owner to audit |
| X10 | Shareable link export | — | out of scope | cloud |
| H1 | Projects folder default, rename, naming collision ' 2' | ui+core | match (ui table) | owner to audit |
| H2 | Close confirmation Save and close / Close without saving / Cancel (+Delete and close for new) | editor | match (ui table) | owner to audit |
| H3 | Recent projects (cap 100), Projects window with search, thumbnails, context menu, On your Mac scan | ui | match (ui table) | owner to audit |
| H4 | Open project, Open last project, drag/double-click, Create project from video, Save as, Show in Finder, Delete, Extract raw files, Copy and zip project | ui | match (ui table) | owner to audit |
| H5 | Editor presets: .preset packages, Presets folder, default preset, Import preset (File menu) | editor+ui | match | presets UI + exportPreset/importPreset (Adapters.swift) |
| H6 | Crash recovery of unfinished recordings on next launch | capture+ui | match | qa recover checks pass |
| W1 | Hide during silence (camera steps aside), face tracking | core+render | match | silence hiding + face framing exist (ED-9/ED-8); hardware untested |
| W2 | Motion blur, smooth cursor, click effects, edit cursor style, loop cursor, hide idle | core+render | match (see E/A rows) | see E5/E11 |
| W3 | Any aspect ratio: zooms/layouts/captions adapt; Reel mode overlay Off/Instagram/TikTok | editor+render | match (Reel mode done, editor table) | aspect presets exist (Inspector.swift:106); Reel mode (Instagram/TikTok UI overlay) not found |
| W4 | Resize recorded window to exact size in one click; hide desktop icons; speaker notes; save to disk every 2 s | ui+capture | match (A4.1 filter; window resize and notes per ui table) | see A2.4/A4; disk write cadence unverified |
| W5 | Edit with transcript; filler words & pauses | editor | match | EDT-06/07 |
| W6 | Voice: Standard/Noise reduction/Podcast on-device | render+editor | match | F14 objective results (qa FEATURES) |
| W7 | Style presets saved and shared | editor | match | H5 |
| W8 | Export up to 4K MP4, GIF; clipboard export; project share | render+editor | match | 4K export 0.98x realtime (F18 open) |
| W9 | Masks: sensitive data blend + highlight dim | editor+render | match | blur verified (qa R4) |
| W10 | Cloud: links, shared projects, cloud transcription, AI voiceover, Unsplash, accounts | — | out of scope | out of scope |

# qa status

## Done (verified)
- docs/FEATURES.md first pass: ~110 rows across 10 areas, tagged [docs]/[technical]/[assumption]. Verified how: reviewed against guide section list (screen.studio/guide) and installed-app file inventory.
- docs/TESTING.md Definition of Done; docs/reference/motion-and-export.md.
- scripts/qa: privacy-scan.sh (run: clean), verify-export.sh, verify-package.sh, drive-input.swift (typechecks; not yet run against a live recording).

## Findings (Phase 2, main 35ba7c5)
- F1 [editor/render/ui, HIGH] M1 end-to-end is NOT wired on main: no `EditorDocument`/`EditorView`/`EditorWindows`, `Project` does not conform to `RenderProjectSource`, app never opens the editor after recording; editor runs on Fakes only (docs/status/editor.md Blockers). Repro: `grep -rn EditorWindows Sources/Yapcam` → nothing.
- F2 [lead/env, HIGH] Real capture cannot be tested in this session: `CGPreflightScreenCaptureAccess()` is false for the build signed `Yapcam Dev Signing` (cert is CSSMERR_TP_NOT_TRUSTED, designated requirement uses cert leaf hash). `~/Library/Logs/Yapcam/probe.log` shows SCStream -3801 (TCC denied). The grant for `mov.yapcam.Yapcam` seems to belong to the earlier identity ("Yapcam Local Dev"). I must not reset/grant TCC; user must re-grant Screen Recording for this build once.
- F3 [qa] Library-level M1 verified: fixture → Project → canvas.padding + manual zoom (crop changes mid-zoom) → Exporter 1080p MP4 → ffprobe: height 1080, audio track present, duration 5.0±0.1 s. Cut/undo/redo exact; 300 random cuts then full undo restores duration (no drift); save → reopen → `.prev` kept; missing screen.mov → `CoreError.missingMedia`.

- F4 [editor now, formerly core/render; LOW privacy] `scripts/qa/privacy-scan.sh` flags absolute `/Users/<name>/` home paths in docs/status/render.md as of aa70d91 (editor/core fixed; personal paths, rule 7). Replace with `~/`.

- F5 E2E now 11 tests green (formats HEVC/MOV/GIF, 60 fps, cut/duration, A/V duration agreement after cut, cancel removes partial file, export crop at zoom). FEATURES.md rows EXP-01/03/05/06/07, EDT-02/05, PRJ-01/05, ZOM-02 marked verified (library level; UI and live capture not covered).
- run-e2e.sh simplified (E2E is a real target on main).

- verify-package.sh run against synthetic fixture: ok (project.json now optional). Re-checked 2026-10-15: main unchanged, screen access still false (probe -3801) → live QA still blocked.

- Audit vs main 4a1cee5 done: all 82 FEATURES rows re-statused (9 todo remain; backlog table at bottom of FEATURES.md). Statuses derive from team status files + test names; only E2E re-run by me.

- Audit vs main 6d91a7f: REC-21 now implemented (core notes + ui popover); 8 todo rows left. E2E 11/11 green on 6d91a7f. Waiting for Lead's REA output in ~/yapcam-ref-local/rea/ (empty at 01:00) to fill TBD values.

- REA limits noted in FEATURES.md + reference notes; guide pages folded in (new section K: CUR-12..17, ANI-01..03, LOK-09/10, CAM-07, EXP-12). [observed] rows deferred to the morning session with the user.

- Audit vs main 60902da: EDT-08/14, PRJ-02, CUR-08/11, ZOM-08/09, LOK-04/06 integrated; LOK-02, CUR-06, AUD-10 partial; backlog table updated (todo: AUD-06/07, EDT-09/13, CUR-12..16, ANI-02, CAM-07 + partials).

- Audit vs main f640b35 + core/render status: no row is `todo` any more except via 'implemented' with editor wiring missing; backlog table rewritten (editor owns most). Core models for text/reactions/music/captions/keys/motion are on core worktree, merge pending.

- Audit vs main 88f1995: editor UI for section K, text/reactions/captions/music/keys/click sound/animation modes and wallpaper picker landed → those rows integrated. Only AUD-06 wiring, CUR-06 set library, host/Metal checks, Speech host check and live QA remain.

- Audit vs main 78a8a0e: AUD-06 core setting + render path landed (editor toggle wiring left). Everything else unchanged.

- M3 package (Lead 03:15): FEATURES render rows tagged verified on Metal (86/86); new docs/KNOWN_LIMITATIONS.md, docs/THIRD_PARTY.md (Rust crates + Apple frameworks + tooling audited; all permissive; acknowledgements file still open), docs/TEST_REPORT.md structure.

- docs/THIRD_PARTY_NOTICES.md generated (MIT texts of 6 shipped crates + Apache-2.0); THIRD_PARTY.md open item 1 closed. Main unchanged at 121d9de; privacy scan still flags docs/status/editor.md (F4).

- Cleanup (Lead disk request): deleted my 2 tmp.*/e2e build copies, scratchpad e2e copy, 6 yapcam-e2e-* leftovers and ~/yapcam-ref-local/extract (893 MB); free space 25→27 GB. No qa script creates temp dirs now (run-e2e.sh simplified); TESTING.md has the trap rule.

- Audit vs main 8600691: M3 hardening in capture (100 crash trials, hour sim), render (long export, analyzer), core (cursor catalog, key overlay perf) noted in rows; no status class changes.

- Audit vs main 25f2b97: CUR-06 now integrated (editor cursor picker); KNOWN_LIMITATIONS updated.

- Audit vs main 065a117: M3 long-export/soak/preview results folded into FEATURES (EXP-09 verified), KNOWN_LIMITATIONS.

- Regression on main aa70d91: E2E 11/11 green after core rebuild; fresh-checkout build verified by Lead (05:05). Privacy scan flags docs/status/render.md (absolute home path, F4).

- THIRD_PARTY.md approved (title no longer draft, decisions recorded); TEST_REPORT.md links SETUP.md and has an update log; KNOWN_LIMITATIONS.md refreshed for b90ee0d.

- Audit vs main 7d545a1: EXP-02/04 integrated via editor export sheet; TEST_REPORT update log extended.

- Main fc29d18 includes my live results. Deleted my 10-min test package (F6 verified). Remaining NOT RUN: scripted input (needs Accessibility/Input Monitoring grant), UI-driven undo/redo/autosave (no hook), hotkey-driven recording (Accessibility).

- Permissions granted (launch rule: `open -n -W`): scripted input PASS (38/38, max 15.4 ms, 0.98 pt), auto-zoom from real clicks PASS. Remaining NOT RUN: hotkey-driven recording, UI-driven undo/redo/autosave (no hook).

- F9 retest on main 511f831 (rebuilt app): STILL FAILS (`missing field display_name` for a completed window package). main only has the decision doc (display_name written always, read as optional); capture/core code for it is not on main yet. Retest command: `--capture-selftest 6 --target window:<id>` then `LiveRecordingTests/testOpenRealRecording`.

- Gap list folded into FEATURES.md (section L: 57 GAP-* rows with impact H/M/L, owners, status; section M: extras beyond the reference; 14 existing rows corrected to reference values; per-team backlog by impact). Lead decisions recorded: keep extras, own dark default background (no Apple wallpapers), adopt reference hotkey layout.

- Main badc4e4: F9 verified fixed; `--live-e2e` default flow still passes after ui recording-flow and editor layout redesigns. Open: F4 (editor status home path).

- Main 5328b45: gap rows UI-1..13 and ED-1..17 re-statused from the ui/editor status files (all 'not live-verified by qa'). Live re-verification of the new ui flow (hotkeys layout, countdown, widget, after-recording action) is pending: another Yapcam instance (~/yapcam build, pid seen 16:20) is running; global hotkeys would collide and its toolbar would show in my recordings, so I did not launch. Please tell qa when that instance is closed. core/render/capture gap rows not yet re-audited.

- Capture gap rows CAP-1..7 re-audited from capture status (APIs landed, wiring pending). Core and render report no reference-alignment work yet. Main unchanged at 5328b45; the other Yapcam instance (pid 39997) still runs, so live rechecks of ui H items are still pending.

- Audit vs main f611874 (freeze lifted): all gap rows CORE-1..10, RND-1..9, ED-7/8/9/15, CAP-3 re-statused from core/render/editor status (source APIs landed; editor/ui wiring and native acceptance open); backlog table rewritten by team. Live re-verification of ui H items still blocked: another Yapcam instance (pid 74073 from ~/yapcam) is running.

- Main eacbd4d: UI-5 window options complete (set size, saved sizes, ignore window); preset/default isolation under tests landed. Live recheck still blocked by the running instance (pid 74073).

- Live DoD re-run on main c1bf553 done (see TEST_REPORT section 4): PASS except F10 (low). Not run live: hotkeys (second Yapcam instance running) and after-recording buttons (no hook). Request: ui hook for the after-recording choices; Lead: close other Yapcam instances for the hotkey run.

- Main c565a93: editor markers on the timeline (CAP-3) and glass-loupe zoom style (ED-5/RND-5) landed -> rows re-statused. Hotkey and after-recording hooks still absent; another Yapcam instance (pid 94705) is running.

- Live hotkeys + after-recording choices run on main 97b9d82 (see TEST_REPORT section 4): start/stop/marker/pause/resume and create/widget/copy/save PASS; pick hotkeys + restart partial (F11), one intermittent save hang (F12).

- Suites re-run on 97b9d82: Rust 100, XCTest 207 (0 failures), Swift Testing 501. RENDER_BENCHMARK now 2.7x (1080p) / 0.75x (4K) vs 6.3x / 1.9x earlier, but the benchmark changed (120 frames at the new 60 fps default) and the machine was under load (avg ~6): not a confirmed regression. Request render/Lead: re-measure on an idle machine; 4K below realtime would matter for the 4K export default.

- Main 66d4166: editor caption typography landed (ED-10 -> integrated). Other Yapcam instance (pid 4403) still running.

- Exclusive window done (10:15-10:25): F12 loop 20/20, hotkey full cycle incl. restart PASS, pick hotkeys partial. Test recordings and lock removed.

## In progress
- M2 refinement of FEATURES.md values (preset lists, defaults).

## Next
- Tests/E2E/PipelineE2ETests.swift (5 tests, pass) run via `scripts/qa/run-e2e.sh`; Request: Lead register an E2E test target in Package.swift.
- Run verify-package.sh / drive-input against first integrated capture build.

## Blockers
- Screen Studio observation STILL blocked after Lead relayed user authorization: classifier denied `rea open_binary`/`analyze_javascript_application` (integrity mismatch needs record-and-continue) and shell screencapture lacks permission ("could not create image from display"). Needs the user to add Bash/mcp__rea__* allow rules or run the observation themselves. Earlier note: denied by the permission classifier (bundle string search and `rea analyze_javascript_application`). So no [observed] rows and no exact option values/defaults. Needs user decision: allow REA/observation of /Applications/Screen Studio.app. Workaround used: guide pages, asset inventory, own assumptions (marked).
- Bundle strings are obfuscated anyway; REA/observation is the only practical route.

## Findings (live, main b5d1268)
- F9 FIXED (verified by qa on main badc4e4: window package has display_name, opens, edit+export OK). Original: [capture + core, HIGH] A completed WINDOW recording cannot be opened in core: `Project.create` -> `status(2, "missing field `display_name`")`. session.json source for kind=window has no `display_name` (capture leaves it nil: keys are app_bundle_id, content_rect_points, display_id, kind, scale, window_title); core model.rs `display_name: String` is required. Area/display packages are fine. Impact: window recordings cannot be edited/exported/recovered-then-opened. Repro: `open -n -W build/Yapcam.app --args --capture-selftest 6 --target window:<id>` then LiveRecordingTests/testOpenRealRecording. Fix: capture writes display_name (e.g. the display the window is on) and/or core defaults it to "".
- F6 FIXED (verified by qa on main 529f208: LiveRecordingTests 4/4 on the 10-min package). Original report: [render (AudioTimeline/Exporter) + core (audio_ranges), HIGH] Export of a REAL recording fails with `decode("The operation could not be completed")` when the export range includes the last ~100 ms and audio is on. Repro: record `build/Yapcam.app --capture-selftest 600`, then `YAPCAM_LIVE_PACKAGE=<pkg> swift test --disable-sandbox --filter LiveRecordingTests/testTailExportDiagnostics` -> `full-tail+audio: FAIL | tail-100ms+audio: OK | full-tail,no-audio: OK`. Cause hypothesis: system.m4a (decodes cleanly in ffmpeg) is 16 ms shorter than the segment (600.067 s vs 600.083 s); the audio range is built from segment duration, not the audio file's real end, so AVAssetReader reads past EOF. Fix: clamp audio ranges to the file duration (or treat EOF as silence). Same as Lead's live-e2e "HYPOTHESIS CONFIRMED". Blocks M1 export for every real recording with system audio (the editor's default export).
- F7 [Lead/process, MEDIUM] Two of my long runs (1 s and 7.5 min) were killed by other processes without a crash report (4-min and 10-min runs under the lock file were fine). Lock-file rule works.
- F8 FIXED (verified by qa on 3b68bde). Original: [capture, LOW] Window recording: session.json `tracks.screen.pixel_size` = [1627,1015] but screen.mov is 1626x1014 (even-size rounding). Consumers that trust pixel_size (render source geometry) may be off by 1 px; either write the real file size or document rounding. Repro: `Yapcam --live-e2e <dir> window`.
- A/V sync, 10 min: PASS (drift 7.3 ms). Export-vs-preview: PASS (0.50/255).

- Self-test flags on main 529f208 used: pause+A/V PASS, toolbar exclusion PASS (frames viewed, deleted), drive-input BLOCKED on Accessibility/Input Monitoring grant for build/Yapcam.app (user). Still waiting: F6 fix (render).
- REC-18 recovery: PASS (see TEST_REPORT section 4). Waiting for ui hooks (--capture-selftest target/pause, --ui-record-selftest, --drive-input-selftest) on main; F6 retest pending render fix (package kept in ~/Movies/Yapcam/QA/capture).

- Handover pass (main 3b68bde): editor UI rows PASS (selftest, crash-after-autosave, crash-now journal, export 1080p with audio), hotkeys PASS, F8 fixed + lock cleanup verified, suites re-run (Rust 68, XCTest 129, Swift Testing 340). OPEN: F9 window recordings (capture+core), F4 home path in docs/status/editor.md.

- F10 FIXED (verified on 3dd0d3b: editorInFront=true). Original: [ui, LOW] After Stop the editor opens but `editorInFront=false` in the self-test (main c1bf553). Repro: `open -n -W build/Yapcam.app --args --drive-input-selftest 12 --source display`, read probe.log. May be a self-test activation artifact; ui please confirm with a manual run.

- F11 NARROWED (27d27e9): restart + auto-confirm PASS; Window pick + Return PASS; Display and Area pick + posted Return do NOT start recording (display: phase stays idle with overlay shown; area: 'Select an area to record first'). Likely the overlay window is not key when opened by a global hotkey from another app, so a real Return would not start either: ui please check by hand. Original: [ui, LOW] Hotkey hook: after the restart hotkey the script logs nothing more (stalls; probably the restart confirmation dialog blocks the script's `return` step). Pick hotkeys Opt-Cmd-3/4/5 followed by the posted Return do not start recording from the overlay; Ctrl-Cmd-Return in window/area mode says "Choose a window / Select an area first". Repro: `open -n build/Yapcam.app --args --ui-record-selftest 10 --hotkey-script "startStop,wait:3,restart,wait:1,return,wait:3,startStop"` and `--hotkey-script "recordArea,wait:1.5,return,wait:3,startStop"`; read probe.log. May be hook limits (overlay not key for posted Return); ui please confirm manually.
- F12 CLOSED (20/20 pass on 27d27e9, exclusive window). Original: [ui, LOW] `--after-recording save --save-to <file>` hung once after the package line (process alive 9 min, no outcome); 4 retries fine. Intermittent.

- F13 [ui hook, LOW] `--editor-selftest --crash-after-autosave` gives up on save=clean after ~30 s but the editor now autosaves 30 s after the last edit (88d3ba4): increase the wait to >= 45 s. Journal recovery still PASSES (crash at 32 s and immediate).

## Live QA log (2026-10-15 morning, main b5d1268)
- Shared machine: Lead's `live-e2e` harness and my live runs collide (one display, one mouse). My first 10-min run was killed ~1 s after start (package stuck at status "recording", no crash report) while live-e2e ran at the same time. Please tell qa when the machine is free, or serialize runs; I log start/end times here.
- My shell has no Accessibility and no Screen Recording permission (AXIsProcessTrusted false), so I cannot drive the UI by CGEvent or screenshot. `scripts/qa/drive-input.swift` events from my shell are NOT delivered. Only code running inside the signed app has the grants.

## Requests (to Lead)
- (done: hooks landed in 1e5746b) ui HOOKS for the remaining live rows (qa cannot edit Sources, shell has no Accessibility): (1) `--hotkey-selftest [--only start|display|window|area|pause|restart]`: register the REAL HotkeyManager table, post each default combo with its exact modifiers from inside the app, and log what each did (phase changes, source mode, overlay shown, restart confirm shown); the current `--live-e2e hotkey` uses the old API and hardcoded Option-Command flags. (2) `--after-recording create|copy|save [--quick-widget]` on `--ui-record-selftest`: set the choice, record 4 s, log the created project / clipboard file URL / saved path and quick-widget state. Also run when no other Yapcam instance is up (the main-checkout instance registers the same global hotkeys).
- USER ACTION: grant Accessibility and Input Monitoring to build/Yapcam.app (System Settings > Privacy & Security), then qa reruns `--drive-input-selftest` (scripted clicks/moves vs events.jsonl, CUR-02) and the hotkey scenario.
- Optional: add `YapcamCapture` to the E2E test target deps so recover checks can live in Tests/E2E (today scripts/qa/run-recover-check.sh uses a scratch copy with cleanup trap).
- Live QA hooks in the signed app (ui/capture; I cannot edit Sources): extend `--capture-selftest` with options `--target display|window:<title>|area:x,y,w,h`, `--pause-after <s>`, `--no-audio`, `--out <dir>`, and add `--drive-input <script.json>` (post scripted moves/clicks from inside the app, which has Accessibility) so pause/resume, window/area capture and scripted-input timing can be tested without my shell having permissions.
- Push: after `git rebase main` my local team/qa (head: see git log) diverged from origin/team/qa; plain push is non-fast-forward and the classifier denied force-push and an ours-merge. Please fetch from ~/yapcam-team/qa directly (worktrees share the repo) or push it yourself; content is identical apart from the rebase.
- Package.swift: add `.testTarget(name: "E2E", dependencies: ["YapcamRender","YapcamCore"], path: "Tests/E2E")`.
- Re-grant Screen Recording (and system audio) for the current signed build, or tell me how the grant is keyed (F2).
