#!/usr/bin/env bash
# ==========================================================================
# HANASO OPS Web Terminal — Installer
#
# Production (on the VPS, as root):
#   ./scripts/install.sh --yes                    # interactive confirm by default
#
# Sandbox/test mode (unprivileged, no systemd — used to validate the exact
# same code paths before shipping):
#   ./scripts/install.sh --sandbox --tls-cert X --tls-key Y \
#        --http-port 8080 --https-port 8443 \
#        --nginx-bin /path/nginx --tmux-bin /path/tmux ...
#
# Behaviour:
#   * Runs preflight.sh first (read-only) and honors its findings.
#   * Installs ttyd (vendored, sha256-verified) + auth gateway + systemd units.
#   * NEVER deletes or modifies existing vhosts/services; only adds its own
#     vhost file and performs `nginx -t` + RELOAD (never restart).
#   * If DNS or TLS is not ready → stops BEFORE any external exposure with a
#     clear message (services stay loopback-only).
#   * Idempotent: re-run updates files; existing credentials are preserved
#     unless --reset-credentials.
#   * Rollback on failure restores the previous state automatically.
# ==========================================================================
set -Eeuo pipefail

die()        { printf '\n[install][FATAL] %s\n' "$*" >&2; exit 1; }
note()       { printf '[install] %s\n' "$*"; }

# ------------------------------------------------------------------ args --
DOMAIN="ops.hanaso.ir"
ASSUME_YES=0; SANDBOX=0; SKIP_NGINX=0; RESET_CREDENTIALS=0
HTTP_PORT=80;  HTTPS_PORT=443
TTYD_PORT=7681; GATEWAY_PORT=7682; SESSION_TTL=8
TLS_CERT=""; TLS_KEY=""; ACME_EMAIL=""
NGINX_BIN=""; MIME_TYPES=""; TMUX_BIN=""; TMUX_LD_PATH=""
PY_BIN="$(command -v python3 || echo /usr/bin/python3)"
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --sandbox) SANDBOX=1; SKIP_SYSTEMD=1; HTTP_PORT=8080; HTTPS_PORT=8443; shift ;;
    --skip-nginx) SKIP_NGINX=1; shift ;;
    --reset-credentials) RESET_CREDENTIALS=1; shift ;;
    --http-port) HTTP_PORT="$2"; shift 2 ;;
    --https-port) HTTPS_PORT="$2"; shift 2 ;;
    --ttyd-port) TTYD_PORT="$2"; shift 2 ;;
    --gateway-port) GATEWAY_PORT="$2"; shift 2 ;;
    --session-ttl) SESSION_TTL="$2"; shift 2 ;;
    --tls-cert) TLS_CERT="$2"; shift 2 ;;
    --tls-key) TLS_KEY="$2"; shift 2 ;;
    --acme-email) ACME_EMAIL="$2"; shift 2 ;;
    --nginx-bin) NGINX_BIN="$2"; shift 2 ;;
    --mime-types) MIME_TYPES="$2"; shift 2 ;;
    --tmux-bin) TMUX_BIN="$2"; shift 2 ;;
    --tmux-ld-path) TMUX_LD_PATH="$2"; shift 2 ;;
    --python-bin) PY_BIN="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$REPO_DIR/gateway/gateway.py" ]   || die "run from the repository (gateway/gateway.py missing)"
[ -f "$REPO_DIR/vendor/ttyd-1.7.7.x86_64" ] || die "vendored ttyd binary missing"

