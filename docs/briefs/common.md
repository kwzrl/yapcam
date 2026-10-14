# Brief for every Yapcam team

Read first: `docs/TEAMS.md` (ownership + rules), `docs/ARCHITECTURE.md`,
`docs/FORMATS.md`, `docs/SWIFT_API.md`, `docs/STATUS.md`, your `docs/status/<team>.md`,
and `docs/FEATURES.md` once it exists (reference feature inventory).

Product: Yapcam, a native macOS (Apple Silicon, macOS 15+) screen recorder and editor.
Full local recording + editing environment, functionally matching Screen Studio 4.0.4
(the fixed reference), with its own calm, precise, professional design. No account,
no cloud, no watermark. Apache 2.0. The full feature inventory is the goal, not an MVP.

Milestones:
- **M1 – end-to-end path (tonight, first):** record display + system audio + cursor
  events → `.yapcam` package → open in editor → preview with background/padding and a
  manual zoom → export MP4 1080p. Integrated on `main` as early as possible.
- **M2 – full reference inventory:** every local feature in `docs/FEATURES.md`.
- **M3 – hardening:** recovery, missing media, low disk, performance numbers, QA.

Working loop: implement → build + tests → real check where possible → commit →
update `docs/status/<team>.md` (Done = verified only, with how) → next item.
When blocked, write it down and take the next independent item. Do not stop to ask
about reversible details; decide, note the assumption in your status file, continue.

Hardware here: Mac mini M4, one 1680×1050 display (no Retina, no second display),
**no camera and no microphone**. Implement camera/mic fully and test the
"no device"/"device lost" paths; state clearly that real-device tests are open.
Permissions for `mov.yapcam.Yapcam` (screen + system audio, mic, camera, accessibility,
input monitoring) are granted. Build with `scripts/build-app.sh` (builds Rust core too).

Signal completion of a work package to Lead by writing a one-line entry at the top of
your status file: `READY <commit> <what>` — Lead polls these files.
