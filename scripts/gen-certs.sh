#!/usr/bin/env bash
# Generates a local CA and server certificates for the Docker test servers.
# The CA is only ever trusted by the test containers and by Hrafn debug builds.
set -euo pipefail

CERT_DIR="$(cd "$(dirname "$0")/.." && pwd)/docker/certs"
DOMAINS=("alpha.test" "beta.test")
DAYS=825

mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

if [[ ! -f ca.key ]]; then
  echo "==> creating local test CA"
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -keyout ca.key -out ca.crt \
    -subj "/CN=Hrafn Test CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
fi

for domain in "${DOMAINS[@]}"; do
  echo "==> issuing certificate for $domain"
  # id-on-xmppAddr (1.3.6.1.5.5.7.8.5) alongside the DNS-IDs, so the certificate
  # exercises the identity forms RFC 6120 §13.7.1.2 expects from an XMPP server.
  cat > "$domain.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $domain
[ext]
subjectAltName = DNS:$domain, DNS:*.$domain, otherName:1.3.6.1.5.5.7.8.5;UTF8:$domain
extendedKeyUsage = serverAuth, clientAuth
basicConstraints = CA:FALSE
EOF
  openssl req -newkey rsa:2048 -nodes -sha256 \
    -keyout "$domain.key" -out "$domain.csr" -config "$domain.cnf"
  openssl x509 -req -in "$domain.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out "$domain.crt" -days "$DAYS" -sha256 \
    -extfile "$domain.cnf" -extensions ext
  cat "$domain.crt" "$domain.key" > "$domain.pem"
  rm -f "$domain.csr"
  chmod 644 "$domain.key" "$domain.pem"
done

echo
echo "CA fingerprint (SHA-256):"
openssl x509 -in ca.crt -noout -fingerprint -sha256
echo
echo "Certificates written to $CERT_DIR"
