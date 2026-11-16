#!/usr/bin/env bash
# ==========================================================================
# HANASO OPS Web Terminal — Preflight (READ-ONLY compatibility check)
# Runs on the target VPS BEFORE installation. Changes nothing.
# Human report on stdout; machine-readable KEY=VALUE file for install.sh.
#
# Usage:  preflight.sh [--domain ops.hanaso.ir] [--out /tmp/ops-preflight.env]
# Exit:   0 = no blocking issues   1 = blocking issues found
# ==========================================================================
set -u
DOMAIN="ops.hanaso.ir"
OUT="/tmp/ops-preflight.env"
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --out)    OUT="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

PASS=0; FAIL=0; WARN=0
ok()   { printf '  [ OK ] %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  [WARN] %s\n' "$1"; WARN=$((WARN+1)); }
info() { printf '  [info] %s\n' "$1"; }
kv()   { printf '%s=%s\n' "$1" "$2" >> "$OUT.tmp"; }

: > "$OUT.tmp"
kv PREFLIGHT_DOMAIN "$DOMAIN"

echo "=================================================================="
echo " HANASO OPS Web Terminal — Preflight (read-only)"
echo " domain: $DOMAIN   host: $(hostname)"
echo "=================================================================="

# --- 1. privileges --------------------------------------------------------
if [ "$(id -u)" = "0" ]; then ok "running as root (required for installation)"; kv PREFLIGHT_IS_ROOT 1
else bad "not running as root — run as root to install (preflight itself is read-only)"; kv PREFLIGHT_IS_ROOT 0; fi

# --- 2. OS ----------------------------------------------------------------
OS_ID=""; OS_VER=""
if [ -r /etc/os-release ]; then
  . /etc/os-release
  OS_ID="${ID:-}"; OS_VER="${VERSION_ID:-}"
fi
case "$OS_ID" in
  ubuntu|debian) ok "supported OS: $PRETTY_NAME" ;;
  *) warn "untested OS: ${OS_ID:-unknown} ${OS_VER} (Debian/Ubuntu expected)" ;;
esac
kv PREFLIGHT_OS "$OS_ID"; kv PREFLIGHT_OS_VERSION "$OS_VER"

# --- 3. systemd -----------------------------------------------------------
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  ok "systemd is running"; kv PREFLIGHT_SYSTEMD 1
else
  warn "systemd not active (services would have to be managed manually)"; kv PREFLIGHT_SYSTEMD 0
fi

# --- 4. nginx + auth_request module --------------------------------------
NGINX_BIN="$(command -v nginx 2>/dev/null || echo /usr/sbin/nginx)"
if [ -x "$NGINX_BIN" ]; then
  NGX_VER="$("$NGINX_BIN" -v 2>&1 | sed 's/.*\///')"
  ok "nginx found: $NGINX_BIN ($NGX_VER)"
  if "$NGINX_BIN" -V 2>&1 | tr ' ' '\n' | grep -q -- --with-http_auth_request_module; then
    ok "nginx has http_auth_request_module (required)"
    kv PREFLIGHT_NGINX_AUTH_REQUEST 1
  else
    bad "nginx LACKS http_auth_request_module (install nginx-core/nginx-full, not nginx-light)"
    kv PREFLIGHT_NGINX_AUTH_REQUEST 0
  fi
  kv PREFLIGHT_NGINX_BIN "$NGINX_BIN"
else
  bad "nginx not found — this installer requires the existing nginx reverse proxy"
  kv PREFLIGHT_NGINX_BIN ""
fi

# --- 5. nginx include layout ---------------------------------------------
VHOST_DIR=""; ENABLE_DIR=""
if [ -d /etc/nginx/sites-available ] && [ -d /etc/nginx/sites-enabled ]; then
  if grep -qE 'sites-enabled' /etc/nginx/nginx.conf 2>/dev/null; then
    VHOST_DIR=/etc/nginx/sites-available; ENABLE_DIR=/etc/nginx/sites-enabled
    ok "Debian/Ubuntu layout detected (sites-available + sites-enabled)"
  fi
fi
if [ -z "$VHOST_DIR" ] && [ -d /etc/nginx/conf.d ] && grep -qE 'conf\.d' /etc/nginx/nginx.conf 2>/dev/null; then
  VHOST_DIR=/etc/nginx/conf.d; ENABLE_DIR=""
  ok "conf.d layout detected"
