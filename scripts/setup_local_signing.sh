#!/bin/bash
# Stable local code-signing identity. Ad-hoc ("Sign to Run Locally") changes the
# cdhash on every rebuild, so macOS drops the Screen Recording grant. This
# certificate keeps the same designated requirement across rebuilds.
set -euo pipefail

NAME="PrettyShot Local"
DIR="${HOME}/Library/Application Support/PrettyShot/Signing"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
mkdir -p "$DIR"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Certificate already in login keychain: $NAME"
  security find-identity -v -p codesigning | grep -F "$NAME" || true
  exit 0
fi

CFG="$DIR/openssl.cnf"
CRT="$DIR/PrettyShotLocal.crt"
KEY="$DIR/PrettyShotLocal.key"
P12="$DIR/PrettyShotLocal.p12"

cat > "$CFG" << 'EOF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = PrettyShot Local
[ ext ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = CA:false
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$KEY" -out "$CRT" -config "$CFG"
PASS="prettyshot-local"
openssl pkcs12 -export -out "$P12" -inkey "$KEY" -in "$CRT" -name "$NAME" -passout pass:"$PASS"

security import "$P12" -k "$KEYCHAIN" -f pkcs12 -P "$PASS" -A
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$CRT"

echo "Installed $NAME"
security find-identity -v -p codesigning | grep -F "$NAME"
