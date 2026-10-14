# Team core (Rust core + Swift wrapper)

Own: `core/**` (not the header), `Sources/YapcamCore/**`, `Tests/YapcamCoreTests/**`.

## M1 (in this order, commit after each)
1. `model.rs`: serde types for `session.json` (FORMATS.md) and `project.json`
   (schema_version 1). Parse the synthetic fixtures in `Tests/Fixtures/synthetic/`.
2. Persistence: `yc_project_create/open/save/to_json/clone/free`. Atomic save
   (tmp → fsync → rename, keep `.prev`), fallback to `.prev` on corrupt JSON,
   refuse newer schema with `YC_ERR_UNSUPPORTED_VERSION`, migration hook.
   Media check: missing files → `YC_ERR_MISSING_MEDIA` with the list in the error text
   (project still openable via a relink later — design for it).
3. Time model: segments → global `src_ns`; clips map `tl_ns` → `src_ns` with speed;
   `src_ns` → (segment, file_ns) per track using `track_start_ns`.
4. Commands + undo/redo (`yc_apply/undo/redo/can_*`): split, delete_range, set_speed,
   add/update/remove zoom, generic `set` on documented paths, batch.
5. `yc_frame_at`: canvas (aspect + output size), background, padding, corner radius,
   shadow, inset; screen crop/dest incl. zoom interpolation (ease in/out, smooth
   spring-like curve); cursor position from events (interpolated + smoothing), scale,
   idle hide, click effect progress; camera rect from layout; audio gains.
   No allocation on this path.
6. `yc_query`: clips, zooms, audio ranges, cursor click list, duration.
7. Swift wrapper `Project` exactly per `docs/SWIFT_API.md`.

## M2
Auto-zoom generation from clicks/typing (`{"op":"auto_zooms"}`), all canvas/cursor/
camera/layout options from FEATURES.md, layout segments over time, migrations.

## Tests (required)
- Unit tests for every command, undo/redo round-trips, serialization round-trip.
- Property test: random sequences of split/delete/speed (≥10 000 ops) keep audio,
  video and event mapping identical (no drift); `tl→src→tl` invariants.
- Golden tests for `yc_frame_at` at fixed times from fixture projects.
- `cargo test` + `swift test` green before marking READY.
