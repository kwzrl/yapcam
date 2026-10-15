READY uncommitted review-2 key-overlay index: layers_at p99 0.070042ms with 36k keys, frame p99 0.069208ms, worst edit 29.969167ms; Rust 67 debug/release, Core Swift 39, portable Swift 224 + XCTest 91 (34 skips), signed build PASS. M3 916ab92 checkpointed/integrated; cursor palette/shape/size contract next.

# Core status

## Next
- The three assigned M3 packages are checkpointed as 916ab92 and integrated in main 0df4bbb. Review-2 key-overlay fix is READY below. NEXT IN PROGRESS: Render requests persisted palette ID / logical size / ten-shape contract (main 0df4bbb); document first, additive cold JSON options, no existing ABI code/layout change. Lead: checkpoint/rebase/publish under read-only Git and request independent review of rational prefix/cut mapping + windowed auto-zoom candidate selection. Main observed 121d9de (newer than announced a02a89e); committed Core runtime sources match HEAD fa0b6e5. Actual clean rebase failed creating read-only rebase-merge; no Git metadata workaround.
- Pending owned files: core/src/{time,commands,auto,lib,hardening}.rs, core/README.md, MigrationTests.swift, own status. Tests/Fixtures/schema is additionally authorized by Lead's explicit frozen-fixture request; existing synthetic fixtures remain unchanged. Suggested checkpoint: `core: harden large edits, frozen migrations and JSON FFI fuzzing`.

## Review-2 key overlay — READY
- Found in Render status/review-codex-2.md: layers_at rebuilt full key_events on every frame. New immutable source-key/label cache + edited timeline/shortcut indexes are built on load and staged during edits/history before publication; Arc shares indexes in snapshots. Binary-search lookup preserves strict expiry, shortcuts-only semantics, glyph order, empty-key suppression and stable same-time ties. Existing public key_events metadata now shares that map; no schema/ABI changes.
- Settings are read at lookup/draw time, so enable/duration/filter/rect/style changes cannot leave stale results and reuse immutable indexes. Cuts/speeds/splits/history rebuild the timeline map; project reload/relink builds new capture indexes. Cold test-fixture event replacement explicitly rebuilds the source index. Failed staged edits leave current data and index untouched. No full key list or disk IO on overlay frame lookup.
- Extended 60-minute harness: 36,000 keys / 18,000 shortcuts in the same 3.6M events. yc_query layers_at p50 0.049958 / p99 0.070042 / max 0.131917 ms (1,024 samples); frame p50 0.035625 / p99 0.069208 / max 0.111083 ms. Worst sampled edit 29.969167 ms (auto_zooms). Durable speed/split/cut p99 12.096000 / 12.066958 / 10.129625 ms; save 12.152166 ms / 1,002,037 bytes. All limits PASS; key lookup itself allocates zero.
- Two Rust regressions compare cached metadata against original query mapping on repeats/fractional speeds/cuts/history, assert Arc sharing and invalid edit stability, and cover shortcuts/expiry/ties/empty labels/text-before-fade order. Swift ABI regression covers settings, speed/cut, undo/redo, snapshot isolation and save/reopen. Rust 67 debug/release, Core Swift 39, portable Swift 224 / 30 suites + XCTest 91 (34 skips), Clippy and signed build pass. Logs /private/tmp/yapcam-core-key-index-{tests,all,release,scale,clippy,swift,app}.log.
- NEW next request in main 0df4bbb Render status: persist authored cursor palette ID / logical size / ten-shape contract and query for Editor's picker. Do after key-overlay package; publish FORMATS/SWIFT_API contract first, preserve existing style codes and YcFrame/Extras layouts.

## M3 READY — scale / performance fixes
- Release harness: `CARGO_BUILD_JOBS=4 cargo test --release --manifest-path core/Cargo.toml scale_60_minutes -- --ignored --nocapture`. Normal suite intentionally skips this large case. Actual C ABI calls with live handle; 60-minute capture model, 3,600,000 generated events at 1kHz, 5,000 clips, 1,000 zooms, cursor smoothing enabled. 2,048 random frames after 32 warmups, fixed seed 0x19bc48; 64 property apply/undo samples per durability mode, eight each speed/split/30-minute cut/auto-zoom. Nearest-rank percentiles, monotonic Instant wall time. Mac mini M4 (brief), arm64, macOS 26.3, rustc 1.95.0; fleet load can vary timings.