fi
if [ -z "$VHOST_DIR" ]; then
  bad "could not detect nginx vhost include layout (no sites-enabled/conf.d in nginx.conf)"
fi
kv PREFLIGHT_NGINX_VHOST_DIR "$VHOST_DIR"; kv PREFLIGHT_NGINX_ENABLE_DIR "$ENABLE_DIR"
if [ -n "$VHOST_DIR" ] && [ -e "$VHOST_DIR/ops-terminal.conf" ]; then
  warn "an ops-terminal vhost already exists (installer will overwrite + backup)"; kv PREFLIGHT_EXISTING_VHOST 1
else kv PREFLIGHT_EXISTING_VHOST 0; fi

# --- 6. who owns :80 / :443 (real traffic path — never guess) ------------
TOPOLOGY="unknown"
LISTEN443="$(ss -tlnp 2>/dev/null | awk '$4 ~ /:443$/ {print $0}' | grep -oE 'users:\(\("[^"]+"' | grep -oE '"[^"]+"' | tr -d '"' | sort -u | tr '\n' ',')"
LISTEN80="$(ss -tlnp 2>/dev/null | awk '$4 ~ /:80$/ {print $0}' | grep -oE 'users:\(\("[^"]+"' | grep -oE '"[^"]+"' | tr -d '"' | sort -u | tr '\n' ',')"
info "processes listening on :443 -> ${LISTEN443:-none}"
info "processes listening on :80  -> ${LISTEN80:-none}"
case ",$LISTEN443," in
  *,nginx,*|*,nginx:*)  TOPOLOGY="nginx-direct"; ok "nginx terminates TLS on :443 (vhost is added in nginx)" ;;
  *,haproxy,*|*,haproxy:*)
    TOPOLOGY="haproxy-front"
    HAPROXY_CFG=""
    for c in /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.d; do
      [ -f "$c" ] && HAPROXY_CFG="$c" && break
    done
    warn "HAProxy owns :443. Adding the panel needs an HAProxy SNI/host ACL + backend edit"
    warn "HAProxy config: ${HAPROXY_CFG:-not found at default path}"
    info "installer will STOP on this topology — send this preflight output to the maintainer for a reviewed HAProxy patch"
    kv PREFLIGHT_HAPROXY_CFG "${HAPROXY_CFG:-}"
    ;;
  *) bad "nothing (or an unknown service) is listening on :443 — cannot add an HTTPS vhost" ;;
esac
kv PREFLIGHT_TOPOLOGY "$TOPOLOGY"

# --- 7. python3 -----------------------------------------------------------
PY="$(command -v python3 2>/dev/null || echo /usr/bin/python3)"
if [ -x "$PY" ]; then
  PYV="$("$PY" -V 2>&1 | awk '{print $2}')"
  PYMAJ="${PYV%%.*}"; PYMIN="${PYV#*.}"; PYMIN="${PYMIN%%.*}"
  if [ "${PYMAJ:-0}" -ge 3 ] && [ "${PYMIN:-0}" -ge 8 ]; then
    ok "python3 ${PYV} >= 3.8 (gateway requirement)"
    kv PREFLIGHT_PYTHON "$PY"; kv PREFLIGHT_PYTHON_OK 1
  else
    bad "python3 too old: ${PYV}"; kv PREFLIGHT_PYTHON_OK 0
  fi
else bad "python3 not found (gateway needs it)"; kv PREFLIGHT_PYTHON_OK 0; fi

# --- 8. tmux --------------------------------------------------------------
if command -v tmux >/dev/null 2>&1; then
  ok "tmux found: $(tmux -V)"; kv PREFLIGHT_TMUX "$(command -v tmux)"
else
  warn "tmux missing — installer will try: apt-get install -y tmux"; kv PREFLIGHT_TMUX ""
fi

# --- 9. curl --------------------------------------------------------------
if command -v curl >/dev/null 2>&1; then ok "curl found"; kv PREFLIGHT_CURL 1
else warn "curl missing (needed for cert issuance + health checks)"; kv PREFLIGHT_CURL 0; fi

