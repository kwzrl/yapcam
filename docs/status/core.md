# core status

## Done (verified)
- M1.1 model: cargo test (fixture + project round-trip), signed app build, swift test all passed.

## In progress
- M1 implementation complete through Swift wrapper; final Swift integration/golden checks and signed build running.
- M2 now uses QA inventory read-only from sibling QA worktree; implementing automatic zooms/typing speed, spring options, cursor ranges/loop, audio automation, presets, and autosave.
- M1.2: persistence and C handle lifecycle implemented; tests running. M1.3 timing next.

## Next
- M2 feature tests and integration checks; retry normal git staging once Lead fixes shared git metadata access.

## Blockers
- Git staging is denied by the workspace sandbox: cannot create shared `/Users/larry/yapcam/.git/worktrees/core/index.lock` despite declared writable root. First attempted model commit could not be created. Lead must fix the sandbox grant or commit reviewed owned files; no READY commit or push can be emitted until resolved. Continuing implementation and verification.
- SwiftPM nested sandbox unsupported (`sandbox_apply: Operation not permitted`); validated workaround uses `swift --disable-sandbox -j 4` via an untracked temporary wrapper for build-app.sh. Stable app signing succeeded.

## Requests (to Lead)
- Cross-model review of critical Rust persistence/time/FFI code before integration (team rule 10).
- QA inventory now readable in sibling QA worktree; not yet committed on local main. Please integrate it.
- M2 ABI extensions needed for masks/highlights, entrance/exit transforms, per-camera shadow and cursor motion blur: existing YcFrame cannot carry these. Please extend header/contracts or agree a second fixed-size frame extension struct before renderer implementation.
- UI video import will need `Project.importVideo`; core Swift helper in progress.
- Media fingerprint uses algorithm-prefixed FNV-1a64 of first MiB for change detection, not security/authenticity; approve or request SHA-256 before format freezes.

## Assumptions
- Effect targets and camera positions use normalized [0,1] coordinates; canvas lengths are output pixels. Generic set rejects unknown setting keys.
- Schema 1 defaults: 1920×1080, 48 px padding, centered fit, manual zoom scale 1…16. Settings are reversible through commands.
- Existing serde/serde_json dependencies only (MIT/Apache-2.0); no new dependencies.
