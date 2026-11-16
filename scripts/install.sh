#!/usr/bin/env bash
# ==========================================================================
# HANASO OPS Web Terminal — Installer
#
# Production (on the VPS, as root):
#   ./scripts/install.sh --yes                    # interactive confirm by default
#
# Supported reverse-proxy topologies (auto-detected by preflight):
#   * nginx-direct     : nginx terminates TLS on :443; a dedicated vhost is
#                        added to the shared nginx (original behaviour).
#   * haproxy-front    : HAProxy terminates TLS on :443 (bind ssl). A managed
#                        SNI/Host ACL + use_backend route ops.<domain> to the
#                        panel's own loopback nginx (127.0.0.1:7680) which
#                        fronts gateway(7682)+ttyd(7681). The panel cert is
#                        added to HAProxy (crt dir drop-in, crt-list append,
#                        or a reversible crt->crt-list conversion).
#   * haproxy-tcp-passthrough : HAProxy forwards raw TCP on :443. The same
#                        managed SNI ACL routes by req.ssl_sni and the loopback
#                        nginx terminates TLS itself.
#
#   In EVERY topology: the shared services of HANASO/KOTODAMA are never
#   restarted — only validated RELOADs; every edit is wrapped in BEGIN/END
#   managed markers and is validated (haproxy -c / nginx -t) BEFORE reload;
#   failure rolls back exactly this panel's changes.
#
# Sandbox/test mode (unprivileged, no systemd — same code paths):
#   ./scripts/install.sh --sandbox ...                    (nginx-direct harness)
#   ./scripts/install.sh --sandbox --sandbox-topology haproxy \
#        --haproxy-cfg SB/etc/haproxy/haproxy.cfg \
#        --haproxy-bin <haproxy> --haproxy-pidfile SB/run/haproxy.pid \
#        --nginx-bin <nginx> --mime-types ... --tmux-bin ... --tls-cert X --tls-key Y
#
# Behaviour:
#   * Runs preflight.sh (read-only) first and honors its findings.
#   * Machine-readable preflight state is parsed STRICTLY (scripts/ops-env.sh);
#     it is NEVER sourced as a shell script (incident 2026-11-16 fix).
#   * Installs ttyd (vendored, sha256-verified) + auth gateway + an
#     independent loopback nginx + systemd units.
#   * If DNS or TLS is not ready → stops BEFORE any external exposure
#     (services stay loopback-only).
#   * Idempotent: re-run updates files; existing credentials are preserved
#     unless --reset-credentials.
#   * Rollback on failure restores the previous state automatically.
# ==========================================================================
set -Eeuo pipefail

die()        { printf '\n[install][FATAL] %s\n' "$*" >&2; if [ "${CHANGES_BEGUN:-0}" = "1" ]; then rollback; fi; exit 1; }
note()       { printf '[install] %s\n' "$*"; }

# ------------------------------------------------------------------ args --
DOMAIN="ops.hanaso.ir"
ASSUME_YES=0; SANDBOX=0; SANDBOX_TOPOLOGY="nginx"; SKIP_NGINX=0; RESET_CREDENTIALS=0
SIMULATE_ACME=0
HTTP_PORT=80;  HTTPS_PORT=443
HTTP_PORT_SET=0; HTTPS_PORT_SET=0
TTYD_PORT=7681; GATEWAY_PORT=7682; PANEL_PORT=7680; SESSION_TTL=8
TLS_CERT=""; TLS_KEY=""; ACME_EMAIL=""
NGINX_BIN=""; MIME_TYPES=""; TMUX_BIN=""; TMUX_LD_PATH=""
PY_BIN="$(command -v python3 || echo /usr/bin/python3)"
HAPROXY_CFG_ARG=""; HAPROXY_BIN_ARG=""; HAPROXY_PIDFILE_ARG=""; CERTBOT_BIN_ARG=""
ACME_WEBROOT_ARG=""; E2E_EXPECT_UID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --sandbox) SANDBOX=1; HTTP_PORT=8080; HTTPS_PORT=8443; shift ;;
    --sandbox-topology) SANDBOX_TOPOLOGY="$2"; shift 2 ;;
    --simulate-acme) SIMULATE_ACME=1; shift ;;
    --skip-nginx) SKIP_NGINX=1; shift ;;
    --reset-credentials) RESET_CREDENTIALS=1; shift ;;
    --http-port) HTTP_PORT="$2"; HTTP_PORT_SET=1; shift 2 ;;
    --https-port) HTTPS_PORT="$2"; HTTPS_PORT_SET=1; shift 2 ;;
    --ttyd-port) TTYD_PORT="$2"; shift 2 ;;
    --gateway-port) GATEWAY_PORT="$2"; shift 2 ;;
    --panel-port) PANEL_PORT="$2"; shift 2 ;;
    --session-ttl) SESSION_TTL="$2"; shift 2 ;;
    --tls-cert) TLS_CERT="$2"; shift 2 ;;
    --tls-key) TLS_KEY="$2"; shift 2 ;;
    --acme-email) ACME_EMAIL="$2"; shift 2 ;;
    --nginx-bin) NGINX_BIN="$2"; shift 2 ;;
    --mime-types) MIME_TYPES="$2"; shift 2 ;;
    --tmux-bin) TMUX_BIN="$2"; shift 2 ;;
    --tmux-ld-path) TMUX_LD_PATH="$2"; shift 2 ;;
    --python-bin) PY_BIN="$2"; shift 2 ;;
    --haproxy-cfg) HAPROXY_CFG_ARG="$2"; shift 2 ;;
    --haproxy-bin) HAPROXY_BIN_ARG="$2"; shift 2 ;;
    --haproxy-pidfile) HAPROXY_PIDFILE_ARG="$2"; shift 2 ;;
    --certbot-bin) CERTBOT_BIN_ARG="$2"; shift 2 ;;
    --acme-webroot) ACME_WEBROOT_ARG="$2"; shift 2 ;;
    --e2e-expect-uid) E2E_EXPECT_UID="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ "$SANDBOX_TOPOLOGY" = "nginx" ] || [ "$SANDBOX_TOPOLOGY" = "haproxy" ] \
  || die "--sandbox-topology must be nginx or haproxy"
if [ "$SIMULATE_ACME" = "1" ]; then
  # CP10 battery: run the PRODUCTION certbot issuance branch inside the
  # sandbox with a stub certbot (tests/stub-certbot.sh). The production code
  # path below is unchanged; only the entry conditions differ.
  [ "$SANDBOX" = "1" ] || die "--simulate-acme is sandbox-only (production uses real certbot)"
  [ "$SANDBOX_TOPOLOGY" = "haproxy" ] || die "--simulate-acme requires --sandbox-topology haproxy"
  [ -z "$TLS_CERT" ] || die "--simulate-acme conflicts with --tls-cert/--tls-key"
  [ -n "$CERTBOT_BIN_ARG" ] || die "--simulate-acme requires --certbot-bin (stub certbot)"
fi
if [ "$SANDBOX" = "1" ] && [ "$SANDBOX_TOPOLOGY" = "haproxy" ]; then
  # default to the production edge ports; an unprivileged sandbox harness
  # overrides them with high ports (binding 80/443 needs CAP_NET_BIND_SERVICE)
  [ "${HTTP_PORT_SET:-0}" = "1" ]  || HTTP_PORT=80
  [ "${HTTPS_PORT_SET:-0}" = "1" ] || HTTPS_PORT=443
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$REPO_DIR/gateway/gateway.py" ]   || die "run from the repository (gateway/gateway.py missing)"
[ -f "$REPO_DIR/vendor/ttyd-1.7.7.x86_64" ] || die "vendored ttyd binary missing"
SCRIPT_DIR="$REPO_DIR/scripts"
# shellcheck source=ops-env.sh
. "$SCRIPT_DIR/ops-env.sh"      || die "scripts/ops-env.sh missing"
# shellcheck source=ops-haproxy.sh
. "$SCRIPT_DIR/ops-haproxy.sh"  || die "scripts/ops-haproxy.sh missing"
# shellcheck source=ops-systemd.sh
. "$SCRIPT_DIR/ops-systemd.sh"  || die "scripts/ops-systemd.sh missing"

