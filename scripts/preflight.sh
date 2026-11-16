#!/usr/bin/env bash
# ==========================================================================
# HANASO OPS Web Terminal — Preflight (READ-ONLY compatibility check)
# Runs on the target VPS BEFORE installation. Changes nothing.
# Human report on stdout; machine-readable KEY='VALUE' file for install.sh
# (written with SAFE single-quoted serialization — see scripts/ops-env.sh;
# install.sh parses it with a strict parser and NEVER sources it).
#
# Usage: preflight.sh [--domain ops.hanaso.ir] [--out /tmp/ops-preflight.env]
#                     [--haproxy-cfg PATH] [--haproxy-bin PATH]
#                     [--nginx-bin PATH] [--letsencrypt-dir PATH]
# Exit:   0 = no blocking issues   1 = blocking issues found
# ==========================================================================
set -u
DOMAIN="ops.hanaso.ir"
OUT="/tmp/ops-preflight.env"
HAPROXY_CFG_DEFAULT="/etc/haproxy/haproxy.cfg"
HAPROXY_CFG_ARG=""
HAPROXY_BIN_ARG=""
NGINX_BIN_ARG=""
LE_DIR="/etc/letsencrypt/live"
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --out)    OUT="$2"; shift 2 ;;
    --haproxy-cfg)  HAPROXY_CFG_ARG="$2"; shift 2 ;;
    --haproxy-bin)  HAPROXY_BIN_ARG="$2"; shift 2 ;;
    --nginx-bin)    NGINX_BIN_ARG="$2"; shift 2 ;;
    --letsencrypt-dir) LE_DIR="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=ops-env.sh
[ -r "$SCRIPT_DIR/ops-env.sh" ] && . "$SCRIPT_DIR/ops-env.sh" || {
  echo "FATAL: scripts/ops-env.sh missing next to preflight.sh"; exit 2; }

PASS=0; FAIL=0; WARN=0
ok()   { printf '  [ OK ] %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  [WARN] %s\n' "$1"; WARN=$((WARN+1)); }
info() { printf '  [info] %s\n' "$1"; }
kv()   { OPS_ENV_OUT="$OUT.tmp" ops_env_kv "$1" "$2" || exit 2; }

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
# (nginx is the panel's internal auth-gateway proxy in BOTH topologies:
#  nginx-direct uses the shared instance; haproxy-front runs an independent
#  loopback instance with the same binary.)
NGINX_BIN="${NGINX_BIN_ARG:-$(command -v nginx 2>/dev/null || echo /usr/sbin/nginx)}"
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
  bad "nginx not found — this installer needs an nginx binary (internal auth-gateway proxy)"
  kv PREFLIGHT_NGINX_BIN ""
fi