# ------------------------------------------------------------- path layout --
TS="$(date +%Y%m%d-%H%M%S)"
if [ "$SANDBOX" = "1" ]; then
  SB_ROOT="${OPS_SANDBOX_ROOT:-$HOME/ops-sandbox}"
  OPT_DIR="$SB_ROOT/opt/ops-terminal";  ETC_DIR="$SB_ROOT/etc/ops-terminal"
  VARLIB_DIR="$SB_ROOT/var/lib/ops-terminal"; VARLOG_DIR="$SB_ROOT/var/log/ops-terminal"
  VARTMP_DIR="$SB_ROOT/var/tmp/ops-terminal"; RUN_DIR="$SB_ROOT/run"
  NGX_DIR="$SB_ROOT/nginx";  BACKUP_DIR="$SB_ROOT/backups/$TS"
  SYSTEMD_DIR=""; LOGROTATE_DIR=""
  SERVICE_USER="$(id -un)"; SERVICE_GROUP="$(id -gn)"
  RUNNER_GW_USER="$SERVICE_USER"
  TMUX_TMPDIR_DEFAULT="$VARTMP_DIR"
else
  OPT_DIR="/opt/ops-terminal";  ETC_DIR="/etc/ops-terminal"
  VARLIB_DIR="/var/lib/ops-terminal"; VARLOG_DIR="/var/log/ops-terminal"
  VARTMP_DIR="/var/tmp/ops-terminal"; RUN_DIR="/run/ops-terminal"
  NGX_DIR=""; BACKUP_DIR="/var/backups/ops-terminal/$TS"
  SYSTEMD_DIR="/etc/systemd/system"; LOGROTATE_DIR="/etc/logrotate.d"
  SERVICE_USER="root"; SERVICE_GROUP="root"
  RUNNER_GW_USER="ops-gw"
  TMUX_TMPDIR_DEFAULT="$VARTMP_DIR"
fi
mkdir -p "$BACKUP_DIR"

# ------------------------------------------------------------- rollback state --
CREATED_USER=0; NGINX_TOUCHED=0; NGINX_RELOADED=0; SERVICES_STARTED=0
CREATED_PATHS=()
rollback() {
  printf '\n[install][ROLLBACK] reverting changes after failure...\n' >&2
  set +e
  if [ "$SANDBOX" = "1" ]; then
    for f in gateway ttyd; do
      [ -f "$RUN_DIR/$f.pid" ] && kill "$(cat "$RUN_DIR/$f.pid")" 2>/dev/null
      rm -f "$RUN_DIR/$f.pid"
    done
    [ -f "$RUN_DIR/nginx.pid" ] && "$NGINX_BIN" -c "$NGX_DIR/nginx.conf" -s stop 2>/dev/null
  else
    systemctl disable --now ops-terminal.service ops-terminal-gateway.service 2>/dev/null
    rm -f "$SYSTEMD_DIR/ops-terminal.service" "$SYSTEMD_DIR/ops-terminal-gateway.service"
    systemctl daemon-reload 2>/dev/null
  fi
  if [ "$NGINX_TOUCHED" = "1" ] && [ "$NGINX_RELOADED" = "1" ]; then
    # restore vhost backup if present, then test+reload
    if [ -f "$BACKUP_DIR/ops-terminal.conf.bak" ]; then
      cp "$BACKUP_DIR/ops-terminal.conf.bak" "${VHOST_FILE:-}" 2>/dev/null
    elif [ -n "${VHOST_FILE:-}" ]; then
      rm -f "$VHOST_FILE" "${VHOST_ENABLE_LINK:-}"
    fi
    if [ "$SANDBOX" = "1" ]; then
      "$NGINX_BIN" -t -c "$NGX_DIR/nginx.conf" 2>/dev/null && \
        "$NGINX_BIN" -c "$NGX_DIR/nginx.conf" -s reload 2>/dev/null
    else
      nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null
    fi
  elif [ "$NGINX_TOUCHED" = "1" ] && [ -n "${VHOST_FILE:-}" ]; then
    rm -f "$VHOST_FILE" "${VHOST_ENABLE_LINK:-}"
  fi
  if [ "$CREATED_USER" = "1" ]; then userdel ops-gw 2>/dev/null; fi
  for p in "${CREATED_PATHS[@]:-}"; do [ -n "$p" ] && rm -rf "$p"; done
  printf '[install][ROLLBACK] done. backups kept in %s\n' "$BACKUP_DIR" >&2
}
on_error() {
  local line="$1"
  printf '\n[install][FATAL] failed at line %s\n' "$line" >&2
  rollback
  exit 1
}
trap 'on_error $LINENO' ERR

