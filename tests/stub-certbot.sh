#!/usr/bin/env bash
# ==========================================================================
# TEST-ONLY certbot simulator for the CP10 battery (NEVER used on a VPS).
# Mimics the exact certbot surface the installer uses:
#   certbot certonly --webroot -w WEBROOT -d DOMAIN \
#     --non-interactive --agree-tos [--email E --no-eff-email |
#      --register-unsafely-without-email] [--keep-until-expiring]
#
# What it does (in order, like the real thing):
#   1. --keep-until-expiring: if a certificate already exists -> exit 0.
#   2. OPS_STUB_FAIL=1 -> simulates an ACME server failure (exit 1) so the
#      battery can prove the installer fails CLOSED (TLS GATE, loopback-only).
#   3. ACME HTTP-01 round-trip: writes a challenge token into
#      WEBROOT/.well-known/acme-challenge/<token> and then fetches it back
#      THROUGH THE REAL EDGE (http://127.0.0.1:$OPS_STUB_HTTP80/...), i.e.
#      HAProxy :80 frontend -> managed acme ACL -> backend OPS_TERM_ACME ->
#      internal nginx -> webroot. A failed round-trip = failed issuance.
#   4. "Issues" a leaf certificate for -d DOMAIN signed by the test CA
#      ($OPS_STUB_CA_DIR/ca.crt + ca.key) into $OPS_STUB_LIVE_BASE/live/DOMAIN/
#
# Env:
#   OPS_STUB_HTTP80     port of the harness HAProxy :80 frontend (required)
#   OPS_STUB_CA_DIR     directory holding ca.crt + ca.key (required)
#   OPS_STUB_LIVE_BASE  letsencrypt live base (default /tmp/stub-live)
#   OPS_STUB_FAIL       1 = simulate issuance failure
# ==========================================================================
set -u

webroot=""; domain=""
while [ $# -gt 0 ]; do
  case "$1" in
    -w) webroot="$2"; shift 2 ;;
    -d) domain="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -z "$webroot" ] || [ -z "$domain" ]; then
  echo "stub-certbot: missing required -w WEBROOT / -d DOMAIN" >&2
  exit 2
fi

LIVE_BASE="${OPS_STUB_LIVE_BASE:-/tmp/stub-live}"
live="$LIVE_BASE/live/$domain"

if [ "${OPS_STUB_FAIL:-0}" = "1" ]; then
  echo "stub-certbot: simulated ACME failure (OPS_STUB_FAIL=1) — rejecting challenge for $domain" >&2
  exit 1
fi

# 1. renewal no-op
if [ -r "$live/fullchain.pem" ] && [ -r "$live/privkey.pem" ]; then
  echo "stub-certbot: certificate already present, keeping until expiring: $live"
  exit 0
fi

# 3. ACME HTTP-01 round-trip through the REAL edge
mkdir -p "$webroot/.well-known/acme-challenge"
tok="stub-token-$(date +%s)-$$"
body="challenge-response-$tok"
printf '%s' "$body" > "$webroot/.well-known/acme-challenge/$tok"
url="http://127.0.0.1:${OPS_STUB_HTTP80:-80}/.well-known/acme-challenge/$tok"
got="$(curl -sf -m 5 -H "Host: $domain" "$url" 2>/dev/null)"
if [ "$got" != "$body" ]; then
  echo "stub-certbot: ACME challenge round-trip FAILED via $url (got: '${got:-<none>}')" >&2
  exit 3
fi
echo "stub-certbot: ACME challenge round-trip OK through the real edge ($url)"

# 4. issue a leaf certificate signed by the test CA
mkdir -p "$live"
cfg="$(mktemp)"
cat > "$cfg" <<EOF
[req]
distinguished_name = dn
[dn]
[ext]
subjectAltName = DNS:$domain
EOF
openssl req -new -newkey rsa:2048 -nodes \
  -keyout "$live/privkey.pem" -subj "/CN=$domain" \
  -out "$live/$domain.csr" 2>/dev/null || { rm -f "$cfg"; exit 4; }
openssl x509 -req -in "$live/$domain.csr" \
  -CA "$OPS_STUB_CA_DIR/ca.crt" -CAkey "$OPS_STUB_CA_DIR/ca.key" \
  -CAcreateserial -days 30 -sha256 -out "$live/fullchain.pem" \
  -extfile "$cfg" -extensions ext 2>/dev/null || { rm -f "$cfg"; exit 4; }
rm -f "$cfg" "$live/$domain.csr"
echo "stub-certbot: certificate issued for $domain -> $live"
exit 0