# --- 5. nginx include layout (nginx-direct topology only) ------------------
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
[ -n "$VHOST_DIR" ] || info "no shared-nginx vhost layout (fine for the HAProxy topology)"
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
  *,nginx,*|*,nginx:*)
    TOPOLOGY="nginx-direct"; ok "nginx terminates TLS on :443 (vhost is added in nginx)" ;;
  *,haproxy,*|*,haproxy:*)
    HAPROXY_BIN="${HAPROXY_BIN_ARG:-$(command -v haproxy 2>/dev/null || echo /usr/sbin/haproxy)}"
    HAPROXY_CFG="${HAPROXY_CFG_ARG:-$HAPROXY_CFG_DEFAULT}"
    [ -f "$HAPROXY_CFG_ARG" ] || { for c in /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.d; do
      [ -f "$c" ] && HAPROXY_CFG="$c" && break; done }
    # --- 6b. HAProxy deep inspection (read-only config analysis) ---------
    HAPROXY_VERSION=""
    if [ -x "$HAPROXY_BIN" ]; then
      HAPROXY_VERSION="$("$HAPROXY_BIN" -v 2>/dev/null | awk '{print $3, $4}' | awk -F. '{print $1"."$2}' | head -1)"
      HAPROXY_VERSION="${HAPROXY_VERSION%% *}"
      ok "HAProxy binary: $HAPROXY_BIN (version ${HAPROXY_VERSION:-unknown})"
    else
      warn "HAProxy binary not found at ${HAPROXY_BIN}"
    fi
    kv PREFLIGHT_HAPROXY_VERSION "$HAPROXY_VERSION"
    if [ -r "$HAPROXY_CFG" ]; then
      ok "HAProxy config readable: $HAPROXY_CFG"
      kv PREFLIGHT_HAPROXY_CFG "$HAPROXY_CFG"
    else
      warn "HAProxy config NOT readable at ${HAPROXY_CFG} (installer will stop)"
      kv PREFLIGHT_HAPROXY_CFG ""
    fi
    # find the frontend/listen section that binds :443 and its bind line
    BIND443_INFO="$(awk '
      function flush() { if (sect != "" && bind443 != "") {
        printf "%s|%d|%s\n", sect, sectline, bind443 } }
      /^[[:space:]]*(frontend|listen)[[:space:]]/ {
        flush(); sect=$2; sectline=NR; bind443=""; next }
      /^[[:space:]]*(backend|defaults|global|peers|resolvers|mailers|caches)[[:space:]]/ {
        flush(); sect=""; next }
      sect != "" && /^[[:space:]]*bind[[:space:]][^#]*:443([[:space:]]|$)/ {
        if (bind443 == "") bind443=$0; else bind443=bind443 "\n" $0 }
      END { flush() }
    ' "$HAPROXY_CFG" 2>/dev/null || true)"
    FRONT443=""; BIND443_FIRST=""
    if [ -n "$BIND443_INFO" ]; then
      FRONT443="${BIND443_INFO%%|*}"
      BIND443_FIRST="${BIND443_INFO#*|}"; BIND443_FIRST="${BIND443_FIRST#*|}"
    fi
    kv PREFLIGHT_HAPROXY_FRONTEND "$FRONT443"
    BIND_MODE="unknown"; CRT_STYLE="none"; CRT_PATH=""
    if [ -n "$BIND443_FIRST" ]; then
      # strip a possible second bind line from the captured string
      BIND443_FIRST="${BIND443_FIRST%%$'\n'*}"
      info "443 bind line: $(printf '%s' "$BIND443_FIRST" | tr -s '[:space:]' ' ')"
      if printf '%s' "$BIND443_FIRST" | grep -qE '(^|[[:space:]])ssl([[:space:]]|$)'; then
        BIND_MODE="ssl-term"
        CRT="$(printf '%s' "$BIND443_FIRST" | tr -s '[:space:]' ' ' | awk '{
          for (i=1;i<=NF;i++) if ($i=="crt" || $i=="crt-list") { print $(i+1); exit } }')"
        CRT_STYLE="none"; CRT_PATH="${CRT:-}"
        if [ -n "$CRT_PATH" ]; then
          if [ -d "$CRT_PATH" ]; then CRT_STYLE="dir"
          elif [ -f "$CRT_PATH" ]; then CRT_STYLE="file"
          else
            CRT_STYLE="none"
            warn "the crt path on the :443 bind does not exist: $CRT_PATH (broken bind — installer stops at its baseline check)"
          fi
        fi
        ok "HAProxy terminates TLS on :443 (bind ssl) — panel cert is added to HAProxy (${CRT_STYLE} crt: ${CRT_PATH:-none})"
      else
        BIND_MODE="tcp-passthrough"
        warn "HAProxy :443 bind has NO ssl — TCP passthrough topology (TLS stays on the panel's internal nginx)"
      fi
      # crt-list keyword style takes precedence over file/dir resolution
      if printf '%s' "$BIND443_FIRST" | grep -qE '(^|[[:space:]])crt-list([[:space:]]|$)'; then CRT_STYLE="crt-list"; fi
    else
      warn "could not locate a :443 bind line in $HAPROXY_CFG (installer will stop)"
    fi
    kv PREFLIGHT_HAPROXY_BIND_MODE "$BIND_MODE"
    kv PREFLIGHT_HAPROXY_CRT_STYLE "$CRT_STYLE"
    kv PREFLIGHT_HAPROXY_CRT_PATH "$CRT_PATH"
    # :80 ownership + existing ACME routing
    HAS80="0"
    printf '%s' ",$LISTEN80," | grep -q ',haproxy,' && HAS80="1"
    kv PREFLIGHT_HAPROXY_HTTP80 "$HAS80"
    if [ "$HAS80" = "1" ] && [ -r "$HAPROXY_CFG" ]; then
      if grep -qE 'acme-challenge' "$HAPROXY_CFG" 2>/dev/null; then
        ok "existing ACME HTTP-01 routing found in HAProxy config (certbot webroot can be reused)"
        kv PREFLIGHT_HAPROXY_ACME_ROUTED 1
      else
        info "no ACME routing in HAProxy config — installer adds its own managed ACME ACL if it must issue a certificate"
        kv PREFLIGHT_HAPROXY_ACME_ROUTED 0
      fi
    else
      kv PREFLIGHT_HAPROXY_ACME_ROUTED 0
      [ "$HAS80" = "0" ] && info "HAProxy does not own :80 (ACME HTTP-01 needs a :80 route or an existing cert)"
    fi
    # reload capability (reload only — this installer never restarts HAProxy)
    HAP_RELOAD="none"
    if command -v systemctl >/dev/null 2>&1; then
      if [ -n "$(systemctl show -p ExecReload haproxy.service --value 2>/dev/null | tr -d '[:space:]')" ]; then
        HAP_RELOAD="systemd"
      elif [ -f /run/haproxy.pid ] || [ -f /var/run/haproxy.pid ]; then
        HAP_RELOAD="pidfile"
      fi
    elif [ -f /run/haproxy.pid ] || [ -f /var/run/haproxy.pid ]; then
      HAP_RELOAD="pidfile"
    fi
    kv PREFLIGHT_HAPROXY_RELOAD "$HAP_RELOAD"
    case "$HAP_RELOAD" in
      systemd) ok "HAProxy reload available via systemctl (ExecReload)" ;;
      pidfile)  ok "HAProxy reload available via master-worker pidfile (SIGUSR2)" ;;
      *) warn "no safe HAProxy reload mechanism detected — installer will stop before editing" ;;
    esac
    TOPOLOGY="haproxy-front"
    [ "$BIND_MODE" = "tcp-passthrough" ] && TOPOLOGY="haproxy-tcp-passthrough"
    ok "topology: $TOPOLOGY (SNI/host ACL + dedicated loopback backend plan)"
    # already-installed marker inside the shared config?
    if [ -r "$HAPROXY_CFG" ] && grep -q 'ops-terminal' "$HAPROXY_CFG" 2>/dev/null; then
      warn "an ops-terminal managed block already exists in $HAPROXY_CFG (idempotent update)"
    fi
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

