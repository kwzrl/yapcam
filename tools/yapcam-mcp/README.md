# Yapcam MCP spike

A local Rust stdio server for editing a **closed** `.yapcam` package through the
same Rust command API as the editor. It does not run speech recognition, render,
export, or synchronize with an open editor. Keep the editor and other writers
closed for the whole session. Quit the server before reopening the project.

## Build and register

From the repository root:

```sh
CARGO_BUILD_JOBS=4 cargo build --release --manifest-path tools/yapcam-mcp/Cargo.toml
claude mcp add yapcam -- /absolute/path/to/repo/tools/yapcam-mcp/target/release/yapcam-mcp --project /absolute/path/to/Recording.yapcam
```

Start Claude Code with that configuration. The server's stdout is exclusively
newline-delimited JSON-RPC; diagnostics go to stderr. It implements MCP
[2025-06-18 stdio](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)
and [tools](https://modelcontextprotocol.io/specification/2025-06-18/server/tools),
plus `ping`. Unsupported initialization versions negotiate `2025-06-18`; clients
must accept that version to continue. No SDK or extra runtime dependencies:
`serde_json` and the path dependency `yapcam-core` (which already uses serde).
License check against local crate manifests: serde, serde_core, serde_derive,
serde_json, itoa, proc-macro2, quote and syn use MIT OR Apache-2.0; memchr uses
Unlicense OR MIT; zmij uses MIT; unicode-ident uses (MIT OR Apache-2.0) AND
Unicode-3.0. See Cargo.lock for exact versions. No new third-party library family is introduced.

## Tools

| Tool | Arguments / result |
|---|---|
| `project_summary` | Duration in ns, clip mappings, recording segments, zooms, caption count, transcript/click/key/camera/mic signals, undo/redo counts |
| `read_project` | Optional `section`: top-level key such as `timeline`, `canvas`, `audio`, `zooms`; otherwise complete project |
| `read_transcript` | Optional `source`: `auto` (default), `captions`, `recording`; optional `start_ns`, `end_ns` in edited timeline |
| `read_events` | Optional `type`: `all` (clicks and keys), `click` (mouse down), `key`; optional `start_ns`, `end_ns` in edited timeline |
| `apply` | `command`: one core JSON command; returns core ChangeSet (`changed`, `createdIDs`) |
| `batch` | `commands`: array of core commands, atomic and one undo step |
| `undo` / `redo` | One history step; `changed=false` at boundary |
| `save` | Persist via core, preserving original `project.json.pre-mcp` |

Ranges are half-open integer nanoseconds: one second is 1000000000. Transcript
filters select overlapping words; event filters select timestamps. Event records
retain captured fields, including x/y where present, and add source/timeline
clock values. Key presses do not necessarily have positions. Signals/counts for
clicks and keys refer to the retained timeline; camera/mic indicate recorded tracks.

`read_transcript` prefers project captions so corrections survive. A caption with
word timing is flattened; otherwise its entire text span is returned, without
inventing individual word timing. Explicit `source=recording` reads the original
Capture transcript and maps it through current clips using core's import logic on
a disposable snapshot. Its `source_words` retain original source timing and are
**not** affected by the timeline range filter; `words` are mapped and filtered.
Recognition warnings/locale are returned with recording transcripts. Missing
transcripts return `available=false`; malformed transcripts return a tool error.
Reading does not import captions into the actual project. There is no sentence
grouping or pagination in this spike.

The complete agent-facing examples are in [src/commands.md](src/commands.md) and
embedded in both `apply` and `batch` descriptions returned by `tools/list`.
They cover split, delete_range, zoom edits, speed, process_silence, auto_zooms,
import_transcript, settings, typing acceleration, presets, captions, and batches.
Advanced commands pass through to core as well; see ../../core/README.md and
../../docs/FORMATS.md. Unknown commands fail explicitly.

A batch executes sequentially: later times refer to the state after earlier edits.
For several cuts chosen in the original timeline, order them right-to-left or use
`process_silence`, which merges overlaps and handles that ordering. Add manual
zooms using final timeline times, or run `auto_zooms` last.

## Persistence

Opening and editing never write the package. Core snapshot mode disables journals
even if a command sets `autosave=true`, and also covers undo/redo. An unedited
capture without project.json is initialized in memory. Existing core autosave
recovery is honored on open. Nothing is automatically saved on EOF or exit.

`save` first creates and fsyncs `project.json.pre-mcp` from the existing primary
using exclusive creation; an existing backup is never overwritten. If no primary
exists, there is nothing to back up. Core then atomically saves project.json,
maintains project.json.prev, and clears the autosave journal. The backup captures
the on-disk primary, not a newer recovered autosave state. File paths use core's
package containment checks. History is session-local and is not persisted.
There is no cross-process package lock or concurrent editor detection in this
spike. Do not use two writers. The backup is for recovery, not concurrency control.

## Get a transcript first

Recording alone does not create `recording/transcript.json`. In the signed Yapcam
app, open a finished recording with microphone audio, select **Edit by transcript**
and click **Generate transcript from speech**. Set the transcription language and
optional keyterms first. Allow Speech Recognition if requested; recognition must
be available on-device for the chosen language. Wait for generation to finish,
save, and close the editor before starting MCP. For an old cached transcript use
**Regenerate transcript…**; that replaces corrected/hidden words but preserves cuts.

The editor document calls the app-provided transcriber; Capture's
`TranscriptionService.transcribe` writes `recording/transcript.json` and the editor
imports it as captions. It requires a complete recording and defaults to mic audio,
falling back to system audio per segment. The editor's transcript inspector is
currently gated on microphone presence, even though the service itself supports
system audio. For system-only packages, use an existing externally generated
schema-1 transcript or a Capture-service integration; this CLI does not bypass
that UI restriction or invoke recognition. Already imported project captions work
even without a transcript file. Recognition can be partial; inspect `warnings`.

Implementation references: `Sources/YapcamEditor/Transcript.swift`,
`EditorDocument.swift`, `TextItems.swift`, and
`Sources/YapcamCapture/TranscriptionService.swift`.

## Evaluation prompt

Copy each real recording to a working evaluation directory and register that copy.
Prepare speech transcripts as above, then use this prompt:

> Tighten this recording: inspect the project summary, transcript and click/key
> events. Remove obvious filler utterances and long pauses conservatively, keeping
> speech natural and leaving breathing room. Do not remove meaningful words just
> because they can be fillers. Add restrained zooms on important clicks. Use one
> batch so the complete edit is one undo step; order cuts right-to-left and account
> for their timing before adding zooms. If speech evidence is missing or partial,
> explain what is missing instead of guessing cuts. Inspect the resulting project,
> explain the cuts and zooms, and save it. Do not export.

Then quit MCP, open the copy in Yapcam, preview and decide whether you would export
without manual rework. Spike success: at least two of three recordings meet that
criterion. The server cannot judge audible edit seams or visual importance itself.
Filler detection needs language/context and accurate recognition of disfluencies;
recognizers may omit them entirely. Transcript gaps alone cannot distinguish real
silence from unrecognized speech. Audio listening/VAD and preview would improve
confidence, and are outside this server's current tool set.

## Verification

```sh
CARGO_BUILD_JOBS=4 cargo test --manifest-path tools/yapcam-mcp/Cargo.toml
zsh core/scripts/with-temp.sh env CARGO_BUILD_JOBS=4 cargo test --manifest-path core/Cargo.toml
cargo fmt --manifest-path tools/yapcam-mcp/Cargo.toml --check
```

Integration tests spawn the real stdio binary on disposable copies of
`Tests/Fixtures/synthetic/basic.yapcam`, add synthetic speech evidence, exercise
initialize/list/read/batch/save, and verify rollback, history, exact timing,
package immutability before save, backup preservation, caption fallback, protocol
errors, and backup symlink containment. Temporary copies are removed on teardown.