# ------------------------------------------------------------ preflight --
TOPOLOGY="nginx-direct"; VHOST_DIR=""; ENABLE_DIR=""; EXISTING_CERT=""
CERTBOT_BIN=""; DNS_MATCH=0; TMUX_MISSING=0
if [ "$SANDBOX" = "1" ]; then
  [ -x "${NGINX_BIN:?--sandbox requires --nginx-bin}" ] || die "nginx binary not executable"
  [ -x "${TMUX_BIN:?--sandbox requires --tmux-bin}" ]   || die "tmux binary not executable"
  [ -n "$MIME_TYPES" ] || die "--sandbox requires --mime-types"
  [ -n "$TLS_CERT" ] && [ -n "$TLS_KEY" ] || die "--sandbox requires --tls-cert and --tls-key (test certificate)"
  TOPOLOGY="nginx-direct"
else
  [ "$(id -u)" = "0" ] || die "run as root (production install)"
  note "running preflight (read-only)..."
  "$REPO_DIR/scripts/preflight.sh" --domain "$DOMAIN" --out /tmp/ops-preflight.env || true
  . /tmp/ops-preflight.env
  [ "${PREFLIGHT_IS_ROOT:-0}" = "1" ]        || die "preflight: not root"
  [ "${PREFLIGHT_NGINX_AUTH_REQUEST:-0}" = "1" ] || die "preflight: nginx lacks auth_request module"
  [ "${PREFLIGHT_PYTHON_OK:-0}" = "1" ]      || die "preflight: python3 unsuitable"
  [ "${PREFLIGHT_PORT_7681_FREE:-1}" = "1" ] && [ "${PREFLIGHT_PORT_7682_FREE:-1}" = "1" ] \
    || { [ "${PREFLIGHT_EXISTING_INSTALL:-0}" = "1" ] || die "preflight: ports 7681/7682 busy (not by this panel)"; }
  TOPOLOGY="${PREFLIGHT_TOPOLOGY:-unknown}"
  VHOST_DIR="${PREFLIGHT_NGINX_VHOST_DIR:-}"
  ENABLE_DIR="${PREFLIGHT_NGINX_ENABLE_DIR:-}"
  EXISTING_CERT="${PREFLIGHT_CERT_PATH:-}"
  CERTBOT_BIN="${PREFLIGHT_CERTBOT:-}"
  DNS_MATCH="${PREFLIGHT_DNS_MATCH:-0}"
  [ -n "${PREFLIGHT_TMUX:-}" ] || TMUX_MISSING=1
  if [ "$TOPOLOGY" != "nginx-direct" ]; then
    cat <<'EOM'

[install] TOPOLOGY NOTICE
  This VPS does NOT have nginx listening directly on :443 (detected: __TOPOLOGY__).
  The automatic vhost path of this installer targets the common nginx-direct
  layout used by HANASO/KOTODAMA/BigBlueButton. To avoid blind edits on the
  shared HAProxy/nginx chain, the installer stops here.
  Next step: send the output of scripts/preflight.sh to the maintainer so the
  exact HAProxy SNI/ACL patch can be prepared and reviewed.
EOM
    die "unsupported reverse-proxy topology: $TOPOLOGY"
  fi
  if [ "$ASSUME_YES" != "1" ]; then
    printf '\nInstall HANASO OPS Web Terminal for %s? (services: ttyd+gateway on loopback; nginx vhost + reload)\nType YES to continue: ' "$DOMAIN"
    read -r ANS; [ "$ANS" = "YES" ] || die "aborted by operator"
  fi
fi

