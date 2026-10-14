#!/bin/zsh
# Runs Tests/E2E (real test target on main). Needs Metal + ffprobe, i.e. outside any sandbox.
# usage: scripts/qa/run-e2e.sh [XCTest filter, default PipelineE2E]
set -euo pipefail
cd "${0:A:h:h:h}"
swift test --disable-sandbox -j 4 --filter "${1:-PipelineE2E}"
