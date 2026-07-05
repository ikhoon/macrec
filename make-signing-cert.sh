#!/bin/zsh
# make-signing-cert.sh — create a STABLE self-signed code-signing certificate,
# once. Signing meeting-capture with this cert keeps its TCC grants across
# rebuilds (the signature's Designated Requirement becomes identifier +
# certificate based instead of the per-build cdhash).
# Idempotent: if an identity with this name already exists, do nothing.
#   ⚠ Never delete/regenerate this cert — that changes the DR and breaks the
#   grants again.
#
# Security: the private key lives ONLY in the login keychain — deliberately no
# file backup. (An on-disk .p12 with a known password would let any user-level
# process copy the key, sign itself as macrec, and inherit the mic/system-audio
# TCC grants.) The keychain ACL is scoped to /usr/bin/codesign (-T) rather than
# all applications (-A), so any other process touching the key triggers a
# keychain prompt. If the key is ever lost (keychain reset, new machine), just
# re-run this script and re-grant the permissions once.
set -e

CERT_NAME="MeetingCaptureSign"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# One-shot transport password for the keychain import only; the .p12 it
# protects lives in a mktemp dir deleted on exit and is never kept.
P12_PASS="$(head -c16 /dev/urandom | xxd -p)"

# Idempotency check: a self-signed cert has no trust settings, so it won't show
# under `-v` (valid) — check without -v.
if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "✅ already exists: '$CERT_NAME' (keeping it — DR stability)"
  security find-identity -p codesigning | grep "$CERT_NAME"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/ext.cnf" <<'EOF'
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=MeetingCaptureSign
O=meeting-recorder (local self-signed)
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
EOF

echo "▸ generating key + self-signed code-signing certificate (valid 10 years)…"
openssl req -new -x509 -days 3650 -nodes \
  -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -config "$TMP/ext.cnf" -extensions v3 2>/dev/null

openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout pass:"$P12_PASS" -name "$CERT_NAME" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
       -out "$TMP/cert.p12" -passout pass:"$P12_PASS" -name "$CERT_NAME" 2>/dev/null

echo "▸ importing into the login keychain (key usable by codesign only)…"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign

echo "🔐 done — the key exists only in your keychain (no file backup)."
echo "--- find-identity (codesigning) ---"
security find-identity -v -p codesigning | grep "$CERT_NAME" \
  && echo "✅ valid identity registered" \
  || echo "⚠ not in the valid list — may need trust settings (verify with a codesign test)"