# ------------------------------------------------------------- path layout --
TS="$(date +%Y%m%d-%H%M%S)"
TOPOLOGY="nginx-direct"          # nginx-direct | haproxy-front | haproxy-tcp-passthrough
HAPROXY_CFG=""; HAPROXY_BIN=""; HAPROXY_PIDFILE=""; CRTLIST=""
HAP_CERTS_DIR=""; HAP_PEM=""; ACME_WEBROOT=""
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
  if [ "$SANDBOX_TOPOLOGY" = "haproxy" ]; then
    TOPOLOGY="haproxy-front"
    HAPROXY_CFG="${HAPROXY_CFG_ARG:-$SB_ROOT/etc/haproxy/haproxy.cfg}"
    HAPROXY_BIN="${HAPROXY_BIN_ARG:?--sandbox-topology haproxy requires --haproxy-bin}"
    HAPROXY_PIDFILE="${HAPROXY_PIDFILE_ARG:-$SB_ROOT/run/haproxy.pid}"
    HAP_CERTS_DIR="$SB_ROOT/etc/haproxy/certs"; CRTLIST="$SB_ROOT/etc/haproxy/ops-terminal.crtlist"
    HAP_PEM="$HAP_CERTS_DIR/ops-terminal.pem"
    ACME_WEBROOT="${ACME_WEBROOT_ARG:-$SB_ROOT/var/www/html}"
    NGINX_BIN="${NGINX_BIN:?--sandbox-topology haproxy requires --nginx-bin}"
    MIME_TYPES="${MIME_TYPES:?--sandbox-topology haproxy requires --mime-types}"
    TMUX_BIN="${TMUX_BIN:?--sandbox-topology haproxy requires --tmux-bin}"
    [ -r "$HAPROXY_CFG" ] || die "sandbox haproxy cfg not readable: $HAPROXY_CFG"
  fi
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
INGX_CONF_DIR="$ETC_DIR/nginx"                 # independent loopback nginx (haproxy topologies)
INGX_VAR_DIR="$VARLIB_DIR/nginx"               # its pid/temp
INGX_TLS_DIR="$INGX_CONF_DIR/tls"              # passthrough topology cert copy

# ------------------------------------------------------------- rollback state --
# CHANGES_BEGUN: set right before the FIRST mutating action (backup snapshot).
# Every die() after that point triggers a full rollback of this panel's own
# changes (CP11: the production incident had a late die() exit WITHOUT any
# rollback — the gateway and the ttyd root shell stayed active and the nginx
# unit kept crash-looping).
CHANGES_BEGUN=0; ROLLED_BACK=0
CREATED_USER=0; NGINX_TOUCHED=0; NGINX_RELOADED=0; SERVICES_STARTED=0
HAP_TOUCHED=0; HAP_RELOADED=0; HAP_BIND_EDITED=0; HAP_PEM_CREATED=0
HAP_CRTLIST_CREATED=0; CRT_STYLE=""; CRT_PATH_BIND=""; HAP_RELOAD_MODE="pidfile"
CREATED_PATHS=()

haproxy_revert_edits() {
  # Surgical removal of OUR changes only; then validate + reload.
  # State-INDEPENDENT: resolves the crt-list situation from the CURRENT
  # config, so it works both for a first-install failure AND for a
  # re-install running over an earlier conversion (the current run's
  # HAP_* metadata alone cannot describe that state).
  local removed=0 lst orig_crt crt_dir need_reload=0
  if [ -f "$HAPROXY_CFG" ]; then
    removed="$(ha_remove_managed "$HAPROXY_CFG")"
    # (a) OUR reversible conversion: bind crt-list $CRTLIST -> crt <original>
    #     ($CRTLIST first line is the original cert path recorded by the
    #     installer; if this run did not convert, a previous run did)
    if [ -f "$CRTLIST" ] && grep -qE "crt-list $CRTLIST([[:space:]]|\$|,)" "$HAPROXY_CFG"; then
      orig_crt="$(head -n1 "$CRTLIST" | tr -d '[:space:]')"
      if [ -n "$orig_crt" ]; then
        sed -i "s|crt-list $CRTLIST|crt $orig_crt|g" "$HAPROXY_CFG" 2>/dev/null || true
        rm -f "$CRTLIST"
      fi
    fi
    # (b) operator-owned crt-list (a bind list that is NOT ours): remove ONLY
    #     our PEM line from it (matched by our unique PEM file name)
    while IFS= read -r lst; do
      [ -n "$lst" ] || continue
      [ "$lst" = "$CRTLIST" ] && continue
      [ -f "$lst" ] || continue
      sed -i '\|ops-terminal\.pem|d' "$lst" 2>/dev/null || true
    done < <(awk '/^[[:space:]]*bind[[:space:]][^#]*:/ { for (i=1;i<NF;i++) if ($i=="crt-list") print $(i+1) }' "$HAPROXY_CFG" 2>/dev/null)
    # (c) PEMs owned by this panel (removed by unique name only)
    rm -f "$HAP_CERTS_DIR/ops-terminal.pem" "${HAP_PEM:-}"
    crt_dir="$(awk '/^[[:space:]]*bind[[:space:]][^#]*:/ { for (i=1;i<NF;i++) if ($i=="crt") { print $(i+1); exit } }' "$HAPROXY_CFG" 2>/dev/null || true)"
    if [ -n "$crt_dir" ] && [ -d "$crt_dir" ] && [ -f "$crt_dir/ops-terminal.pem" ]; then
      rm -f "$crt_dir/ops-terminal.pem"
    fi
    [ -n "${DEPLOY_HOOK:-}" ] && rm -f "$DEPLOY_HOOK"
  fi
  printf '[install][ROLLBACK] removed %s managed HAProxy block(s) from %s\n' "$removed" "${HAPROXY_CFG:-?}" >&2
  # CP11: reload whenever we actually removed something from the shared
  # config — even if THIS run never reloaded (a leftover managed block from
  # an older crashed run must not keep its route live after a rollback).
  # The reload is validated and is never a restart.
  if [ "$HAP_RELOADED" = "1" ]; then need_reload=1; fi
  if [ "${removed:-0}" -gt 0 ] 2>/dev/null && [ -n "$HAPROXY_BIN" ]; then need_reload=1; fi
  if [ "$need_reload" = "1" ] && [ -f "$HAPROXY_CFG" ]; then
    if ha_haproxy_check "$HAPROXY_BIN" "$HAPROXY_CFG"; then
      haproxy_reload || true
    else
      # surgical removal failed validation -> restore the full backup copy
      if [ -f "$BACKUP_DIR/haproxy.cfg.bak" ]; then
        cp -a "$BACKUP_DIR/haproxy.cfg.bak" "$HAPROXY_CFG"
        ha_haproxy_check "$HAPROXY_BIN" "$HAPROXY_CFG" && haproxy_reload || true
      fi
    fi
  fi
}

haproxy_reload() {
  if [ "$SANDBOX" = "1" ]; then
    [ -r "$HAPROXY_PIDFILE" ] || { note "haproxy pidfile missing ($HAPROXY_PIDFILE)"; return 1; }
    kill -USR2 "$(head -n1 "$HAPROXY_PIDFILE")"
  elif [ "$HAP_RELOAD_MODE" = "systemd" ]; then
    systemctl reload haproxy
  elif [ "$HAP_RELOAD_MODE" = "pidfile" ]; then
    local pf; pf="/run/haproxy.pid"; [ -r "$pf" ] || pf="/var/run/haproxy.pid"
    [ -r "$pf" ] || { note "haproxy pidfile not found for SIGUSR2 reload"; return 1; }
    kill -USR2 "$(head -n1 "$pf")"
  else
    note "no safe haproxy reload mechanism (this should not happen — gated earlier)"; return 1
  fi
  sleep 0.6
  # post-reload liveness: HAProxy must still own the edge port (reload, never a stop)
  if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":${HTTPS_PORT}$"; then return 0; fi
  note "WARNING: edge port ${HTTPS_PORT} not listening right after reload — checking pid"
  if [ "$SANDBOX" = "1" ] && [ -r "$HAPROXY_PIDFILE" ] && kill -0 "$(head -n1 "$HAPROXY_PIDFILE")" 2>/dev/null; then return 0; fi
  return 1
}

