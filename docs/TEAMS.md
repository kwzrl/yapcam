# Teams, ownership and rules

| Team | Agent | Branch / worktree | Owns |
|---|---|---|---|
| Lead | Claude Opus 5.5 | `main` in `~/yapcam` | `Package.swift`, `core/include/yapcam_core.h`, `docs/ARCHITECTURE.md`, `docs/FORMATS.md`, `docs/SWIFT_API.md`, `docs/STATUS.md`, `Tests/Fixtures/synthetic/`, integration into `main` |
| ui | Claude Sonnet 5.5 | `team/ui` · `~/yapcam-team/ui` | `Sources/Yapcam/**` (app shell, vertical toolbar, source pickers, area overlay, countdown, settings, permissions onboarding, menus), `Resources/**` |
| capture | Codex gpt-6.1-sol (high) | `team/capture` · `~/yapcam-team/capture` | `Sources/YapcamCapture/**`, `Tests/YapcamCaptureTests/**` |
| core | Codex gpt-6.1-sol (high) | `team/core` · `~/yapcam-team/core` | `core/**` except the header, `Sources/YapcamCore/**`, `Tests/YapcamCoreTests/**` |
| render | Codex gpt-6.1-sol (high) | `team/render` · `~/yapcam-team/render` | `Sources/YapcamRender/**`, `Tests/YapcamRenderTests/**` |
| editor | Claude Sonnet 5.5 | `team/editor` · `~/yapcam-team/editor` | `Sources/YapcamEditor/**`, `Tests/YapcamEditorTests/**` |
| ref → qa | Claude Sonnet 5.5 (+ Codex gpt-6-astra / Opus for reviews) | `team/qa` · `~/yapcam-team/qa` | `docs/FEATURES.md`, `docs/reference/**`, `docs/TESTING.md`, `scripts/qa/**`, `Tests/E2E/**` |

Each team also owns `docs/status/<team>.md` (its own short status) and nothing else.

## Rules

1. Touch only files you own. Need a change elsewhere (header, Package.swift, another
   team's API)? Write it in your `docs/status/<team>.md` under **Requests** and work on
   something else; Lead resolves it.
2. Code against `docs/SWIFT_API.md` and `docs/FORMATS.md`. If you own an API there,
   implement exactly that surface (additions are fine, breaking changes go via Lead).
3. Keep your branch building: `scripts/build-app.sh` and `swift test` and
   `cargo test --manifest-path core/Cargo.toml` must pass before every commit you
   mark ready. Use `CARGO_BUILD_JOBS=4` and `swift build -j 4`.
4. Rebase on local `main` at least every time Lead announces an integration
   (`git fetch . main:main` is not needed — worktrees share the repo; `git rebase main`).
   Never rewrite `main`. Never force-push anything but your own team branch.
5. Commit small, meaningful commits. Push your branch to `origin` when it builds.
6. No fake implementations. Something not done = explicit error/`unavailable` state and
   an entry in your status file. No hidden TODOs in central flows.
7. Real captures go to `~/Movies/Yapcam/QA/<team>/` and are deleted when no longer
   needed. Never commit recordings, credentials or personal paths.
8. Every app build uses bundle id `mov.yapcam.Yapcam` signed with `Yapcam Dev Signing`,
   so macOS permissions already granted stay valid. Do not reset TCC.
9. A new macOS permission dialog or other blocker: note it under **Blockers** in your
   status file and continue with independent work.
10. Your own critical code is reviewed by the other model family before Lead merges it.
11. Third-party dependencies need a license check (record in `docs/THIRD_PARTY.md`
    via a Request to Lead). Prefer Apple frameworks and the Rust std/serde.
12. Reference analysis of Screen Studio (REA, docs, practical use) is for understanding
    behavior only. Never copy its code, assets, strings or binaries into the repo.