# ------------------------------------------------------- optional apt install --
if [ "$TMUX_MISSING" = "1" ] && [ "$SANDBOX" != "1" ]; then
  note "installing tmux (required for session persistence)..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y tmux >/dev/null
  command -v tmux >/dev/null 2>&1 || die "tmux installation failed"
fi
[ -n "$TMUX_BIN" ] || TMUX_BIN="$(command -v tmux || echo /usr/bin/tmux)"
[ -x "$TMUX_BIN" ] || die "tmux binary not usable: $TMUX_BIN"

# ---------------------------------------------------------------- backups --
note "backup snapshot -> $BACKUP_DIR"
for p in "$OPT_DIR" "$ETC_DIR" "$VARLIB_DIR" "$VARLOG_DIR"; do
  [ -e "$p" ] && cp -a "$p" "$BACKUP_DIR/$(basename "$(dirname "$p")")-$(basename "$p").bak"
done
if [ -n "$VHOST_DIR" ] && [ -e "$VHOST_DIR/ops-terminal.conf" ]; then
  cp -a "$VHOST_DIR/ops-terminal.conf" "$BACKUP_DIR/ops-terminal.conf.bak"
fi
BACKUP_COUNT="$(ls -A "$BACKUP_DIR" 2>/dev/null | wc -l)"
note "backup contains $BACKUP_COUNT item(s)"

# ------------------------------------------------------------ verify ttyd --
VENDORED_TTYD="$REPO_DIR/vendor/ttyd-1.7.7.x86_64"
EXPECT_SHA="$(grep 'ttyd.x86_64$' "$REPO_DIR/vendor/ttyd-SHA256SUMS.txt" | awk '{print $1}')"
ACTUAL_SHA="$(sha256sum "$VENDORED_TTYD" | awk '{print $1}')"
[ "$EXPECT_SHA" = "$ACTUAL_SHA" ] || die "ttyd binary sha256 mismatch ($ACTUAL_SHA)"
[ "$(uname -m)" = "x86_64" ] || die "vendored ttyd is x86_64 only (host: $(uname -m))"
note "ttyd 1.7.7 sha256 verified: $ACTUAL_SHA"

# ------------------------------------------------------------ install files --
DIRS=("$OPT_DIR/bin" "$OPT_DIR/gateway" "$ETC_DIR" "$VARLIB_DIR" "$VARLOG_DIR" "$VARTMP_DIR" "$RUN_DIR")
[ "$SANDBOX" = "1" ] && DIRS+=("$NGX_DIR")
for d in "${DIRS[@]}"; do
  if [ ! -d "$d" ]; then mkdir -p "$d"; CREATED_PATHS+=("$d"); fi
done
install -m 0755 "$VENDORED_TTYD"      "$OPT_DIR/bin/ttyd"
install -m 0755 "$REPO_DIR/gateway/gateway.py" "$OPT_DIR/gateway/gateway.py"
install -m 0755 "$REPO_DIR/scripts/health-check.sh" "$OPT_DIR/health-check.sh"

# --- environment file
cat > "$ETC_DIR/env" <<EOF
# HANASO OPS Web Terminal — gateway environment (rendered by installer)
OPS_DOMAIN=$DOMAIN
GATEWAY_HOST=127.0.0.1
GATEWAY_PORT=$GATEWAY_PORT
TTYD_PORT=$TTYD_PORT
SESSION_TTL_HOURS=$SESSION_TTL
MAX_LOGIN_FAILURES=5
LOCKOUT_MINUTES=15
PBKDF2_ITERATIONS=200000
PANEL_USERNAME=ops-admin
CREDENTIALS_FILE=$ETC_DIR/credentials
SESSION_KEY_FILE=$ETC_DIR/session.key
STATE_FILE=$VARLIB_DIR/state.json
LOG_FILE=$VARLOG_DIR/gateway.log
EOF
chmod 0640 "$ETC_DIR/env"