# --- 10. local ports free (loopback panel services) -----------------------
for P in 7680 7681 7682; do
  if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":$P\$"; then
    bad "port $P already in use on this host"; kv "PREFLIGHT_PORT_${P}_FREE" 0
  else ok "port $P free (loopback service)"; kv "PREFLIGHT_PORT_${P}_FREE" 1; fi
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
if [ -n "$(printf '%s' "$DNS_IPS" | tr -d ' ')" ] && [ "$DNS_MATCH" = "1" ]; then
  ok "DNS: $DOMAIN resolves to this host ($(printf '%s' "$DNS_IPS" | tr -s ' '))"
  kv PREFLIGHT_DNS_MATCH 1
elif [ -n "$(printf '%s' "$DNS_IPS" | tr -d ' ')" ]; then
  warn "DNS: $DOMAIN resolves to $(printf '%s' "$DNS_IPS" | tr -s ' ') (not this host) — create A record -> one of: $HOST_IPS"
  kv PREFLIGHT_DNS_MATCH 0
else
  warn "DNS: $DOMAIN does not resolve — create an A record to $HOST_IPS (DNS Only)"
  kv PREFLIGHT_DNS_MATCH 0
fi
kv PREFLIGHT_DNS_IPS "$DNS_IPS"; kv PREFLIGHT_HOST_IPS "$HOST_IPS"

# --- 13. existing TLS certificate covering the domain ---------------------
COVER_CERT=""
if [ -d "$LE_DIR" ]; then
  for d in "$LE_DIR"/*/; do
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
  kv PREFLIGHT_HAPROXY_OPS_CERT_EXISTS 1
else
  info "no existing certificate found that covers $DOMAIN"
  kv PREFLIGHT_CERT_PATH ""; kv PREFLIGHT_CERT_KEY ""
  kv PREFLIGHT_HAPROXY_OPS_CERT_EXISTS 0
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
[ -d /var/www/html ] || info "/var/www/html missing (ACME webroot for HTTP-01); installer will create it"
if systemctl is-active --quiet bigbluebutton 2>/dev/null; then
  info "BigBlueButton is active on this host — installer only reloads the reverse proxy (never restarts)"
  kv PREFLIGHT_BBB 1
else kv PREFLIGHT_BBB 0; fi

# --- result ---------------------------------------------------------------
mv -f "$OUT.tmp" "$OUT" && rm -f "$OUT.tmp"
echo "------------------------------------------------------------------"
echo " RESULT: PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
echo " machine-readable state -> $OUT (KEY='value', strictly parsed by install.sh)"
echo "------------------------------------------------------------------"
[ "$FAIL" -eq 0 ]
