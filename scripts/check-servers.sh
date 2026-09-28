#!/usr/bin/env bash
# Confirms both test servers speak XMPP on the ports Hrafn dials: STARTTLS on
# 5222 and Direct TLS on 5223. Runs in CI, where the Swift transport tests
# cannot (they need Apple platforms).
set -euo pipefail

cd "$(dirname "$0")/.."
status=0

check_starttls() {
  local host=$1 port=$2 domain=$3
  printf '==> %s:%s STARTTLS ... ' "$host" "$port"
  local response
  response=$(printf "<?xml version='1.0'?><stream:stream to='%s' version='1.0' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>" "$domain" \
    | timeout 10 openssl s_client -connect "$host:$port" -starttls xmpp -xmpphost "$domain" -quiet 2>/dev/null \
    | head -c 2000 || true)
  if grep -q "stream:features" <<<"$response"; then
    echo "ok"
  else
    echo "FAILED"
    status=1
  fi
}

check_directtls() {
  local host=$1 port=$2 domain=$3
  printf '==> %s:%s Direct TLS ... ' "$host" "$port"
  # XEP-0368 also requires ALPN xmpp-client; openssl is asked for it explicitly.
  local response
  response=$(printf "<?xml version='1.0'?><stream:stream to='%s' version='1.0' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>" "$domain" \
    | timeout 10 openssl s_client -connect "$host:$port" -alpn xmpp-client \
        -servername "$domain" -quiet 2>/dev/null | head -c 2000 || true)
  if grep -q "stream:" <<<"$response"; then
    echo "ok"
  else
    echo "FAILED"
    status=1
  fi
}

# XEP-0363 upload services over HTTPS (any HTTP answer will do).
check_https() {
  local port=$1 host=$2
  printf '==> 127.0.0.1:%s HTTPS (%s) ... ' "$port" "$host"
  if curl -sk -o /dev/null --max-time 10 --resolve "$host:$port:127.0.0.1" "https://$host:$port/"; then
    echo "ok"
  else
    echo "FAILED"
    status=1
  fi
}

check_starttls 127.0.0.1 5222 alpha.test
check_directtls 127.0.0.1 5223 alpha.test
check_starttls 127.0.0.1 15222 beta.test
check_directtls 127.0.0.1 15223 beta.test
check_https 5281 upload.alpha.test
check_https 5443 upload.beta.test

exit $status