rollback() {
  trap - ERR   # never re-enter this rollback from a nested command failure
  if [ "${ROLLED_BACK:-0}" = "1" ]; then return 0; fi
  ROLLED_BACK=1
  printf '\n[install][ROLLBACK] reverting changes after failure...\n' >&2
  set +e
  if [ "$SANDBOX" = "1" ]; then
    for f in gateway ttyd nginx-internal; do
      [ -f "$RUN_DIR/$f.pid" ] && kill "$(cat "$RUN_DIR/$f.pid")" 2>/dev/null
      rm -f "$RUN_DIR/$f.pid"
    done
    pkill -f "$OPT_DIR/bin/ttyd" 2>/dev/null
    pkill -f "$OPT_DIR/gateway/gateway.py" 2>/dev/null
    # the internal loopback nginx must also be swept (pidfile may be stale)
    pkill -f "$INGX_CONF_DIR/nginx.conf" 2>/dev/null
    if [ "$SANDBOX_TOPOLOGY" = "nginx" ] && [ -f "$RUN_DIR/nginx.pid" ]; then
      "$NGINX_BIN" -c "$NGX_DIR/nginx.conf" -s stop 2>/dev/null
    fi
    # bounded wait until the loopback panel ports are really free
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ':(7680|7681|7682)$' || break
      sleep 0.4
    done
  else
    # CP11: stop ONLY this panel's units, break any restart loop, clear the
    # failed state, and remove the unit files (scripts/ops-systemd.sh — the
    # shared nginx/haproxy of HANASO/KOTODAMA is never touched here).
    systemd_stop_panel_units
    if systemd_panel_units_stopped; then
      printf '[install][ROLLBACK] all ops-terminal units stopped (no restart loop left)\n' >&2
    else
      printf '[install][ROLLBACK][WARN] an ops-terminal unit is STILL active after the stop sweep\n' >&2
    fi
  fi
  if [ -n "${HAPROXY_CFG:-}" ] && [ -f "$HAPROXY_CFG" ]; then
    # CP11: sweep managed leftovers state-independently — our own route must
    # never survive a failed install, even if this run never touched haproxy
    # (a previous crashed run may have left managed blocks behind).
    if [ "$HAP_TOUCHED" = "1" ] || grep -q '^# BEGIN ops-terminal' "$HAPROXY_CFG" 2>/dev/null; then
      haproxy_revert_edits
    fi
  fi
  if [ "$NGINX_TOUCHED" = "1" ] && [ "$NGINX_RELOADED" = "1" ]; then
    # restore vhost backup if present, then test+reload (nginx-direct topology)
    if [ -f "$BACKUP_DIR/ops-terminal.conf.bak" ]; then
      cp "$BACKUP_DIR/ops-terminal.conf.bak" "${VHOST_FILE:-}" 2>/dev/null
    elif [ -n "${VHOST_FILE:-}" ]; then
      rm -f "$VHOST_FILE" "${VHOST_ENABLE_LINK:-}"
    fi
    if [ "$SANDBOX" = "1" ] && [ "$SANDBOX_TOPOLOGY" = "nginx" ]; then
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
  printf '\n[install][FATAL] failed at line %s (see above)\n' "$line" >&2
  rollback
  exit 1
}
trap 'on_error $LINENO' ERR

# ------------------------------------------------------------ preflight --
TOPOLOGY_SET=""
VHOST_DIR=""; ENABLE_DIR=""; EXISTING_CERT=""
CERTBOT_BIN=""; DNS_MATCH=0; TMUX_MISSING=0
if [ "$SANDBOX" = "1" ] && [ "$SANDBOX_TOPOLOGY" = "nginx" ]; then
  [ -x "${NGINX_BIN:?--sandbox requires --nginx-bin}" ] || die "nginx binary not executable"
  [ -x "${TMUX_BIN:?--sandbox requires --tmux-bin}" ]   || die "tmux binary not executable"
  [ -n "$MIME_TYPES" ] || die "--sandbox requires --mime-types"
  [ -n "$TLS_CERT" ] && [ -n "$TLS_KEY" ] || die "--sandbox requires --tls-cert and --tls-key (test certificate)"
  TOPOLOGY="nginx-direct"; TOPOLOGY_SET=1
elif [ "$SANDBOX" = "1" ] && [ "$SANDBOX_TOPOLOGY" = "haproxy" ]; then
  note "sandbox/haproxy topology: analysing the sandbox HAProxy config directly"
  TOPOLOGY="haproxy-front"; TOPOLOGY_SET=1
  V="$(ha_version_major "$HAPROXY_BIN")"
  [ "${V:-0}" -ge 2 ] || die "sandbox: haproxy version < 2.0 not supported (got ${V:-unknown})"
  ha_haproxy_check "$HAPROXY_BIN" "$HAPROXY_CFG" \
    || die "sandbox: baseline haproxy -c FAILED on the existing config — refusing to touch it"
  if [ "$SIMULATE_ACME" = "1" ]; then
    # CP10 battery: drive the PRODUCTION certbot branch (issue_certificate)
    # exactly as a real VPS clean install would with preflight reporting
    # PREFLIGHT_CERT_PATH='' / certbot available / DNS A-record OK.
    DNS_MATCH=1
    CERTBOT_BIN="$CERTBOT_BIN_ARG"
    PREFLIGHT_HAPROXY_HTTP80=1
    # mirror what preflight detects on a RE-run: the managed acme route
    if grep -q '^# BEGIN ops-terminal acme' "$HAPROXY_CFG" 2>/dev/null; then
      PREFLIGHT_HAPROXY_ACME_ROUTED=1
    else
      PREFLIGHT_HAPROXY_ACME_ROUTED=0
    fi
    note "ACME simulation: DNS_MATCH=1, certbot stub, :80 challenge route managed by the installer"
  fi
