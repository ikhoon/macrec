#!/bin/zsh
# make-signing-cert.sh — STABLE self-signed 코드서명 인증서를 1회 생성한다.
#   meeting-capture 를 이 인증서로 서명하면 TCC 권한이 rebuild 후에도 유지된다
#   (서명의 Designated Requirement 가 cdhash가 아니라 identifier+cert 기반이 되므로).
#   멱등: 동일 이름 identity가 이미 있으면 아무것도 안 한다.
#   ⚠ 이 인증서는 절대 재생성/삭제하지 말 것 (재생성하면 DR 바뀌어 권한 다시 깨짐).
set -e

CERT_NAME="MeetingCaptureSign"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
BACKUP_DIR="$HOME/.config/meeting-recorder"
BACKUP="$BACKUP_DIR/${CERT_NAME}.p12"
P12_PASS="meeting-capture"

# 멱등 체크: self-signed는 신뢰 설정이 없어 -v(valid)엔 안 잡히므로 -v 없이 확인한다.
if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "✅ 이미 존재: '$CERT_NAME' (재생성 안 함 — DR 안정성 유지)"
  security find-identity -p codesigning | grep "$CERT_NAME"
  exit 0
fi

TMP=$(mktemp -d)
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

echo "▸ 키 + 자체서명 코드서명 인증서 생성 (10년 유효)…"
openssl req -new -x509 -days 3650 -nodes \
  -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -config "$TMP/ext.cnf" -extensions v3 2>/dev/null

openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout pass:"$P12_PASS" -name "$CERT_NAME" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
       -out "$TMP/cert.p12" -passout pass:"$P12_PASS" -name "$CERT_NAME" 2>/dev/null

echo "▸ 로그인 키체인에 import (-A: 모든 앱 접근 허용 → codesign 프롬프트 회피)…"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" -A

mkdir -p "$BACKUP_DIR"; cp "$TMP/cert.p12" "$BACKUP"
chmod 600 "$BACKUP"
rm -rf "$TMP"

echo "🔐 백업: $BACKUP (pass: $P12_PASS) — 보관하세요 (분실 시 권한 재허여 필요)"
echo "--- find-identity (codesigning) ---"
security find-identity -v -p codesigning | grep "$CERT_NAME" \
  && echo "✅ valid identity 등록됨" \
  || echo "⚠ valid 목록에 없음 — 신뢰 설정 필요할 수 있음 (codesign 테스트로 확인)"
