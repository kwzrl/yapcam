#!/bin/sh
# Fails if tracked files include media, credentials or personal home paths.
cd "$(git rev-parse --show-toplevel)" || exit 2
bad=0
git ls-files | grep -Ei '\.(mov|mp4|m4a|wav|mp3|gif|heic|p12|pem|key)$' | grep -v '^Tests/Fixtures/' && bad=1
git ls-files -z | xargs -0 grep -lEI '/Users/[a-z0-9_-]+/|AKIA[0-9A-Z]{16}|BEGIN (RSA |EC )?PRIVATE KEY|sk-[A-Za-z0-9]{20,}' 2>/dev/null | grep -v 'scripts/qa/privacy-scan.sh' && bad=1
[ $bad = 0 ] && echo "privacy scan clean" || { echo "privacy scan FAILED"; exit 1; }
