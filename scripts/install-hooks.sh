#!/bin/zsh
# Installs a pre-commit hook that blocks commits containing secrets or media files.
set -euo pipefail
ROOT="${0:A:h:h}"
cat > "$ROOT/.git/hooks/pre-commit" <<'HOOK'
#!/bin/zsh
set -euo pipefail
gitleaks git --staged --redact --no-banner || { echo "pre-commit: gitleaks found a possible secret" >&2; exit 1; }
if git diff --cached --name-only --diff-filter=AM | grep -Ei '\.(mov|mp4|m4a|wav|caf|aac|p12|pem|key)$' | grep -v '^Tests/Fixtures/synthetic/'; then
  echo "pre-commit: media or key files must not be committed" >&2; exit 1
fi
HOOK
chmod +x "$ROOT/.git/hooks/pre-commit"
echo "pre-commit hook installed"