| Actual ABI operation | p50 ms | p99 ms / max edit ms |
|---|---:|---:|
| yc_frame_at | 0.035917 | 0.055750 (max 0.115334) |
| yc_apply, autosave off | 1.710542 | 2.269417 |
| yc_undo, autosave off | 0.116792 | 0.186750 |
| yc_apply, durable | 9.988958 | 18.783250 |
| yc_undo, durable | 8.746084 | 12.930042 |
| set_speed, durable | 8.027958 | 9.020375 |
| split, durable | 7.939125 | 8.983917 |
| delete 30 minutes, durable | 7.962666 | 8.961625 |
| auto_zooms, durable | 25.059292 | 29.880792 |

- Save: 14.172709 ms; project.json 1,002,038 bytes (1,000 auto-mode zoom records after regeneration/undo phase; initial manual-mode records serialize to 1,004,038 bytes). Generator/index build 0.128 s. All sampled edits <50ms and frame p99 <1ms; zero hot allocations. Original default-mode baseline was p50 0.335667 / p99 1.323833 ms, and 30-minute cut p50 1202.588875 / p99 1231.286541 ms.
- Fixes: exact integer-ns fast paths avoid unnecessary rational GCD/division; cut boundaries build one rational prefix table, and removed-span prefix sums + binary search replace repeated full scans during effect remapping. Auto zoom now searches the retained event window per source clip and uses one rational time prefix table; preserves pre-cut cursor coordinates, repeated clips, fractional speeds and endpoint exclusion. Regression oracle checks linear mapping equality at fractional/snapped/sub-ns boundaries and >2^53 clocks; prior 10,000-edit time invariants remain green. No schema/ABI changes.
- Assumptions/limits: events generated in memory, copied procedural fixtures supply media refs; measures evaluator/edit scaling, not recording-file parsing or movie decoding. No massive dataset or recordings committed. Default speed-1 clips with manual zooms for frame sampling; auto-zoom phase temporarily changes modes and undoes its edits. Durable samples include real serialization/journal/fsync; save includes .prev handling. These are measured host samples, not an all-load/all-option latency guarantee.

## M3 READY — frozen migration harness
- Frozen JSON corpus under Tests/Fixtures/schema: v1-minimal (missing settings), v1-populated (nondefault settings, repeated clips/speeds/effects/Unicode/media fingerprint), v1-long-clock (>2^53 clocks and >Int64 media byte count), v0-prerelease (supported 0->1 defaults migration). Independent FNV-1a64 manifest freezes exact corpus bytes; no regeneration from current model types. Add new cases instead of rewriting legacy fixtures.
- Rust harness checks every original leaf retained, canonical decode/serialize/decode equality, restored defaults and future-version refusal. Small integer literals in floating settings compare numerically; large integers must remain exact integer JSON, never Double comparisons. Swift's real ABI open/save/reopen/snapshot harness verifies minimal/v0 files, unchanged originals on open, explicit relink failure for populated synthetic fingerprint, and future primary cannot fall back/downgrade to an older backup.

## M3 READY — deterministic FFI fuzz
- Four seeds, 10,000 random JSON commands: 1,498 accepted, 8,502 rejected; zero returned panic status 99. Includes malformed JSON/UTF-8/nonfinite number spelling, arbitrary nested types, 40-deep batches, bad paths, split/cut/speed/set/zoom/caption inputs and atomic partially failing batches. Live ABI handles and valid allocated C buffers only.
- Failed commands preserve canonical state + undo/redo availability. Accepted states validate; frame/extras/motion outputs stay valid/finite or explicit invalid-time errors. Exercises random queries, history, snapshot immutability, owned result-string freeing and 100 real save/open equality checks. Failures report seed/step/command. Ordinary cargo test runs the corpus; no fuzz dependency or fake implementation. This is finite regression evidence, not a proof for every possible input.