# --- 10. local ports free -------------------------------------------------
for P in 7681 7682; do
  if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":$P$"; then
    bad "port $P already in use on this host"; kv PREFLIGHT_PORT_${P}_FREE 0
  else ok "port $P free (loopback service)"; kv PREFLIGHT_PORT_${P}_FREE 1; fi
done

# --- 11. existing installation -------------------------------------------
if [ -e /etc/ops-terminal/env ]; then
  warn "existing installation detected (/etc/ops-terminal/env) — re-install is idempotent"; kv PREFLIGHT_EXISTING_INSTALL 1
else kv PREFLIGHT_EXISTING_INSTALL 0; fi

# --- 12. DNS pointing -----------------------------------------------------
DNS_IPS="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
HOST_IPS="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u | tr '\n' ' ')"
DNS_MATCH=0
for ip in $DNS_IPS; do
  for hip in $HOST_IPS; do [ "$ip" = "$hip" ] && DNS_MATCH=1; done
done
if [ -n "$DNS_IPS" ] && [ "$DNS_MATCH" = "1" ]; then
  ok "DNS: $DOMAIN resolves to this host ($DNS_IPS)"; kv PREFLIGHT_DNS_MATCH 1
elif [ -n "$DNS_IPS" ]; then
  warn "DNS: $DOMAIN resolves to ${DNS_IPS}(not this host) — create A record -> one of: $HOST_IPS"; kv PREFLIGHT_DNS_MATCH 0
else
  warn "DNS: $DOMAIN does not resolve — create an A record to $HOST_IPS (DNS Only)"; kv PREFLIGHT_DNS_MATCH 0
fi
kv PREFLIGHT_DNS_IPS "$DNS_IPS"; kv PREFLIGHT_HOST_IPS "$HOST_IPS"

# --- 13. existing TLS certificate covering the domain ---------------------
COVER_CERT=""
if [ -d /etc/letsencrypt/live ]; then
  for d in /etc/letsencrypt/live/*/; do
    FC="$d/fullchain.pem"
    [ -r "$FC" ] || continue
    if openssl x509 -in "$FC" -noout -ext subjectAltName 2>/dev/null | tr ',' '\n' \
        | grep -qi "DNS:${DOMAIN}\|DNS:*.${DOMAIN#*.}"; then
      if openssl x509 -in "$FC" -noout -checkend 2592000 >/dev/null 2>&1; then
        COVER_CERT="$FC"; break
      fi
    fi
  done
fi
if [ -n "$COVER_CERT" ]; then
  ok "existing certificate covers $DOMAIN: $COVER_CERT (will be reused)"
  kv PREFLIGHT_CERT_PATH "$COVER_CERT"
  kv PREFLIGHT_CERT_KEY "$(dirname "$COVER_CERT")/privkey.pem"
else
  info "no existing certificate found that covers $DOMAIN"
  kv PREFLIGHT_CERT_PATH ""; kv PREFLIGHT_CERT_KEY ""
  if command -v certbot >/dev/null 2>&1; then
    ok "certbot available (will issue a new Let's Encrypt certificate)"
    kv PREFLIGHT_CERTBOT "$(command -v certbot)"
  else
    warn "certbot not found AND no covering certificate — TLS setup needs manual action"
    kv PREFLIGHT_CERTBOT ""
  fi
fi

# --- 14. disk space + misc ------------------------------------------------
FREE_MB="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"
if [ "${FREE_MB:-0}" -ge 100 ]; then ok "disk space: ${FREE_MB} MB free"; else warn "low disk space: ${FREE_MB} MB"; fi
[ -d /var/www/html ] || warn "/var/www/html missing (ACME webroot for HTTP-01); installer will create it"
if systemctl is-active --quiet bigbluebutton 2>/dev/null; then
  info "BigBlueButton is active on this host — installer will only reload nginx (never restart)"
  kv PREFLIGHT_BBB 1
else kv PREFLIGHT_BBB 0; fi
if grep -RqsE '^\s*map\s+\$http_upgrade' /etc/nginx/ 2>/dev/null; then
  info "existing websocket map(s) found — our template uses a unique variable name (no conflict)"
fi

# --- result ---------------------------------------------------------------
mv "$OUT.tmp" "$OUT"
echo "------------------------------------------------------------------"
echo " RESULT: PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
echo " machine-readable state -> $OUT"
echo "------------------------------------------------------------------"
[ "$FAIL" -eq 0 ]
