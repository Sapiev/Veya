#!/usr/bin/env bash
# Creates the self-signed code signing certificate releases are signed with.
# Run once and keep the output safe: the certificate is the app's identity, so
# replacing it makes users sign in again after the next update.
#
# Usage: scripts/make-signing-certificate.sh <output-dir>
# Writes veya-signing.p12 and its password; docs/release.md turns them into secrets.
set -euo pipefail

NAME="Veya Release"
dir="${1:?usage: scripts/make-signing-certificate.sh <output-dir>}"
mkdir -p "$dir"
umask 077
openssl=/usr/bin/openssl
"$openssl" rand -base64 24 > "$dir/veya-signing.password"
# 20 years: codesign refuses an expired certificate, and a new one is a new identity.
"$openssl" req -x509 -newkey rsa:3072 -nodes -days 7300 -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$dir/key.pem" -out "$dir/cert.pem"
"$openssl" pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" -name "$NAME" \
    -passout file:"$dir/veya-signing.password" -out "$dir/veya-signing.p12"
rm "$dir/key.pem" "$dir/cert.pem"
echo "Created $dir/veya-signing.p12 (identity \"$NAME\")"
