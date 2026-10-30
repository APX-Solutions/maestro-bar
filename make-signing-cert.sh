#!/bin/bash
# Makes the certificate Maestro Bar is signed with. Once per Mac that builds:
#
#   ./make-signing-cert.sh
#
# An ad-hoc signature identifies the app by a hash of its code, so every build
# is a stranger to macOS and every permission granted to the last one silently
# stops applying: System Settings shows Maestro Bar switched ON while the app
# asks again, and the toggle does nothing because it is already on. Signed with
# a certificate, the app is identified by its bundle id plus that certificate
# instead, and a grant survives every rebuild and every update.
#
# Self-signed is enough for that — nobody's trust is involved, only sameness.
# It does not remove the Gatekeeper warning; a Developer ID certificate would.
#
# The identity lives in a keychain of its own, ~/.maestro/signing.keychain-db,
# with a password only build.sh reads. Not the login keychain: there codesign
# stops the build to ask for the login password, and not every Mac has a login
# keychain whose password its owner knows.
#
# Keep both files. A new certificate is a new identity and costs everyone one
# more permission prompt. To build releases on another Mac, copy the two files
# into its ~/.maestro.
set -euo pipefail

NAME="MaestroBar Code Signing"
KC="$HOME/.maestro/signing.keychain-db"
PASSFILE="$HOME/.maestro/signing.pass"

if [ -f "$KC" ] && security find-identity -p codesigning "$KC" | grep -q "\"$NAME\""; then
  echo "==> \"$NAME\" is already in $KC. Nothing to do."
  exit 0
fi

mkdir -p "$HOME/.maestro"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# digitalSignature is what the first attempt ("Maestro Bar Signing") lacked:
# without it the keychain lists the certificate and codesign still answers
# "no identity found".
cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# /usr/bin/openssl (LibreSSL) on purpose: a Homebrew OpenSSL 3+ writes a .p12
# that `security import` refuses.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$tmp/cert.cnf" -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
P12PASS=$(uuidgen)
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
  -name "$NAME" -passout "pass:$P12PASS" -out "$tmp/id.p12"

PASS=$(uuidgen)
rm -f "$KC"
security create-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"          # no auto-lock mid-build
security unlock-keychain -p "$PASS" "$KC"
security import "$tmp/id.p12" -k "$KC" -P "$P12PASS" -T /usr/bin/codesign >/dev/null
# Without this, macOS shows a "codesign wants to use the key" dialog every build.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null

printf %s "$PASS" > "$PASSFILE"
chmod 600 "$PASSFILE" "$KC"

echo "==> Made \"$NAME\" in $KC. ./build.sh signs with it from now on."