else
  [ "$(id -u)" = "0" ] || die "run as root (production install)"
  note "running preflight (read-only)..."
  "$SCRIPT_DIR/preflight.sh" --domain "$DOMAIN" --out /tmp/ops-preflight.env || true
  # STRICT parse — the env file is NEVER sourced as a shell script
  ops_env_read /tmp/ops-preflight.env || die "preflight env file failed strict validation"
  [ "${PREFLIGHT_IS_ROOT:-0}" = "1" ]        || die "preflight: not root"
  [ "${PREFLIGHT_NGINX_AUTH_REQUEST:-0}" = "1" ] || die "preflight: nginx lacks auth_request module"
  [ "${PREFLIGHT_PYTHON_OK:-0}" = "1" ]      || die "preflight: python3 unsuitable"
  [ "${PREFLIGHT_PORT_7680_FREE:-1}" = "1" ] && [ "${PREFLIGHT_PORT_7681_FREE:-1}" = "1" ] \
    && [ "${PREFLIGHT_PORT_7682_FREE:-1}" = "1" ] \
    || { [ "${PREFLIGHT_EXISTING_INSTALL:-0}" = "1" ] || die "preflight: ports 7680/7681/7682 busy (not by this panel)"; }
  TOPOLOGY="${PREFLIGHT_TOPOLOGY:-unknown}"
  VHOST_DIR="${PREFLIGHT_NGINX_VHOST_DIR:-}"
  ENABLE_DIR="${PREFLIGHT_NGINX_ENABLE_DIR:-}"
  EXISTING_CERT="${PREFLIGHT_CERT_PATH:-}"
  CERTBOT_BIN="${CERTBOT_BIN_ARG:-${PREFLIGHT_CERTBOT:-}}"
  DNS_MATCH="${PREFLIGHT_DNS_MATCH:-0}"
  [ -n "${PREFLIGHT_TMUX:-}" ] || TMUX_MISSING=1
  if [ "$TOPOLOGY" = "haproxy-front" ] || [ "$TOPOLOGY" = "haproxy-tcp-passthrough" ]; then
    HAPROXY_CFG="${HAPROXY_CFG_ARG:-${PREFLIGHT_HAPROXY_CFG:-}}"
    HAPROXY_BIN="${HAPROXY_BIN_ARG:-$(command -v haproxy 2>/dev/null || echo /usr/sbin/haproxy)}"
    [ -n "$HAPROXY_CFG" ] || die "preflight did not find a readable haproxy config — stopping (no changes made)"
    [ -x "$HAPROXY_BIN" ] || die "haproxy binary not usable: $HAPROXY_BIN"
    V="$(ha_version_major "$HAPROXY_BIN")"
    [ "${V:-0}" -ge 2 ] || die "haproxy version ${V:-unknown} < 2.0 — unsupported for ACL routing (stopping, no changes made)"
    [ "${PREFLIGHT_HAPROXY_BIND_MODE:-unknown}" != "unknown" ] \
      || die "could not analyse the :443 bind of $HAPROXY_CFG — stopping (no changes made)"
    HAP_RELOAD_MODE="${PREFLIGHT_HAPROXY_RELOAD:-none}"
    [ "$HAP_RELOAD_MODE" != "none" ] \
      || die "no safe reload mechanism for haproxy detected — refusing to edit a live shared config (no changes made)"
    HAP_CERTS_DIR="/etc/haproxy/certs"; CRTLIST="/etc/haproxy/ops-terminal.crtlist"
    HAP_PEM="$HAP_CERTS_DIR/ops-terminal.pem"
    ACME_WEBROOT="${ACME_WEBROOT_ARG:-/var/www/html}"
    CRT_STYLE="${PREFLIGHT_HAPROXY_CRT_STYLE:-none}"; CRT_PATH_BIND="${PREFLIGHT_HAPROXY_CRT_PATH:-}"
    [ "${PREFLIGHT_HAPROXY_BIND_MODE:-}" = "ssl-term" ] || CRT_STYLE="none"
    if [ "$CRT_STYLE" = "none" ] && [ "${PREFLIGHT_HAPROXY_BIND_MODE:-}" = "ssl-term" ]; then
      die "the :443 bind uses ssl without a usable crt/crt-list directive — unsupported (stopping, no changes made)"
    fi
    # baseline: the CURRENT shared config must validate before we touch anything
    ha_haproxy_check "$HAPROXY_BIN" "$HAPROXY_CFG" \
      || die "baseline haproxy -c FAILED on $HAPROXY_CFG — the config is already broken; refusing to touch it (no changes made)"
  elif [ "$TOPOLOGY" != "nginx-direct" ]; then
    cat <<'EOM'

[install] TOPOLOGY NOTICE
  This VPS has an unknown/unsupported :443 owner. The installer stops here,
  BEFORE any change. Send the output of scripts/preflight.sh to the maintainer.
EOM
    die "unsupported reverse-proxy topology: $TOPOLOGY"
  fi
fi

# --------------------------------------------------- operator confirmation --
# (sandbox installs never prompt — they are test harnesses by definition)
if [ "$ASSUME_YES" != "1" ] && [ "$SANDBOX" != "1" ]; then
  printf '\nInstall HANASO OPS Web Terminal for %s?\n' "$DOMAIN"
  printf '  topology: %s\n' "$TOPOLOGY"
  printf '  services : ttyd+gateway+internal nginx on 127.0.0.1 (ports %s/%s/%s)\n' "$TTYD_PORT" "$GATEWAY_PORT" "$PANEL_PORT"
  if [ "$TOPOLOGY" != "nginx-direct" ]; then
    printf '  shared   : %s gets a MANAGED ACL/backend block + VALIDATED reload only (never restart)\n' "$HAPROXY_CFG"
  else
    printf '  shared   : nginx gets a dedicated vhost + reload only (never restart)\n'
  fi
  printf 'Type YES to continue: '
  read -r ANS; [ "$ANS" = "YES" ] || die "aborted by operator"
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
# CP11: from this point on, EVERY failure (die, ERR trap, explicit rollback)
# reverts exactly this panel's changes — no more late exits that leave the
# gateway, the ttyd root shell or a crash-looping unit running.
CHANGES_BEGUN=1
note "backup snapshot -> $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
for p in "$OPT_DIR" "$ETC_DIR" "$VARLIB_DIR" "$VARLOG_DIR"; do
  [ -e "$p" ] && cp -a "$p" "$BACKUP_DIR/$(basename "$(dirname "$p")")-$(basename "$p").bak"
done
if [ "$TOPOLOGY" != "nginx-direct" ] && [ -n "$HAPROXY_CFG" ] && [ -f "$HAPROXY_CFG" ]; then
  cp -a "$HAPROXY_CFG" "$BACKUP_DIR/haproxy.cfg.bak"
  note "independent backup of the shared haproxy.cfg -> $BACKUP_DIR/haproxy.cfg.bak"
fi
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
if [ "$TOPOLOGY" != "nginx-direct" ]; then
  DIRS+=("$INGX_CONF_DIR" "$INGX_VAR_DIR/tmp/client_body" "$INGX_VAR_DIR/tmp/proxy" \
         "$INGX_VAR_DIR/tmp/fastcgi" "$INGX_VAR_DIR/tmp/uwsgi" "$INGX_VAR_DIR/tmp/scgi")
  [ "$SANDBOX" != "1" ] && mkdir -p "$ACME_WEBROOT" 2>/dev/null || true
fi
[ "$SANDBOX" = "1" ] && [ "$SANDBOX_TOPOLOGY" = "nginx" ] && DIRS+=("$NGX_DIR")
for d in "${DIRS[@]}"; do
  if [ ! -d "$d" ]; then mkdir -p "$d"; CREATED_PATHS+=("$d"); fi
done
if [ "$SANDBOX" = "1" ] && [ "$SANDBOX_TOPOLOGY" = "haproxy" ]; then
  mkdir -p "$(dirname "$ACME_WEBROOT")" 2>/dev/null || true
fi
install -m 0755 "$VENDORED_TTYD"      "$OPT_DIR/bin/ttyd"
install -m 0755 "$REPO_DIR/gateway/gateway.py" "$OPT_DIR/gateway/gateway.py"
install -m 0755 "$REPO_DIR/scripts/health-check.sh" "$OPT_DIR/health-check.sh"

# --- environment file
cat > "$ETC_DIR/env" <<EOF
# HANASO OPS Web Terminal — gateway environment (rendered by installer)
OPS_DOMAIN=$DOMAIN
OPS_TOPOLOGY=$TOPOLOGY
GATEWAY_HOST=127.0.0.1
GATEWAY_PORT=$GATEWAY_PORT
TTYD_PORT=$TTYD_PORT
PANEL_LISTEN_PORT=$PANEL_PORT
ACME_WEBROOT=$ACME_WEBROOT
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