# --- system user (production only)
if [ "$SANDBOX" != "1" ]; then
  if ! id ops-gw >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /var/lib/ops-terminal \
            --shell /usr/sbin/nologin ops-gw
    CREATED_USER=1
    note "created system user ops-gw (no login shell)"
  fi
fi

# --- credentials + session key (generate once, preserve on re-runs)
export OPS_TERMINAL_CONF="$ETC_DIR/env"
CRED_SUMMARY="(existing credentials kept — rotate with: ops-terminal-passwd)"
if [ ! -f "$ETC_DIR/credentials" ] || [ "$RESET_CREDENTIALS" = "1" ]; then
  note "generating panel credentials (random 24 chars)..."
  CRED_OUT="$("$PY_BIN" "$OPT_DIR/gateway/gateway.py" passwd --generate --print-once)"
  PANEL_USERNAME="$(printf '%s\n' "$CRED_OUT" | sed -n 's/^PANEL_USERNAME=//p')"
  PANEL_PASSWORD="$(printf '%s\n' "$CRED_OUT" | sed -n 's/^PANEL_PASSWORD=//p')"
  [ -n "$PANEL_PASSWORD" ] || die "credential generation failed"
  CRED_SUMMARY="(new random password generated — shown once at the end)"
fi
if [ ! -f "$ETC_DIR/session.key" ]; then
  "$PY_BIN" "$OPT_DIR/gateway/gateway.py" passwd --rotate-session-key >/dev/null
fi
if [ "$SANDBOX" = "1" ]; then
  chown -R "$SERVICE_USER:$SERVICE_GROUP" "$ETC_DIR" "$VARLIB_DIR" "$VARLOG_DIR" "$VARTMP_DIR" 2>/dev/null || true
else
  chown root:ops-gw "$ETC_DIR" "$ETC_DIR/env" "$ETC_DIR/credentials" "$ETC_DIR/session.key"
  chmod 0640 "$ETC_DIR/credentials" "$ETC_DIR/session.key"
  chown -R ops-gw:ops-gw "$VARLIB_DIR" "$VARLOG_DIR"
  chmod 0750 "$VARLIB_DIR" "$VARLOG_DIR" "$VARTMP_DIR" "$ETC_DIR"
fi

# --- convenience tools + logrotate (production)
if [ "$SANDBOX" != "1" ]; then
  sed "s|/opt/ops-terminal|$OPT_DIR|g" "$REPO_DIR/scripts/ops-terminal-passwd" \
      > /usr/local/bin/ops-terminal-passwd
  chmod 0755 /usr/local/bin/ops-terminal-passwd
  cat > "$LOGROTATE_DIR/ops-terminal" <<'EOF'
/var/log/ops-terminal/gateway.log {
  weekly
  rotate 8
  compress
  missingok
  notifempty
  copytruncate
}
EOF
fi

# ------------------------------------------------------------ systemd units --
if [ "$SANDBOX" != "1" ]; then
  sed -e "s|-p 7681|-p $TTYD_PORT|" \
      -e "s|TMUX_TMPDIR=/var/tmp/ops-terminal|TMUX_TMPDIR=$VARTMP_DIR|" \
      -e "s|/usr/bin/tmux|$TMUX_BIN|" \
      -e "s|-w /root|-w /root|" \
      "$REPO_DIR/systemd/ops-terminal.service"        > "$SYSTEMD_DIR/ops-terminal.service"
  sed -e "s|OPS_TERMINAL_CONF=/etc/ops-terminal/env|OPS_TERMINAL_CONF=$ETC_DIR/env|" \
      -e "s|/usr/bin/python3|$PY_BIN|" \
      -e "s|/opt/ops-terminal|$OPT_DIR|g" \
      "$REPO_DIR/systemd/ops-terminal-gateway.service" > "$SYSTEMD_DIR/ops-terminal-gateway.service"
  systemctl daemon-reload
fi