## Previous integrated M1/M2 packages
- Lead checkpoints e4be2c3 and fa0b6e5 contain the complete Core model/evaluator/ABI v3, notes, text/reactions/captions, music/clicks/key overlay, camera layouts, cursor filtering/hold/type optimization, motion presets/blur/camera zoom, AUD-06 settings/preparation and arrow style/code 3. All existing YcFrame/extras layouts retained; no new M3 ABI or schema version.
- Persistence/recovery, safe media/FNV references, rational clocks, exact cuts/speeds, transactional undo/redo and zero-allocation frames remain regression tested. Prior H1 rounding-safe crop/pan/camera clamps and disk I/O outside state locks remain intact; all 19 FFI entries have top-level panic-injection coverage.

## Validation / checkpoint
- Current M3 tree: cargo test 65 debug + 65 release pass; one large scale test intentionally ignored in each ordinary run, separately PASS in release. Clippy all-targets -D warnings + cargo fmt --check + git diff --check pass.
- Current Core Swift 38 pass after clean optimized-Rust relink; portable suite 202 Swift Testing tests in 24 suites + 85 XCTest (31 explicit runtime skips) pass. Clean build-app.sh + strict codesign pass: mov.yapcam.Yapcam / Yapcam Dev Signing.
- Outer-sandbox unfiltered run: 233 Swift Testing tests / 33 suites with 31 issues (29 Editor Metal-preview unavailable + 2 UI smoke missing windows), 91 XCTest with 31 skips + six Metal-unavailable E2E failures. No Core failure. Lead separately reports main a02a89e full tests green and Render 86/86 on native Metal; this local restricted-run result does not override that native evidence.
- Portable exclusions: Real(Stack|Frame|CoreRanges|UndoAndScale|Relink)Tests, ReviewFixRealCoreTests, OverlayRealCoreTests, TextAndMusicRealCoreTests, GuideOptionTests.realCoreAcceptsEveryCursorMotionAndCameraOption, WallpaperTests.realLibraryAppliesGradientAndImageWallpapers, UISmokeTests, plus six PipelineE2ETests methods (testAudioVideoDurationsAgreeAfterCut/testExportFrameMatchesPreviewEvaluator/testFormatsAndPresets/testFPSAndNoAudio/testM1OpenEditExport/testSpeedAndCutChangeExportedDuration). All new Core/migration and Render software tests ran.
- Logs /private/tmp/yapcam-core-m3-{scale-baseline-full,scale-final,all-rust,release-all,final-clippy,migration-swift,fuzz,portable,full,scale-app}.log. Benchmark command/method also recorded in core/README.md.
- fa0b6e5 contains the previous final API/status refresh; source checkpoint M3 remains uncommitted for Lead (read-only .git). Fast-forward pushed fa0b6e5 to origin/team/core from e4be2c3; exact remote verified as fa0b6e54609d3d81e42c8eae23c8280adfe60e52. This publishes the previous final docs, not uncommitted M3 work. No M3 work claimed pushed without a commit.

## Requests / integration handoff
- Lead: checkpoint M3 owned sources/tests + explicitly requested frozen fixture corpus, rebase onto latest main and run native integration tests. Independent review requested for integer fast paths, rational cut-prefix lookup/coincident rounded edges, retained-window auto-zoom cursor history and migration/fuzz invariants before acceptance. No ABI or schema bump.
- QA: reference this measured M3 table/harness in testing evidence. All FEATURES rows now implemented/integrated per Lead; previous M2 Editor/Render handoffs are superseded by the full native green integration. docs/FEATURES.md remains QA-owned.
- Editor output sizes confirmed previously: 4:3/[1440,1080], 1:1/[1080,1080], 9:16/[1080,1920], 21:9/[2520,1080] yield those frame canvas sizes; fixed-aspect height controls width, custom uses both. Typed Int64 clocks and immutable export snapshots remain required contracts.

## Limits / environment
- Native Metal/Vision/camera/mic, Retina/multi-display, compressed AAC decode and pixel/export parity remain host-limited; explicit decoder-unavailable behavior retained, PCM/metadata proofs are not device/pixel verification.
- SwiftPM --disable-sandbox under the outer sandbox and four jobs via temporary PATH wrapper. No sudo, TCC reset, real recordings or credentials committed. Unfiltered UI smoke invoked the signed app in --snapshot-ui mode; no live capture started. New dependency list empty.