# ------------------------------------------------------ internal nginx conf --
render_internal_nginx() {
  # $1 = listen value ("127.0.0.1:PORT" or "127.0.0.1:PORT ssl")
  # $2 = TLS conf block (or empty)
  local tls_conf="$2"
  sed -e "s|{{OPS_DOMAIN}}|$DOMAIN|g" \
      -e "s|{{PANEL_LISTEN}}|$1|g" \
      -e "s|{{TLS_CONF}}|$tls_conf|g" \
      -e "s|{{GATEWAY_PORT}}|$GATEWAY_PORT|g" -e "s|{{TTYD_PORT}}|$TTYD_PORT|g" \
      -e "s|{{ACME_WEBROOT}}|$ACME_WEBROOT|g" \
      -e "s|{{NGINX_LOG_PREFIX}}|$VARLOG_DIR/nginx-ops-terminal.|g" \
      "$REPO_DIR/nginx/ops-terminal-internal.conf.template" > "$INGX_CONF_DIR/ops-terminal-internal.conf"
  # master config for the INDEPENDENT loopback instance
  cat > "$INGX_CONF_DIR/nginx.conf" <<EOF
# HANASO OPS Web Terminal — internal nginx master config (loopback only)
# Managed file — do not edit manually. Remove via scripts/uninstall.sh
# CP11: the systemd unit uses Type=simple — the nginx master must stay in the
# FOREGROUND (daemon off), otherwise systemd tracks a process that exits
# immediately after the daemonizing fork.
daemon off;
worker_processes 1;
error_log $VARLOG_DIR/nginx-internal-master-error.log warn;
pid $INGX_VAR_DIR/nginx.pid;
events { worker_connections 256; }
http {
    include $MIME_TYPES;
    default_type application/octet-stream;
    access_log off;
    client_body_temp_path $INGX_VAR_DIR/tmp/client_body;
    proxy_temp_path      $INGX_VAR_DIR/tmp/proxy;
    fastcgi_temp_path    $INGX_VAR_DIR/tmp/fastcgi;
    uwsgi_temp_path      $INGX_VAR_DIR/tmp/uwsgi;
    scgi_temp_path       $INGX_VAR_DIR/tmp/scgi;
    sendfile on;
    keepalive_timeout 65;
    include $INGX_CONF_DIR/ops-terminal-internal.conf;
}
EOF
}
if [ "$TOPOLOGY" != "nginx-direct" ]; then
  [ -n "$MIME_TYPES" ] || MIME_TYPES="/etc/nginx/mime.types"
  [ -r "$MIME_TYPES" ] || die "mime.types not readable: $MIME_TYPES (internal nginx needs it)"
  render_internal_nginx "127.0.0.1:$PANEL_PORT" ""
  note "internal nginx rendered: $INGX_CONF_DIR/nginx.conf (loopback :$PANEL_PORT)"
fi

# ------------------------------------------------------------ systemd units --
if [ "$SANDBOX" != "1" ]; then
  sed -e "s|-p 7681|-p $TTYD_PORT|" \
      -e "s|TMUX_TMPDIR=/var/tmp/ops-terminal|TMUX_TMPDIR=$VARTMP_DIR|" \
      -e "s|/usr/bin/tmux|$TMUX_BIN|" \
      "$REPO_DIR/systemd/ops-terminal.service"        > "$SYSTEMD_DIR/ops-terminal.service"
  sed -e "s|OPS_TERMINAL_CONF=/etc/ops-terminal/env|OPS_TERMINAL_CONF=$ETC_DIR/env|" \
      -e "s|/usr/bin/python3|$PY_BIN|" \
      -e "s|/opt/ops-terminal|$OPT_DIR|g" \
      "$REPO_DIR/systemd/ops-terminal-gateway.service" > "$SYSTEMD_DIR/ops-terminal-gateway.service"
  if [ "$TOPOLOGY" != "nginx-direct" ]; then
    sed -e "s|/usr/sbin/nginx|$(command -v nginx || echo /usr/sbin/nginx)|" \
        -e "s|/etc/ops-terminal/nginx/nginx.conf|$INGX_CONF_DIR/nginx.conf|g" \
        -e "s|/var/lib/ops-terminal/nginx/nginx.pid|$INGX_VAR_DIR/nginx.pid|g" \
        -e "s|/etc/ops-terminal|$ETC_DIR|g" \
        -e "s|/var/lib/ops-terminal|$VARLIB_DIR|g" \
        -e "s|/var/log/ops-terminal|$VARLOG_DIR|g" \
        "$REPO_DIR/systemd/ops-terminal-nginx.service" > "$SYSTEMD_DIR/ops-terminal-nginx.service"
    # CP11 permission model: the config dir is root-OWNED and read-only for
    # the service user (ops-gw only reads); only the runtime dir (pid, tmp)
    # and the log dir are writable by ops-gw. The service user must not be
    # able to alter its own nginx config.
    chown -R root:ops-gw "$INGX_CONF_DIR" 2>/dev/null || true
    chown -R ops-gw:ops-gw "$INGX_VAR_DIR" 2>/dev/null || true
    chmod 0750 "$INGX_CONF_DIR" "$INGX_VAR_DIR"
  fi
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
sandbox_sweep() {
  # kill ORPHANED processes from previous sandbox runs (paths are unique to this sandbox)
  pkill -f "$OPT_DIR/bin/ttyd" 2>/dev/null || true
  pkill -f "$OPT_DIR/gateway/gateway.py" 2>/dev/null || true
  pkill -f "$INGX_CONF_DIR/nginx.conf" 2>/dev/null || true
  pkill -f "$NGX_DIR/nginx.conf" 2>/dev/null || true
  pkill -f "new -A -s ops" 2>/dev/null || true
  sleep 0.6
}
note "starting gateway + ttyd..."
if [ "$SANDBOX" = "1" ]; then
  sandbox_sweep
  stop_sandbox_svc gateway; stop_sandbox_svc ttyd; stop_sandbox_svc nginx-internal
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
  if [ "$SANDBOX_TOPOLOGY" = "haproxy" ]; then
    # mirror of the systemd ExecStart: -e stderr keeps the EARLY error log
    # (opened before the config parse) away from the compiled-in default
    # /var/log/nginx/error.log, exactly like the production unit.
    nohup "$NGINX_BIN" -c "$INGX_CONF_DIR/nginx.conf" -e stderr \
          >> "$VARLOG_DIR/nginx-internal.log" 2>&1 &
    echo $! > "$RUN_DIR/nginx-internal.pid"
  fi
else
  systemctl enable --now ops-terminal-gateway.service
  systemctl enable --now ops-terminal.service
  if [ "$TOPOLOGY" != "nginx-direct" ]; then
    systemctl enable --now ops-terminal-nginx.service
  fi
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
if [ "$TOPOLOGY" != "nginx-direct" ]; then
  for i in $(seq 1 20); do
    if curl -sf -m 2 "http://127.0.0.1:$PANEL_PORT/health" >/dev/null 2>&1; then break; fi
    sleep 0.5; [ "$i" = "20" ] && die "internal nginx did not become healthy on 127.0.0.1:$PANEL_PORT"
  done
fi
note "loopback services healthy (gateway:$GATEWAY_PORT, ttyd:$TTYD_PORT${INGX_CONF_DIR:+, nginx-internal:$PANEL_PORT})"

if [ "$SKIP_NGINX" = "1" ]; then
  note "--skip-nginx: stopping after loopback services (no external exposure)"
  printf '\n[install] DONE (loopback-only mode)\n'
  exit 0
fi

# ------------------------------------------------------------ TLS material --
PANEL_PEM_SRC_CERT=""; PANEL_PEM_SRC_KEY=""
LE_LIVE_BASE="${OPS_LE_LIVE_BASE:-/etc/letsencrypt}"   # OPS_LE_LIVE_BASE: sandbox ACME simulation only
ACME_ROUTE_PRESENT=0

# validate_cert_pair CERT KEY DOMAIN -> 0 when: readable, valid for >= 24h,
# SAN covers DOMAIN (or its wildcard parent), and the key matches the cert.
validate_cert_pair() {
  local cert="$1" key="$2" dom="$3" c k
  [ -r "$cert" ] && [ -r "$key" ] || { note "cert pair unreadable: $cert / $key"; return 1; }
  openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null 2>&1 \
    || { note "certificate expired or expires within 24h: $cert"; return 1; }
  openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | tr ',' '\n' \
    | grep -qi "DNS:${dom}\|DNS:*.${dom#*.}" \
    || { note "certificate does not cover $dom (SAN): $cert"; return 1; }
  c="$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null \
       | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
  k="$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
  [ -n "$c" ] && [ "$c" = "$k" ] \
    || { note "certificate and key do not match: $cert / $key"; return 1; }
  return 0
}

