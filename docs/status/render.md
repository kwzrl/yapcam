# render status

## Done (verified)
- Shared Metal compositor, IOSurface decoder/cache, preview clock/audio/view, offline MP4/MOV/GIF exporter and M2 range/quality/bitrate/presets compile with swift build --disable-sandbox -j 4.
- Stable signed app build passed: PATH temporary Swift wrapper adds --disable-sandbox -j 4 to scripts/build-app.sh; CARGO_BUILD_JOBS=4. Bundle signed Yapcam Local Dev; no permissions reset.
- Root swift test --disable-sandbox -j 4 passed (ABI test); CARGO_BUILD_JOBS=4 cargo test --manifest-path core/Cargo.toml passed.
- Render tests run through a temporary /tmp validation manifest that adds Lead-owned missing target without changing repo Package.swift: 8 tests, 2 passed, 6 explicitly skipped because Metal device is unavailable. Settings validation and cancellation/existing-file preservation passed. GPU tests are NOT verified.

## In progress
- M1: harden shared clip audio mapping, add sync/cut/speed coverage and exact Project adapters once core lands.
- M2: GIF/range/preset controls implemented; performance metrics implemented, host measurements still open. Reconcile FEATURES presets when published.

## Assumptions
- Apple frameworks only; decode BGRA IOSurfaces via CVMetalTextureCache (no CPU pixel copy), linear-light Metal shading, sRGB targets/output, bounded nearest-sample cache.
- Preview/export use one RenderProjectSource evaluator and compositor. Exact Project initializers will be added after core implementation is integrated. Local test double lives only in render tests.
- Output refuses existing destinations; a same-directory hidden temporary file is atomically moved only after duration/dimensions/track verification. Cancellation removes its temporary file.
- Presets are provisional compact720/standard1080/high1440/ultra4K/gif until QA's FEATURES inventory arrives. GIF contains no audio.

## Blockers
- Git add and commit fail: sandbox denies /Users/larry/yapcam/.git/worktrees/render/index.lock despite declared writable root. Cannot emit a truthful READY commit. Initial commit attempted: "Implement shared Metal rendering and offline export pipeline". Source stays available in render worktree for Lead.
- Metal unavailable in this sandbox (MTLCreateSystemDefaultDevice returns nil). Pixel comparisons, actual video/GIF export and GPU performance tests explicitly skip; real host runs required.
- Core Swift wrapper on this branch only exports abiVersion; no Project surface yet. Independent implementation continues.
- SwiftPM nested sandbox unsupported; --disable-sandbox works within the outer execution sandbox.

## Requests (to Lead)
- Add testTarget(name: "YapcamRenderTests", dependencies: ["YapcamRender", "YapcamCore"]) to Package.swift; tests supplied under owned test directory.
- Resolve shared Git metadata write denial or commit reviewed owned files for render. No change to main attempted.
- Signal core integration, then renderer adds exact Project/query adapters.
- Arrange other-model-family review of critical Metal/export/audio code before merge (TEAMS rule 10).
- Run render GPU tests/performance on host with Metal access; they are explicitly unverified here.
