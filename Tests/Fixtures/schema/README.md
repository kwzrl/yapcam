# Frozen schema migration corpus

Lead explicitly requested this corpus under Tests/Fixtures for Core M3 hardening.
These are synthetic JSON documents, with no recordings or credentials. Freeze the
bytes: do not regenerate them from the current Rust/Swift types. Add a new case for
new schema generations rather than rewriting old cases. The FNV-1a64 manifest
catches accidental edits; it is an integrity regression check, not authentication.

v1-minimal freezes the original missing-settings/defaults case. v1-populated
freezes nondefault settings, exact clip/source clocks, repeated source ranges,
Unicode notes, effects and a media fingerprint. Its deliberately synthetic media
fingerprint tests retention and missing-media reporting; it is not a valid movie.
v1-long-clock freezes >2^53 source/tail clocks and a >Int64 media byte count for
exact integer retention; it is a decoder-only synthetic long-session case.
v0-prerelease verifies the supported 0 -> 1 migration with absent settings.

The Rust harness checks every original JSON leaf survives migration, canonical
round trips are stable, defaults are restored, and future versions are refused.
The Swift harness opens copied minimal/prerelease packages through the real ABI,
checks save/reopen and immutable snapshots, and checks populated media remains an
explicit relink failure rather than silently replacing its fingerprint.