acme_write_blocks() {
  # Insert the managed ACME ACL after the :$HTTP_PORT frontend bind and append
  # the acme backend. Idempotent (skips blocks already present). Callers own
  # validation/reload: issue_certificate reloads immediately (certbot needs
  # the live route); the external wiring re-adds blocks after its own
  # ha_remove_managed pass and validates/reloads once at the end (CP10 fix:
  # a re-install must NOT silently lose the renewal route).
  local sec lineno blk
  if ! grep -q '^# BEGIN ops-terminal acme ' "$HAPROXY_CFG"; then
    sec="$(ha_find_bind_section "$HAPROXY_CFG" "$HTTP_PORT")" || sec=""
    [ -n "$sec" ] || return 1
    lineno="${sec#*|}"; lineno="${lineno%%|*}"
    blk="$(mktemp)"
    cat > "$blk" <<EOF
# BEGIN ops-terminal acme (managed — keep intact; removed by uninstall.sh)
acl OPS_TERM_ACME path_beg /.well-known/acme-challenge/
# plain use_backend (frontend-level) — haproxy 2.x/3.x have no
# 'http-request use-backend' action (caught by haproxy -c in CP10)
use_backend OPS_TERM_ACME if OPS_TERM_ACME
# END ops-terminal acme
EOF
    ha_insert_after_line "$HAPROXY_CFG" "$lineno" "$blk"; rm -f "$blk"
  fi
  if ! grep -q '^# BEGIN ops-terminal acme-backend' "$HAPROXY_CFG"; then
    cat >> "$HAPROXY_CFG" <<EOF
# BEGIN ops-terminal acme-backend (managed — keep intact; removed by uninstall.sh)
backend OPS_TERM_ACME
    mode http
    server ops_acme 127.0.0.1:$PANEL_PORT check inter 2s fall 3 rise 2
# END ops-terminal acme-backend
EOF
  fi
  HAP_TOUCHED=1
  ACME_ROUTE_PRESENT=1
  return 0
}

issue_certificate() {
  # Production certbot issuance through the HAProxy :80 path.
  # Returns 0 on success and sets PANEL_PEM_SRC_CERT/KEY; fail-closed otherwise.
  if [ -z "$CERTBOT_BIN" ] || [ "$DNS_MATCH" != "1" ]; then
    return 1
  fi
  local acme_routed="${PREFLIGHT_HAPROXY_ACME_ROUTED:-0}"
  local acme_added=0 webroot="" tried=""
  if [ "$acme_routed" != "1" ]; then
    # Add a MANAGED acme ACL into the :80 frontend (validated + reload).
    # The internal nginx (already healthy) serves the webroot on 127.0.0.1:$PANEL_PORT.
    [ "${PREFLIGHT_HAPROXY_HTTP80:-0}" = "1" ] || return 1
    acme_write_blocks || return 1
    ha_haproxy_check "$HAPROXY_BIN" "$HAPROXY_CFG" \
      || { haproxy_revert_edits; return 1; }
    haproxy_reload || { haproxy_revert_edits; return 1; }
    HAP_RELOADED=1
    acme_added=1
    note "managed ACME HTTP-01 route added to the :80 frontend (validated + reloaded)"
  else
    ACME_ROUTE_PRESENT=1
  fi
  for webroot in "$ACME_WEBROOT" /var/www/html /var/www/letsencrypt; do
    [ -d "$webroot" ] || continue
    [ "$tried" != "" ] && [ "$acme_routed" = "1" ] && break
    tried="$tried $webroot"
    mkdir -p "$webroot"
    note "certbot: issuing Let's Encrypt certificate for $DOMAIN (webroot $webroot)..."
    ACME_FLAGS="--register-unsafely-without-email"
    [ -n "$ACME_EMAIL" ] && ACME_FLAGS="--email $ACME_EMAIL --no-eff-email"
    if "$CERTBOT_BIN" certonly --webroot -w "$webroot" -d "$DOMAIN" \
         --non-interactive --agree-tos $ACME_FLAGS --keep-until-expiring; then
      PANEL_PEM_SRC_CERT="$LE_LIVE_BASE/live/$DOMAIN/fullchain.pem"
      PANEL_PEM_SRC_KEY="$LE_LIVE_BASE/live/$DOMAIN/privkey.pem"
      if validate_cert_pair "$PANEL_PEM_SRC_CERT" "$PANEL_PEM_SRC_KEY" "$DOMAIN"; then
        # renewal deploy hook keeps the HAProxy PEM fresh (production only)
        if [ "$SANDBOX" != "1" ] && [ "$TOPOLOGY" = "haproxy-front" ]; then
          DEPLOY_HOOK="$LE_LIVE_BASE/renewal-hooks/deploy/ops-terminal-haproxy.sh"
          mkdir -p "$(dirname "$DEPLOY_HOOK")"
          cat > "$DEPLOY_HOOK" <<EOF
#!/bin/sh
# Managed by hanaso-ops-terminal — rebuilds the HAProxy PEM on renewal.
cat "$PANEL_PEM_SRC_CERT" "$PANEL_PEM_SRC_KEY" > "$HAP_PEM" && \\
  $HAPROXY_BIN -c -f "$HAPROXY_CFG" && (systemctl reload haproxy 2>/dev/null || kill -USR2 \$(cat /run/haproxy.pid) 2>/dev/null)
EOF
          chmod 0755 "$DEPLOY_HOOK"
        fi
        return 0
      fi
      # CP10: a certbot success whose files are unreadable/expired/domain-
      # mismatched/key-mismatched must NOT reach HAProxy — fail closed.
      note "issued certificate FAILED validation — treating issuance as failed (fail-closed)"
      PANEL_PEM_SRC_CERT=""; PANEL_PEM_SRC_KEY=""
    fi
    [ "$acme_added" = "1" ] && break
  done
  # issuance failed: leave HAProxy exactly as it was
  if [ "$acme_added" = "1" ]; then
    haproxy_revert_edits
    HAP_TOUCHED=0; HAP_RELOADED=0; ACME_ROUTE_PRESENT=0
  fi
  return 1
}

if [ "$SANDBOX" = "1" ] && [ "$SIMULATE_ACME" != "1" ]; then
  [ -n "$TLS_CERT" ] && [ -n "$TLS_KEY" ] \
    || die "--sandbox-topology haproxy requires --tls-cert/--tls-key (test certificate)"
  PANEL_PEM_SRC_CERT="$TLS_CERT"; PANEL_PEM_SRC_KEY="$TLS_KEY"
  validate_cert_pair "$PANEL_PEM_SRC_CERT" "$PANEL_PEM_SRC_KEY" "$DOMAIN" \
    || die "provided test certificate failed validation (readable/valid/covers $DOMAIN/matches key)"
  note "sandbox mode: using provided test certificate"
else
  # Production selection chain — ALSO runs for --sandbox --simulate-acme
  # (CP10 battery: the same code path the real VPS takes on a clean install
  # where preflight reports PREFLIGHT_CERT_PATH='' / OPS_CERT_EXISTS=0).
  EXISTING_CERT="${EXISTING_CERT:-}"
  if [ -n "$TLS_CERT" ]; then
    validate_cert_pair "$TLS_CERT" "$TLS_KEY" "$DOMAIN" \
      || die "provided certificate failed validation (readable/valid/covers $DOMAIN/matches key)"
  fi
  if [ -n "$EXISTING_CERT" ]; then
    if validate_cert_pair "$EXISTING_CERT" "$(dirname "$EXISTING_CERT")/privkey.pem" "$DOMAIN"; then
      note "existing certificate validated: $EXISTING_CERT"
    else
      note "preflight certificate path failed install-time validation — will try fresh issuance: $EXISTING_CERT"
      EXISTING_CERT=""
    fi
  fi
  if [ -z "$TLS_CERT" ]; then
    if [ -n "$EXISTING_CERT" ] && [ "$TOPOLOGY" != "nginx-direct" ]; then
      PANEL_PEM_SRC_CERT="$EXISTING_CERT"; PANEL_PEM_SRC_KEY="$(dirname "$EXISTING_CERT")/privkey.pem"
      note "reusing existing certificate: $EXISTING_CERT"
    elif [ -n "$EXISTING_CERT" ]; then
      TLS_CERT="$EXISTING_CERT"; TLS_KEY="$(dirname "$EXISTING_CERT")/privkey.pem"
      note "reusing existing certificate: $TLS_CERT"
    elif [ "$TOPOLOGY" != "nginx-direct" ]; then
      if ! issue_certificate; then
        cat <<'EOM'