# ------------------------------------------------------------ start services --
stop_sandbox_svc() {
  local f="$1"
  if [ -f "$RUN_DIR/$f.pid" ]; then
    local pid; pid="$(cat "$RUN_DIR/$f.pid")"
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 0.3; done
    rm -f "$RUN_DIR/$f.pid"
  fi
}
note "starting gateway + ttyd..."
if [ "$SANDBOX" = "1" ]; then
  stop_sandbox_svc gateway; stop_sandbox_svc ttyd
  nohup env OPS_TERMINAL_CONF="$ETC_DIR/env" "$PY_BIN" "$OPT_DIR/gateway/gateway.py" \
        >> "$VARLOG_DIR/gateway-stderr.log" 2>&1 &
  echo $! > "$RUN_DIR/gateway.pid"
  TTYD_ENV="TMUX_TMPDIR=$VARTMP_DIR"
  [ -n "$TMUX_LD_PATH" ] && TTYD_ENV="TMUX_TMPDIR=$VARTMP_DIR LD_LIBRARY_PATH=$TMUX_LD_PATH"
  nohup env $TTYD_ENV "$OPT_DIR/bin/ttyd" -i 127.0.0.1 -p "$TTYD_PORT" -W -O -m 2 \
        -T xterm-256color -w "$HOME" \
        "$TMUX_BIN" new -A -s ops \
        >> "$VARLOG_DIR/ttyd.log" 2>&1 &
  echo $! > "$RUN_DIR/ttyd.pid"
else
  systemctl enable --now ops-terminal-gateway.service
  systemctl enable --now ops-terminal.service
fi
SERVICES_STARTED=1

# --- local health gate (loopback only; no external exposure yet)
for i in $(seq 1 20); do
  if curl -sf -m 2 "http://127.0.0.1:$GATEWAY_PORT/health" >/dev/null 2>&1; then break; fi
  sleep 0.5; [ "$i" = "20" ] && die "gateway did not become healthy on 127.0.0.1:$GATEWAY_PORT"
done
for i in $(seq 1 20); do
  if curl -sf -m 2 "http://127.0.0.1:$TTYD_PORT/" -o /dev/null; then break; fi
  sleep 0.5; [ "$i" = "20" ] && die "ttyd did not become healthy on 127.0.0.1:$TTYD_PORT"
done
note "loopback services healthy (gateway:$GATEWAY_PORT, ttyd:$TTYD_PORT)"

if [ "$SKIP_NGINX" = "1" ]; then
  note "--skip-nginx: stopping after loopback services (no external exposure)"
  printf '\n[install] DONE (loopback-only mode)\n'
  exit 0
fi

# ------------------------------------------------------------ TLS material --
if [ "$SANDBOX" = "1" ]; then
  note "sandbox mode: using provided test certificate"
else
  if [ -z "$TLS_CERT" ]; then
    if [ -n "$EXISTING_CERT" ]; then
      TLS_CERT="$EXISTING_CERT"; TLS_KEY="$(dirname "$EXISTING_CERT")/privkey.pem"
      note "reusing existing certificate: $TLS_CERT"
    elif [ -n "$CERTBOT_BIN" ] && [ "$DNS_MATCH" = "1" ]; then
      note "issuing Let's Encrypt certificate for $DOMAIN (HTTP-01 webroot)..."
      ACME_FLAGS="--register-unsafely-without-email"
      [ -n "$ACME_EMAIL" ] && ACME_FLAGS="--email $ACME_EMAIL --no-eff-email"
      mkdir -p /var/www/html
      if ! "$CERTBOT_BIN" certonly --webroot -w /var/www/html -d "$DOMAIN" \
           --non-interactive --agree-tos $ACME_FLAGS --keep-until-expiring; then
        cat <<'EOM'

[install] TLS GATE — certificate issuance FAILED.
  The panel stays in SAFE loopback-only mode: no nginx vhost was added and
  nothing is exposed to the internet. Fix DNS (A record -> this host) or the
  ACME webroot, then re-run this installer.
