#!/usr/bin/env bash
# Creates "Twinkle Local Signing", a self-signed code signing identity in
# your login keychain, which ./build.sh signs Twinkle with. A fixed identity
# is what lets macOS keep Twinkle's sandbox container (cookies, history,
# settings) for Twinkle alone across rebuilds. Run once per Mac; the private
# key never leaves your keychain, so never copy it elsewhere or commit it.
set -euo pipefail
name="Twinkle Local Signing"
if security find-identity -p codesigning | grep -q "\"$name\""; then
  echo "\"$name\" is already in your keychain."
  exit 0
fi
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
cat > "$dir/cert.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
# The system's LibreSSL writes a .p12 that `security import` accepts.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$dir/cert.cnf" \
  -keyout "$dir/key.pem" -out "$dir/cert.pem" 2>/dev/null
pass="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -name "$name" -inkey "$dir/key.pem" -in "$dir/cert.pem" \
  -out "$dir/id.p12" -passout "pass:$pass"
security import "$dir/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$pass" -T /usr/bin/codesign >/dev/null
echo "Created \"$name\". The first ./build.sh asks for your login password to let codesign use it: choose Always Allow."
