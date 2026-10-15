#!/bin/zsh
# Creates a local, self-signed code-signing identity "Yapcam Dev Signing" in a dedicated
# keychain, so builds keep a stable app identity (macOS privacy permissions survive
# rebuilds) and codesign never shows keychain password dialogs. Idempotent.
set -euo pipefail

NAME="Yapcam Dev Signing"
KEYCHAIN="${YAPCAM_SIGN_KEYCHAIN:-$HOME/Library/Keychains/yapcam-signing.keychain-db}"
PASS_FILE="${YAPCAM_SIGN_KEYCHAIN_PASS_FILE:-$HOME/.config/yapcam/signing-keychain-pass}"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
  echo "identity '$NAME' already present in $KEYCHAIN"
  exit 0
fi

umask 077
mkdir -p "${PASS_FILE:h}"
[[ -f "$PASS_FILE" ]] || /usr/bin/openssl rand -hex 24 > "$PASS_FILE"
PASS="$(<"$PASS_FILE")"

[[ -f "$KEYCHAIN" ]] || security create-keychain -p "$PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"          # no auto-lock
security unlock-keychain -p "$PASS" "$KEYCHAIN"

WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK:?}"' EXIT
cat > "$WORK/cfg" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cfg" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
P12_PASS="$(/usr/bin/openssl rand -hex 12)"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/id.p12" -passout "pass:$P12_PASS" -name "$NAME"
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null

# Add the keychain to the user search list (keeps existing entries).
existing=(${(f)"$(security list-keychains -d user | tr -d '"' | sed 's/^ *//')"})
if [[ ${existing[(Ie)$KEYCHAIN]} -eq 0 ]]; then
  security list-keychains -d user -s "${existing[@]}" "$KEYCHAIN"
fi

echo "created '$NAME' in $KEYCHAIN"
echo "Grant Screen & System Audio Recording, Accessibility and Input Monitoring to build/Yapcam.app once."
