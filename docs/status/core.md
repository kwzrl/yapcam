READY UNCOMMITTED REC-21: notes/set contract documented; Unicode, journal/save/reopen, undo/no-op/invalid-type regressions pass (Rust 42, Core Swift 21); signed app builds. Lead checkpoint includes pending H1/M3 validation files.


# Core status

## Current backlog
- REC-21 complete: existing notes field/set path verified with dedicated Rust/real Swift ABI regressions, docs/FORMATS.md explicit notes contract. Suggested commit: `core: verify speaker notes persistence and editing`.
- Next: publish additive contracts for text/reactions/captions, music/click sound, key overlay, transforms and per-layout camera options before implementing. ABI remains v2; existing frame/extras layouts stay unchanged.
- Assumption: Capture transcript uses schema_version 1 + words[{text,src_start_ns,src_end_ns,confidence,segment_index,track}], as found in Capture worktree. Core imports JSON only; recognition remains Capture-owned.
- .git read-only: Lead checkpoints/rebases; no workaround. Current branch 5b9a429; announced main 6d91a7f is later history. New Backlog read from local main docs/FEATURES.md.

## Independent review addressed
- Read ~/yapcam-fleet/reviews/review-core-capture-1.md. No new features started after the review request.
- H1: geometry clamps now use non-panicking min/max with bounded derived spans, including initial zoom, follow_pan and camera placement. Fit/camera heights clamp to available height to avoid one-ulp overflow. Rust regression covers crop [0.1,0.1,0.7,0.7], manual/auto zoom at start 0 and 1 s (including exact start + 1 ns), pan and a height-limited 1280x800 camera at canvas height 768. Real Swift/C regression verifies cropped zoom starts.
- M3: separate writer mutex serializes apply/undo/redo/save. Edits stage under a read lock, journal path/serialization/write/fsync/rename run with NO state lock, then completed durable states/history publish under a brief write lock. Save also copies data then performs disk IO outside the state lock. Swift's global NSLock was removed so readers do not queue behind synchronous disk writes. Old complete state remains visible until the journal succeeds; IO failure leaves state/history unchanged. Durability remains synchronous, with no debounce loss window. Notifications happen after releasing the writer gate.
- Deterministic Rust regression pauses each apply/undo/redo/save disk stage and proves 100 frame + extras calls finish before releasing the writer, with zero allocations. Reader sees old complete state; writer gate remains held. Separate 4-writer test verifies all 32 edits, persisted ordering, complete undo and redo. FFI IO-failure regression covers apply/undo/redo rollback. A disk-stage panic returns status 99 without poisoning frame readers.
- Every FFI entry point, including ABI/error/free/bool getters, has a top-level unwind guard. Panic injection covers all 18 header functions and cross-checks the Rust C exports. Status calls return 99; getters use documented zero/static-message fallbacks; no Rust unwind escapes void calls. Existing FFI signatures and frame layouts unchanged.
- Swift regression runs 1000 frame/extras reads concurrently with 24 durable edits, 12 undo, 12 redo and save; validates crop frames and saved/reopened state. Tests use procedural fixture packages only, not a device/GPU recording.

## Validation / checkpoint
- cargo test: 41 pass; cargo test --release: 41 pass; Clippy all-targets -D warnings and cargo fmt --check pass.
- Swift Core: 20 pass. Portable whole suite: 134 Swift Testing tests in 15 suites + 38 XCTest tests, 16 runtime skips, pass. Clean build-app.sh passes and codesign strict verification confirms Authority=Yapcam Dev Signing.
- Unfiltered suite on updated integration: 152 Swift Testing tests have 18 Editor Metal preview unavailable failures; 44 XCTest have 16 skips and 6 E2E Metal unavailable failures. No Core failure. Host Metal tests remain open; this is not unfiltered full-suite success.
- Portable exclusions: Real(Stack|Frame|CoreRanges|UndoAndScale|Relink)Tests, ReviewFixRealCoreTests, and the six PipelineE2ETests exports (testAudioVideoDurationsAgreeAfterCut, testExportFrameMatchesPreviewEvaluator, testFormatsAndPresets, testFPSAndNoAudio, testM1OpenEditExport, testSpeedAndCutChangeExportedDuration). Other E2E/model tests ran.
- Lead checkpointed/rebased main fixes as 5b9a429 while verification ran. This commit is an ancestor of current main 1f813f8. Origin/team/core still cce4cdc. Pending owned files: core/src/ffi.rs (C-string Clippy correction, stronger export coverage and additional ordering/panic regressions), Tests/YapcamCoreTests/ProjectTests.swift (crop/concurrency regressions), core/README.md (locking/guarantees), this status.
- Suggested final commit: `core: verify review fixes and contain every FFI unwind`. Lead must checkpoint pending files before final branch push; .git remains read-only in Codex. No stage/stash/rebase workaround or main push attempted. Current working tree builds at this natural stop.
- Request independent review of the stage/journal/commit lock scopes and Swift concurrency change before merge. Existing primary/.prev/journal durability and autosave-error behavior are preserved.

## Previous Core work (included in 5b9a429)
- M1 project model/persistence/migrations/path checks, rational shared time mapping, transactional commands/history, allocation-free frames, Swift Project surface.
- M2 auto zoom/typing/silence edits, cursor springs/ranges/idle/loop, canvas/crop/aspect, camera layouts, gain envelopes, autosave recovery, local movie/image/preset/relink helpers. Rational cut/speed/typing effect remaps, no-op history fix, tiny speed preservation and quantized-tail removal verified.
- Exact map_audio_ranges query and Project.mapAudioRanges helper map decoded file-local silence through current clips/segments/speeds/track offsets/repeated occurrences, sorted/merged without IO/history mutation. Editor should decode once per unique path/track then map once per file (not once per per-clip audio row). README documents query/API; Lead can add them to FORMATS/SWIFT_API.
- ABI v2 extras: unchanged YcFrame 328 bytes, YcFrameHighlight 80 bytes, YcFrameExtras 2600 bytes/alignment 8; fixed allocation-free extras evaluation and cold typed render bridges. 32 overlapping highlights max, never truncated; unlimited sequential ranges. Timeline clicks query + typed clicks() retime through edits. Full set paths/ABI docs in FORMATS.md/SWIFT_API.md under prior explicit Lead authorization. FNV-1a64 first-MiB + size approved for change detection.

## Remaining integration / limits
- Render/Editor still need extras/options/layer wiring; draw highlights then fade once, export from one snapshot, and serialize preview edits when a matched frame/extras pair is needed. Independent calls read independently, as before. Rendering/pixel parity remains a host check.
- Editor snapping caches should refresh project.clicks().map(\.tlNs). Render background_asset via mediaURL; audio gain endpoints need dB ramp interpolation. Rust static library updates require Swift relinking (verification used SwiftPM clean).
- Native compressed AAC, real camera/mic, Retina/multi-display, Vision/GPU and movie orientation encode checks remain host-limited. PCM silence is verified; AAC explicitly reports decoder unavailable (-11800/status 6). Scene transforms beyond none/fade remain unsupported.
- SwiftPM uses --disable-sandbox under the outer Codex sandbox and four jobs via temporary PATH wrapper. No app launched, global permission changes, sudo, recordings or credentials committed.
- One editor writer per package; snapshots do not journal. Source-ns quantization shifts effects by media actually removed, with canonical snapped source endpoints; all tracks/events share rational clocks. JSONValue.integer retains ns beyond 2^53. Capture/session contract and existing C frame fields unchanged.