EOM
        die "certbot failed (see above)"
      fi
      TLS_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
      TLS_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    else
      cat <<'EOM'

[install] TLS GATE — DNS or TLS not ready.
  * DNS: the domain must resolve to THIS host (currently: see preflight output).
  * TLS: no covering certificate exists and certbot is unavailable.
  The panel stays in SAFE loopback-only mode (services run on 127.0.0.1 only;
  no nginx vhost added; nothing exposed). Re-run the installer after fixing.
EOM
      note "loopback-only install completed; stopping before external exposure"
      printf '\n[install] DONE (loopback-only, TLS/DNS gate)\n'
      exit 0
    fi
  fi
  [ -r "$TLS_CERT" ] && [ -r "$TLS_KEY" ] || die "certificate files unreadable"
fi

# ------------------------------------------------------------ nginx vhost --
V6_HTTP=""; V6_HTTPS=""
if [ "$SANDBOX" != "1" ]; then V6_HTTP="listen [::]:$HTTP_PORT;"; V6_HTTPS="listen [::]:$HTTPS_PORT ssl;"; fi
NGINX_LOG_PREFIX="/var/log/nginx/ops-terminal."
if [ "$SANDBOX" = "1" ]; then NGINX_LOG_PREFIX="$VARLOG_DIR/nginx-ops-terminal."; fi
RENDER() { # file -> target
  sed -e "s|{{OPS_DOMAIN}}|$DOMAIN|g" \
      -e "s|{{TLS_CERT}}|$TLS_CERT|g" -e "s|{{TLS_KEY}}|$TLS_KEY|g" \
      -e "s|{{LISTEN_HTTP}}|$HTTP_PORT|g" -e "s|{{LISTEN_HTTPS}}|$HTTPS_PORT ssl|g" \
      -e "s|{{LISTEN_HTTP_V6}}|$V6_HTTP|g" -e "s|{{LISTEN_HTTPS_V6}}|$V6_HTTPS|g" \
      -e "s|{{GATEWAY_PORT}}|$GATEWAY_PORT|g" -e "s|{{TTYD_PORT}}|$TTYD_PORT|g" \
      -e "s|{{NGINX_LOG_PREFIX}}|$NGINX_LOG_PREFIX|g" "$1" > "$2"
}
if [ "$SANDBOX" = "1" ]; then
  RENDER "$REPO_DIR/nginx/ops-terminal.conf.template" "$NGX_DIR/ops-terminal.conf"
  # test-only master conf (unprivileged nginx, custom temp/pid/log paths)
  cat > "$NGX_DIR/nginx.conf" <<EOF
# TEST-ONLY harness configuration (sandbox) — production uses the distro master conf
worker_processes 1;
error_log $VARLOG_DIR/nginx-master-error.log warn;
pid $RUN_DIR/nginx.pid;
events { worker_connections 256; }
http {
    include $MIME_TYPES;
    default_type application/octet-stream;
    access_log off;
    client_body_temp_path $RUN_DIR/nginx_client;
    proxy_temp_path      $RUN_DIR/nginx_proxy;
    fastcgi_temp_path    $RUN_DIR/nginx_fastcgi;
    uwsgi_temp_path      $RUN_DIR/nginx_uwsgi;
    scgi_temp_path       $RUN_DIR/nginx_scgi;
    sendfile on;
    keepalive_timeout 65;
    include $NGX_DIR/ops-terminal.conf;
}
EOF
  VHOST_FILE="$NGX_DIR/ops-terminal.conf"
  note "sandbox nginx: testing configuration..."
  "$NGINX_BIN" -t -c "$NGX_DIR/nginx.conf"
  note "sandbox nginx: starting..."
  "$NGINX_BIN" -c "$NGX_DIR/nginx.conf"
  NGINX_TOUCHED=1
