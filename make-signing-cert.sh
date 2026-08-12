#!/bin/bash
#  make-signing-cert.sh — a stable code identity, without an Apple account.
#
#  WHAT THIS FIXES, AND WHAT IT DOES NOT
#
#  It does NOT get past Gatekeeper. Nothing can, without a paid Developer ID and
#  notarization — that is Apple's signature, not something a script can forge,
#  and any "workaround" that claims otherwise is really asking the USER to
#  override Gatekeeper rather than the developer to satisfy it. Downloading a
#  build still needs the one-time right-click > Open. See package.sh.
#
#  What it fixes is trap 9, which has been costing real time every single build:
#
#      ad hoc      designated => cdhash H"9642..."
#      self-signed designated => identifier "com.prakritmaan.elemental"
#                                and certificate root = H"0ccc..."
#
#  An ad-hoc signature's designated requirement IS the code hash, and swiftc
#  mints a new one every compile. macOS keys TCC grants on that requirement, so
#  every rebuild looks like a different application and Location has to be
#  granted again — which is why the scene keeps falling back to the stored place
#  during development, with nothing in the log to say why.
#
#  A self-signed certificate makes the requirement "this bundle id, signed by
#  this certificate". Both halves are stable, so the grant survives every
#  rebuild. Same for Screen Recording.
#
#  Run once per machine. The certificate lives ten years; the private key never
#  leaves this Mac and is not in the repo (.gitignore covers *.p12 and *.key).

set -euo pipefail
DIR="$HOME/Elemental-Signing"
NAME="Elemental Self-Signed"
mkdir -p "$DIR"; cd "$DIR"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "==> '$NAME' already exists in the keychain. Nothing to do."
  echo "    Build with it:  ./build.sh"
  exit 0
fi

echo "==> creating $NAME"
cat > selfsign.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Elemental Self-Signed
O  = Elemental
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config selfsign.cnf -keyout elemental-self.key -out elemental-self.crt >/dev/null 2>&1

# Legacy PBE on purpose: OpenSSL 3 defaults to AES for PKCS#12 and the macOS
# `security` tool cannot read it — the import fails with "MAC verification
# failed (wrong password?)", which is a misleading way to say "unsupported
# cipher".
openssl pkcs12 -export -inkey elemental-self.key -in elemental-self.crt \
  -name "$NAME" -out elemental-self.p12 -passout pass:elemental \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1

security import elemental-self.p12 -k "$HOME/Library/Keychains/login.keychain-db" \
  -P elemental -T /usr/bin/codesign -A

echo "==> done. Rebuild and TCC grants will survive future rebuilds:"
echo "    ./build.sh"
echo
echo "Note: `security find-identity -v -p codesigning` will still say 0 valid"
echo "identities. That is about TRUST, not about signing — the certificate is"
echo "self-signed so nothing vouches for it, and codesign uses it regardless."
