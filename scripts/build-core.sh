#!/bin/zsh
# Builds the Rust core static library that the Swift package links against.
set -euo pipefail
ROOT="${0:A:h:h}"
cargo build --release --manifest-path "$ROOT/core/Cargo.toml"