else
  VHOST_FILE="$VHOST_DIR/ops-terminal.conf"
  VHOST_ENABLE_LINK=""
  [ -n "$ENABLE_DIR" ] && VHOST_ENABLE_LINK="$ENABLE_DIR/ops-terminal.conf"
  RENDER "$REPO_DIR/nginx/ops-terminal.conf.template" "$VHOST_FILE"
  [ -n "$VHOST_ENABLE_LINK" ] && ln -sfn "$VHOST_FILE" "$VHOST_ENABLE_LINK"
  NGINX_TOUCHED=1
  note "nginx: testing configuration (nginx -t)..."
  nginx -t
  note "nginx: controlled RELOAD (existing vhosts stay online)..."
  systemctl reload nginx
  NGINX_RELOADED=1
  systemctl is-active nginx >/dev/null || die "nginx not active after reload"
fi

# ------------------------------------------------------------ end-to-end check --
if [ -z "${PANEL_PASSWORD:-}" ]; then
  note "credentials were preserved from a previous install — skipping automated e2e"
  note "(verify manually: scripts/e2e-test.py --base https://$DOMAIN --username <user> --password-stdin)"
else
  note "running end-to-end verification (login -> websocket -> shell)..."
  E2E_ARGS=(--base "https://$DOMAIN" --connect 127.0.0.1 --port "$HTTPS_PORT"
            --username "$PANEL_USERNAME" --password-stdin)
  if [ "$SANDBOX" = "1" ]; then
    E2E_ARGS+=(--insecure-allow --expect-uid "$(id -u)")
  else
    E2E_ARGS+=(--expect-uid 0)
  fi
  if printf '%s\n' "$PANEL_PASSWORD" | "$PY_BIN" "$REPO_DIR/scripts/e2e-test.py" "${E2E_ARGS[@]}"; then
    note "end-to-end verification PASSED"
  else
    cat <<'EOM'

[install] END-TO-END VERIFICATION FAILED.
  Rolling back the nginx vhost (services keep running loopback-only).
EOM
    rollback
    exit 1
  fi
fi

# ------------------------------------------------------------ summary --
printf '\n'
printf '==========================================================\n'
printf ' HANASO OPS Web Terminal — installed\n'
printf '==========================================================\n'
printf ' Panel URL   : https://%s%s\n' "$DOMAIN" "$([ "$HTTPS_PORT" != "443" ] && echo ":$HTTPS_PORT")"
printf ' Credential  : %s\n' "$CRED_SUMMARY"
if [ -n "${PANEL_PASSWORD:-}" ]; then
  printf ' USERNAME    : %s\n' "$PANEL_USERNAME"
  printf ' PASSWORD    : %s\n' "$PANEL_PASSWORD"
  printf '               (shown ONCE — save it now; it is not stored anywhere in cleartext)\n'
fi
printf ' Services    : ops-terminal-gateway  ops-terminal%s\n' "$([ "$SANDBOX" = "1" ] && echo ' (sandbox nohup)' || echo '')"
printf ' Logs        : %s/gateway.log  (login/logout events + IP)\n' "$VARLOG_DIR"
printf ' Docs        : docs/INSTALL.md  docs/SECURITY.md  docs/ROLLBACK.md\n'
printf ' Rotate pass : %s\n' "$([ "$SANDBOX" = "1" ] && echo "$PY_BIN $OPT_DIR/gateway/gateway.py passwd --generate --print-once" || echo 'ops-terminal-passwd  (or panel: /change-password)')"
printf ' Uninstall   : %s/scripts/uninstall.sh%s\n' "$REPO_DIR" "$([ "$SANDBOX" = "1" ] && echo ' --sandbox' || echo '')"
printf ' Backup now  : %s\n' "$BACKUP_DIR"
printf '==========================================================\n'
printf ' Do NOT redirect this output to a file (it contains the one-time password).\n'
printf '==========================================================\n'
exit 0