[install] TLS GATE — certificate issuance FAILED or unavailable.
  The panel stays in SAFE loopback-only mode: no HAProxy edit for the panel
  remains and nothing is exposed to the internet. Fix DNS (A record -> this
  host), the ACME route or provide a certificate, then re-run this installer.
EOM
        note "loopback-only install completed; stopping before external exposure"
        printf '\n[install] DONE (loopback-only, TLS/DNS gate)\n'
        exit 0
      fi
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
      TLS_CERT="$LE_LIVE_BASE/live/$DOMAIN/fullchain.pem"
      TLS_KEY="$LE_LIVE_BASE/live/$DOMAIN/privkey.pem"
      validate_cert_pair "$TLS_CERT" "$TLS_KEY" "$DOMAIN" \
        || die "issued certificate failed validation (fail-closed): $TLS_CERT"
    else
      cat <<'EOM'

[install] TLS GATE — DNS or TLS not ready.
  * DNS: the domain must resolve to THIS host (currently: see preflight output).
  * TLS: no covering certificate exists and certbot is unavailable.
  The panel stays in SAFE loopback-only mode (services run on 127.0.0.1 only;
  no proxy edit added; nothing exposed). Re-run the installer after fixing.
EOM
      note "loopback-only install completed; stopping before external exposure"
      printf '\n[install] DONE (loopback-only, TLS/DNS gate)\n'
      exit 0
    fi
  fi
  if [ "$TOPOLOGY" = "nginx-direct" ]; then
    [ -r "$TLS_CERT" ] && [ -r "$TLS_KEY" ] || die "certificate files unreadable"
  else
    # CP10 fix: for haproxy topologies the material lives in PANEL_PEM_SRC_*;
    # the previous check tested TLS_* and would have died even AFTER a
    # successful issuance (latent bug, never reachable before the parser fix).
    if [ -z "$PANEL_PEM_SRC_CERT" ] && [ -n "$TLS_CERT" ]; then
      PANEL_PEM_SRC_CERT="$TLS_CERT"; PANEL_PEM_SRC_KEY="$TLS_KEY"
    fi
    [ -r "$PANEL_PEM_SRC_CERT" ] && [ -r "$PANEL_PEM_SRC_KEY" ] || die "certificate files unreadable"
  fi
fi

# ------------------------------------------------------------ external wiring --
if [ "$TOPOLOGY" = "nginx-direct" ]; then
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
fi

if [ "$TOPOLOGY" != "nginx-direct" ]; then
  # ---- shared HAProxy: managed SNI/Host route + (ssl-term) cert integration ----
  SEC443="$(ha_find_bind_section "$HAPROXY_CFG" "$HTTPS_PORT")" || SEC443=""
  [ -n "$SEC443" ] || { die "could not locate a :${HTTPS_PORT} frontend in $HAPROXY_CFG (rollback keeps services loopback-only)"; }
  FRONT443_NAME="${SEC443%%|*}"; FRONT443_LINE="${SEC443#*|}"; FRONT443_LINE="${FRONT443_LINE%%|*}"
  BIND443_LINE="${SEC443##*|}"
  note "HAProxy :443 section: '$FRONT443_NAME' (line $FRONT443_LINE)"
  # idempotency: drop any previous managed blocks of ours first
  ha_remove_managed "$HAPROXY_CFG" >/dev/null || true
  # re-run crt analysis on the CURRENT config (handles re-install after crt-list conversion)
  CRT_NOW="$(ha_bind_crt "$BIND443_LINE")"
  CRT_STYLE_NOW="${CRT_NOW%%|*}"; CRT_PATH_NOW="${CRT_NOW#*|}"
  if [ -z "$CRT_NOW" ]; then
    die "the :${HTTPS_PORT} bind carries no crt/crt-list directive — unsupported ($BIND443_LINE)"
  fi
  # resolve the RAW keyword to the filesystem style (same semantics as preflight):
  #   'crt' + directory -> dir (PEM drop-in), 'crt' + file -> file (reversible
  #   crt-list conversion), the crt-list keyword itself -> crt-list (append).
  if [ "$CRT_STYLE_NOW" != "crt-list" ]; then
    if [ -d "$CRT_PATH_NOW" ]; then CRT_STYLE_NOW="dir"
    elif [ -f "$CRT_PATH_NOW" ]; then CRT_STYLE_NOW="file"
    else CRT_STYLE_NOW="none"
    fi
  fi
  if [ "$TOPOLOGY" = "haproxy-front" ]; then
    ha_bind_ssl "$BIND443_LINE" || die "expected a TLS-terminating bind on :$HTTPS_PORT but found none (config changed?)"
    # -------- certificate material into HAProxy --------
    mkdir -p "$HAP_CERTS_DIR"
    case "$CRT_STYLE_NOW" in
      dir)
        HAP_PEM="$CRT_PATH_NOW/ops-terminal.pem"
        cat "$PANEL_PEM_SRC_CERT" "$PANEL_PEM_SRC_KEY" > "$HAP_PEM"
        chmod 0600 "$HAP_PEM"; HAP_PEM_CREATED=1
        note "panel PEM dropped into the existing crt directory: $HAP_PEM (no bind edit)"
        ;;
      crt-list)
        # append our PEM to the existing crt-list (idempotent)
        HAP_PEM="$HAP_CERTS_DIR/ops-terminal.pem"
        [ "$CRT_PATH_NOW" != "$HAP_PEM" ] && { cat "$PANEL_PEM_SRC_CERT" "$PANEL_PEM_SRC_KEY" > "$HAP_PEM"; chmod 0600 "$HAP_PEM"; HAP_PEM_CREATED=1; }
        grep -qxF "$HAP_PEM" "$CRT_PATH_NOW" || echo "$HAP_PEM" >> "$CRT_PATH_NOW"
        note "panel PEM appended to the existing crt-list: $CRT_PATH_NOW"
        ;;
      file)
        # reversible conversion: bind 'crt FILE' -> 'crt-list CRTLIST' (orig + ours)
        HAP_PEM="$HAP_CERTS_DIR/ops-terminal.pem"
        cat "$PANEL_PEM_SRC_CERT" "$PANEL_PEM_SRC_KEY" > "$HAP_PEM"
        chmod 0600 "$HAP_PEM"; HAP_PEM_CREATED=1
        printf '%s\n%s\n' "$CRT_PATH_NOW" "$HAP_PEM" > "$CRTLIST"
        HAP_CRTLIST_CREATED=1; CRT_PATH_BIND="$CRT_PATH_NOW"
        sed -i "s|crt $CRT_PATH_NOW|crt-list $CRTLIST|g" "$HAPROXY_CFG"
        HAP_BIND_EDITED=1
        note "reversible bind edit: crt $CRT_PATH_NOW -> crt-list $CRTLIST (original cert kept)"
        ;;
      *)
        die "unsupported crt style on the :443 bind: $CRT_STYLE_NOW ($BIND443_LINE)"
        ;;
    esac
    # -------- frontend managed block --------
    BLK="$(mktemp)"
    cat > "$BLK" <<EOF
# BEGIN ops-terminal (managed — keep intact; removed by uninstall.sh)
acl OPS_TERM_SNI ssl_fc_sni -i $DOMAIN
acl OPS_TERM_HOST hdr(host) -i $DOMAIN
use_backend OPS_TERM_BACKEND if OPS_TERM_SNI || OPS_TERM_HOST
# END ops-terminal
EOF
    ha_insert_after_line "$HAPROXY_CFG" "$FRONT443_LINE" "$BLK"; rm -f "$BLK"
    HAP_TOUCHED=1
    # -------- backend managed block --------
    cat >> "$HAPROXY_CFG" <<EOF
# BEGIN ops-terminal backend (managed — keep intact; removed by uninstall.sh)
backend OPS_TERM_BACKEND
    mode http
    http-request del-header X-Forwarded-For
    http-request add-header X-Forwarded-For %[src]
    http-response add-header Strict-Transport-Security "max-age=31536000"
    timeout tunnel 7d
    timeout server 7d
    timeout connect 5s
    server ops_panel 127.0.0.1:$PANEL_PORT check inter 2s fall 3 rise 2
