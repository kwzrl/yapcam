#!/bin/zsh
# Keep all temporary outputs of one Core verification run under one owned root.
set -euo pipefail

if (( $# == 0 )); then
    print -u2 'Usage: core/scripts/with-temp.sh command [args...]'
    exit 2
fi

run_dir="$(mktemp -d "${TMPDIR:-/private/tmp/}/yapcam-core-run.XXXXXXXX")"
cleanup() { print -r -- "Core temp cleanup: $run_dir"; rm -rf -- "$run_dir"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

export YAPCAM_CORE_TMP="$run_dir"
mkdir "$run_dir/tmp"
export TMPDIR="$run_dir/tmp/"
# Do not exec: this shell must run its EXIT trap even when the command fails.
"$@"