# END ops-terminal backend
EOF
  elif [ "$TOPOLOGY" = "haproxy-tcp-passthrough" ]; then
    if ha_bind_ssl "$BIND443_LINE"; then
      die "expected a TCP (non-ssl) bind on :443 but TLS termination is configured — topology changed?"
    fi
    # internal nginx terminates TLS for the panel domain
    install -m 0644 "$PANEL_PEM_SRC_CERT" "$INGX_TLS_DIR/fullchain.pem" 2>/dev/null || {
      mkdir -p "$INGX_TLS_DIR"; install -m 0644 "$PANEL_PEM_SRC_CERT" "$INGX_TLS_DIR/fullchain.pem"; }
    install -m 0640 "$PANEL_PEM_SRC_KEY" "$INGX_TLS_DIR/privkey.pem"
    if [ "$SANDBOX" != "1" ]; then chown -R root:ops-gw "$INGX_TLS_DIR"; fi
    TLS_BLOCK="ssl_certificate     $INGX_TLS_DIR/fullchain.pem;
        ssl_certificate_key $INGX_TLS_DIR/privkey.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;"
    render_internal_nginx "127.0.0.1:$PANEL_PORT ssl" "$TLS_BLOCK"
    note "internal nginx re-rendered with TLS (passthrough topology): $INGX_TLS_DIR"
    # restart the internal nginx (config gained ssl material) — OUR service only
    if [ "$SANDBOX" = "1" ]; then
      stop_sandbox_svc nginx-internal
      nohup "$NGINX_BIN" -c "$INGX_CONF_DIR/nginx.conf" -e stderr >> "$VARLOG_DIR/nginx-internal.log" 2>&1 &
      echo $! > "$RUN_DIR/nginx-internal.pid"
    else
      systemctl restart ops-terminal-nginx.service
    fi
    for i in $(seq 1 20); do
      if curl -skf -m 2 "https://127.0.0.1:$PANEL_PORT/health" >/dev/null 2>&1; then break; fi
      sleep 0.5; [ "$i" = "20" ] && die "internal nginx (TLS) did not become healthy on 127.0.0.1:$PANEL_PORT"
    done
    # -------- frontend managed block (SNI on raw TCP) --------
    SECBODY="$(ha_section_text "$HAPROXY_CFG" "$FRONT443_NAME")"
    BLK="$(mktemp)"
    {
      echo "# BEGIN ops-terminal (managed — keep intact; removed by uninstall.sh)"
      echo "$SECBODY" | grep -qE '^[[:space:]]*tcp-request[[:space:]]+inspect-delay' \
        || echo "    tcp-request inspect-delay 5s"
      echo "    acl OPS_TERM_SNI req.ssl_sni -i $DOMAIN"
      echo "$SECBODY" | grep -qE '^[[:space:]]*tcp-request[[:space:]]+content[[:space:]]+accept' \
        || echo "    tcp-request content accept if OPS_TERM_SNI"
      echo "    use_backend OPS_TERM_BACKEND if OPS_TERM_SNI"
      echo "# END ops-terminal"
    } > "$BLK"
    ha_insert_after_line "$HAPROXY_CFG" "$FRONT443_LINE" "$BLK"; rm -f "$BLK"
    HAP_TOUCHED=1
    cat >> "$HAPROXY_CFG" <<EOF
# BEGIN ops-terminal backend (managed — keep intact; removed by uninstall.sh)
backend OPS_TERM_BACKEND
    mode tcp
    timeout tunnel 7d
    timeout server 7d
    timeout connect 5s
    server ops_panel 127.0.0.1:$PANEL_PORT check inter 2s fall 3 rise 2
# END ops-terminal backend
EOF
  fi

  # -------- ACME route persistence (CP10 fix) --------
  # The idempotency pass above removes ALL managed blocks — including the
  # acme route installed by a PREVIOUS run (or by issuance in THIS run).
  # Re-add it before the single validated reload, or future Let's Encrypt
  # renewals would silently stop routing the HTTP-01 challenge.
  if [ "$ACME_ROUTE_PRESENT" = "1" ] || [ "${PREFLIGHT_HAPROXY_ACME_ROUTED:-0}" = "1" ]; then
    acme_write_blocks || { rollback; die "could not (re-)add the managed ACME route — reverted"; }
    note "managed ACME route present on the :80 frontend (renewals keep working)"
  fi

  # -------- validate BEFORE reload — always --------
  note "HAProxy: validating edited configuration (haproxy -c) BEFORE any reload..."
  if ! ha_haproxy_check "$HAPROXY_BIN" "$HAPROXY_CFG"; then
    rollback
    die "haproxy -c FAILED on the edited config — no reload happened; changes reverted (services keep running loopback-only)"
  fi
  note "haproxy -c passed"
  note "HAProxy: controlled RELOAD (existing routes stay online; never a restart)..."
  haproxy_reload || { rollback; die "haproxy reload failed — reverted (services keep running loopback-only)"; }
  HAP_RELOADED=1
  # liveness probe of the shared edge
  sleep 0.5
  if ! ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":${HTTPS_PORT}$"; then
    rollback
    die "edge port ${HTTPS_PORT} stopped answering after reload — reverted"
  fi
  note "HAProxy reloaded; edge port ${HTTPS_PORT} still owned by haproxy (reload only)"
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
    E2E_ARGS+=(--insecure-allow --expect-uid "${E2E_EXPECT_UID:-$(id -u)}")
  else
    E2E_ARGS+=(--expect-uid "${E2E_EXPECT_UID:-0}")
  fi
  if printf '%s\n' "$PANEL_PASSWORD" | "$PY_BIN" "$REPO_DIR/scripts/e2e-test.py" "${E2E_ARGS[@]}"; then
    note "end-to-end verification PASSED"
  else
    cat <<'EOM'

[install] END-TO-END VERIFICATION FAILED.
  Rolling back this panel's changes (managed proxy blocks removed; shared
  services untouched; panel services stay loopback-only or stopped).
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
printf ' Topology    : %s\n' "$TOPOLOGY"
if [ "$TOPOLOGY" != "nginx-direct" ]; then
  printf ' HAProxy     : %s (managed blocks + validated reload only)\n' "$HAPROXY_CFG"
  printf ' Panel PEM   : %s\n' "${HAP_PEM:-$INGX_TLS_DIR/fullchain.pem (internal nginx TLS)}"
fi
printf ' Credential  : %s\n' "$CRED_SUMMARY"
if [ -n "${PANEL_PASSWORD:-}" ]; then
  printf ' USERNAME    : %s\n' "$PANEL_USERNAME"
  printf ' PASSWORD    : %s\n' "$PANEL_PASSWORD"
  printf '               (shown ONCE — save it now; it is not stored anywhere in cleartext)\n'
fi
printf ' Services    : ops-terminal-gateway  ops-terminal%s\n' "$([ "$TOPOLOGY" != "nginx-direct" ] && echo '  ops-terminal-nginx' || echo '')"
printf ' Logs        : %s/gateway.log  (login/logout events + IP)\n' "$VARLOG_DIR"
printf ' Docs        : docs/INSTALL.md  docs/SECURITY.md  docs/ROLLBACK.md\n'
printf ' Rotate pass : %s\n' "$([ "$SANDBOX" = "1" ] && echo "$PY_BIN $OPT_DIR/gateway/gateway.py passwd --generate --print-once" || echo 'ops-terminal-passwd  (or panel: /change-password)')"
printf ' Uninstall   : %s/scripts/uninstall.sh%s\n' "$REPO_DIR" "$([ "$SANDBOX" = "1" ] && echo ' --sandbox' || echo '')"
printf ' Backup now  : %s\n' "$BACKUP_DIR"
printf '==========================================================\n'
printf ' Do NOT redirect this output to a file (it contains the one-time password).\n'
printf '==========================================================\n'
exit 0
