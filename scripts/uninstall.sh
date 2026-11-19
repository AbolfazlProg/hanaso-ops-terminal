#!/usr/bin/env bash
# ==========================================================================
# HANASO OPS Web Terminal — Uninstaller
# Removes ONLY files/services owned by this panel. Never touches other
# vhosts, services, containers, volumes or the shared reverse-proxy config
# beyond this panel's own managed blocks (BEGIN/END ops-terminal markers)
# and the reversible crt-list conversion of its certificate.
# A RELOAD (never restart) of nginx / HAProxy is performed after validation.
#
# Topology awareness:
#   * nginx-direct              : removes the dedicated vhost + reloads nginx
#   * haproxy-front             : removes managed SNI/Host ACL + backend,
#                                 reverts the crt->crt-list bind conversion
#                                 (original cert is restored), deletes the
#                                 panel PEM/crtlist, stops the internal
#                                 loopback nginx, reloads HAProxy
#   * haproxy-tcp-passthrough   : same HAProxy cleanup (TLS block on the
#                                 internal nginx dies with its config dir)
#
# Usage:  uninstall.sh [--yes] [--sandbox] [--purge] [--purge-packages]
#                      [--haproxy-cfg PATH] [--haproxy-bin PATH]
#                      [--haproxy-pidfile PATH]
#   --yes     skip confirmation
#   --sandbox remove a --sandbox test installation
#   --purge   also remove logs, state and backups (default: kept)
#   --purge-packages  ALSO apt-purge the distro nginx + certbot packages the
#            standalone install brought in (default: kept — harmless on a
#            dedicated server; this flag is opt-in because removing nginx
#            could affect other local uses)
# ==========================================================================
set -Eeuo pipefail
die()  { printf '[uninstall][FATAL] %s\n' "$*" >&2; exit 1; }
note() { printf '[uninstall] %s\n' "$*"; }
warn() { printf '[uninstall][WARN] %s\n' "$*"; }

ASSUME_YES=0; SANDBOX=0; PURGE=0; PURGE_PACKAGES=0
HAPROXY_CFG_ARG=""; HAPROXY_BIN_ARG=""; HAPROXY_PIDFILE_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) ASSUME_YES=1; shift ;;
    --sandbox) SANDBOX=1; shift ;;
    --purge) PURGE=1; shift ;;
    --purge-packages) PURGE_PACKAGES=1; shift ;;
    --haproxy-cfg) HAPROXY_CFG_ARG="$2"; shift 2 ;;
    --haproxy-bin) HAPROXY_BIN_ARG="$2"; shift 2 ;;
    --haproxy-pidfile) HAPROXY_PIDFILE_ARG="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=ops-haproxy.sh
[ -r "$SCRIPT_DIR/ops-haproxy.sh" ] && . "$SCRIPT_DIR/ops-haproxy.sh" \
  || die "scripts/ops-haproxy.sh missing next to uninstall.sh"
# shellcheck source=ops-systemd.sh
[ -r "$SCRIPT_DIR/ops-systemd.sh" ] && . "$SCRIPT_DIR/ops-systemd.sh" \
  || die "scripts/ops-systemd.sh missing next to uninstall.sh"

if [ "$SANDBOX" = "1" ]; then
  SB_ROOT="${OPS_SANDBOX_ROOT:-$HOME/ops-sandbox}"
  OPT_DIR="$SB_ROOT/opt/ops-terminal";  ETC_DIR="$SB_ROOT/etc/ops-terminal"
  VARLIB_DIR="$SB_ROOT/var/lib/ops-terminal"; VARLOG_DIR="$SB_ROOT/var/log/ops-terminal"
  VARTMP_DIR="$SB_ROOT/var/tmp/ops-terminal"; RUN_DIR="$SB_ROOT/run"
  NGX_DIR="$SB_ROOT/nginx"
  VHOST_FILE="$NGX_DIR/ops-terminal.conf"
  NGINX_BIN="${OPS_SANDBOX_NGINX_BIN:-}"
  BACKUP_BASE="$SB_ROOT/backups"
  HAPROXY_CFG="${HAPROXY_CFG_ARG:-$SB_ROOT/etc/haproxy/haproxy.cfg}"
  HAPROXY_BIN="${HAPROXY_BIN_ARG:-$SB_ROOT/usr/sbin/haproxy}"
  HAPROXY_PIDFILE="${HAPROXY_PIDFILE_ARG:-$SB_ROOT/run/haproxy.pid}"
  CRTLIST="$SB_ROOT/etc/haproxy/ops-terminal.crtlist"
  HAP_CERTS_DIR="$SB_ROOT/etc/haproxy/certs"
else
  [ "$(id -u)" = "0" ] || die "run as root"
  OPT_DIR="/opt/ops-terminal";  ETC_DIR="/etc/ops-terminal"
  VARLIB_DIR="/var/lib/ops-terminal"; VARLOG_DIR="/var/log/ops-terminal"
  VARTMP_DIR="/var/tmp/ops-terminal"; RUN_DIR="/run/ops-terminal"
  VHOST_FILE="/etc/nginx/sites-available/ops-terminal.conf"
  [ -e "$VHOST_FILE" ] || VHOST_FILE="/etc/nginx/conf.d/ops-terminal.conf"
  WEBROOT_DIR="/var/www/ops-terminal"          # CP13 standalone ACME webroot
  BACKUP_BASE="/var/backups/ops-terminal"
  HAPROXY_CFG="${HAPROXY_CFG_ARG:-/etc/haproxy/haproxy.cfg}"
  HAPROXY_BIN="${HAPROXY_BIN_ARG:-$(command -v haproxy 2>/dev/null || echo /usr/sbin/haproxy)}"
  HAPROXY_PIDFILE="${HAPROXY_PIDFILE_ARG:-/run/haproxy.pid}"
  [ -r "$HAPROXY_PIDFILE" ] || HAPROXY_PIDFILE="/var/run/haproxy.pid"
  CRTLIST="/etc/haproxy/ops-terminal.crtlist"
  HAP_CERTS_DIR="/etc/haproxy/certs"
fi

# ---- topology (from the installer's env file; blank if none recorded) ----
TOPOLOGY=""
[ -r "$ETC_DIR/env" ] && TOPOLOGY="$(sed -n 's/^OPS_TOPOLOGY=//p' "$ETC_DIR/env" | head -n1)"
case "${TOPOLOGY:-}" in
  nginx-direct|haproxy-front|haproxy-tcp-passthrough|standalone) ;;
  *) TOPOLOGY="" ;;   # unknown/missing -> infer from artifacts below
esac
HAP_IS_OURS=0
if [ -r "$HAPROXY_CFG" ] && grep -q '^# BEGIN ops-terminal' "$HAPROXY_CFG" 2>/dev/null; then
  HAP_IS_OURS=1
fi
[ -f "$CRTLIST" ] && HAP_IS_OURS=1
if [ -z "$TOPOLOGY" ]; then
  if [ "$HAP_IS_OURS" = "1" ]; then TOPOLOGY="haproxy-front"
  elif [ -f /etc/systemd/system/ops-terminal-front.service ] || [ -d "$ETC_DIR/nginx-front" ]; then
    TOPOLOGY="standalone"   # CP13: front unit artifacts without an env file
  else TOPOLOGY="nginx-direct"; fi
  note "topology not recorded — inferred: $TOPOLOGY"
fi

# --purge-packages may run AFTER a successful uninstall (a package-cleanup
# pass) — with nothing left installed it must still work, purging only the
# distro packages and any leftover unit files.
[ -e "$ETC_DIR/env" ] || [ -e "$OPT_DIR" ] || [ "$HAP_IS_OURS" = "1" ] \
  || [ "$PURGE_PACKAGES" = "1" ] \
  || die "no installation found at $ETC_DIR / $OPT_DIR (and no managed HAProxy blocks)"

if [ "$ASSUME_YES" != "1" ]; then
  printf 'Remove HANASO OPS Web Terminal completely?\n'
  printf '  topology : %s\n' "$TOPOLOGY"
  printf '  (services, files, proxy routing — other vhosts/services untouched)\n'
  printf '  logs/state/backups are KEPT unless --purge\n'
  printf 'Type YES to continue: '; read -r ANS; [ "$ANS" = "YES" ] || die "aborted"
fi

# --- 1. stop services -------------------------------------------------------
if [ "$SANDBOX" = "1" ]; then
  for f in gateway ttyd nginx-internal; do
    if [ -f "$RUN_DIR/$f.pid" ]; then
      note "stopping sandbox $f (pid $(cat "$RUN_DIR/$f.pid"))"
      kill "$(cat "$RUN_DIR/$f.pid")" 2>/dev/null || true
      rm -f "$RUN_DIR/$f.pid"
    fi
  done
  # sweep orphans from previous runs (unique sandbox paths)
  pkill -f "$SB_ROOT/opt/ops-terminal/bin/ttyd" 2>/dev/null || true
  pkill -f "$SB_ROOT/opt/ops-terminal/gateway/gateway.py" 2>/dev/null || true
  pkill -f "$SB_ROOT/nginx/nginx.conf" 2>/dev/null || true
  pkill -f "$ETC_DIR/nginx/nginx.conf" 2>/dev/null || true
  pkill -f "new -A -s ops" 2>/dev/null || true
  if [ -f "$RUN_DIR/nginx.pid" ] && [ -n "$NGINX_BIN" ]; then
    note "stopping sandbox nginx harness"
    "$NGINX_BIN" -c "$NGX_DIR/nginx.conf" -s stop 2>/dev/null || kill "$(cat "$RUN_DIR/nginx.pid")" 2>/dev/null || true
  fi
else
  note "stopping + disabling systemd services (restart loop broken, failed state cleared)"
  systemd_stop_panel_units
fi

# --- 1b. revert HAProxy edits (managed blocks + reversible bind conversion) --
if [ "$TOPOLOGY" != "nginx-direct" ] && [ -r "$HAPROXY_CFG" ] && [ "$HAP_IS_OURS" = "1" ]; then
  note "reverting managed blocks in $HAPROXY_CFG ..."
  # (a) reversible crt->crt-list conversion: the crtlist's FIRST line is the
  #     original cert path recorded by the installer
  if [ -f "$CRTLIST" ]; then
    ORIG_CRT="$(head -n1 "$CRTLIST" | tr -d '[:space:]')"
    if [ -n "$ORIG_CRT" ] && grep -qE "crt-list ${CRTLIST}([[:space:]]|\$|,)" "$HAPROXY_CFG"; then
      sed -i "s|crt-list ${CRTLIST}|crt ${ORIG_CRT}|g" "$HAPROXY_CFG"
      note "bind reverted: crt-list $CRTLIST -> crt $ORIG_CRT (original cert restored)"
    else
      warn "crtlist $CRTLIST exists but its bind reference is gone (already reverted?)"
    fi
  fi
  # (b) drop our PEMs (ours by name only; operator certs are never touched)
  rm -f "$HAP_CERTS_DIR/ops-terminal.pem" "$CRTLIST"
  # (c) crt-dir style: our PEM lives inside the operator's crt directory
  CRT_DIR_NOW="$(awk '/^[[:space:]]*bind[[:space:]][^#]*:443([[:space:]]|$)/ {
      for (i=1;i<=NF;i++) if ($i=="crt") { print $(i+1); exit } }' "$HAPROXY_CFG" 2>/dev/null || true)"
  if [ -n "$CRT_DIR_NOW" ] && [ -d "$CRT_DIR_NOW" ] && [ -f "$CRT_DIR_NOW/ops-terminal.pem" ]; then
    rm -f "$CRT_DIR_NOW/ops-terminal.pem"
    note "panel PEM removed from the crt directory: $CRT_DIR_NOW/ops-terminal.pem"
  fi
  # (d) surgical removal of every BEGIN/END ops-terminal block
  removed="$(ha_remove_managed "$HAPROXY_CFG")"
  note "removed $removed managed block(s)"
  # (e) validate + reload (fallback: newest backup)
  if ha_haproxy_check "$HAPROXY_BIN" "$HAPROXY_CFG"; then
    note "haproxy config validates after removal"
    if [ "$SANDBOX" = "1" ]; then
      [ -r "$HAPROXY_PIDFILE" ] && kill -USR2 "$(head -n1 "$HAPROXY_PIDFILE")" \
        && note "HAProxy reloaded (SIGUSR2 via sandbox pidfile)"
    elif command -v systemctl >/dev/null 2>&1 \
         && systemctl list-unit-files haproxy.service >/dev/null 2>&1; then
      systemctl reload haproxy && note "HAProxy reloaded (systemctl)"
    elif [ -r "$HAPROXY_PIDFILE" ]; then
      kill -USR2 "$(head -n1 "$HAPROXY_PIDFILE")" && note "HAProxy reloaded (SIGUSR2 pidfile)"
    else
      warn "no HAProxy reload mechanism found — config edited on disk; reload it manually"
    fi
  else
    warn "haproxy -c FAILED after removal — restoring newest backup"
    BAK="$(ls -1t "$BACKUP_BASE"/*/haproxy.cfg.bak "$BACKUP_BASE"/haproxy.cfg.bak 2>/dev/null | head -n1 || true)"
    if [ -n "$BAK" ]; then
      cp -a "$BAK" "$HAPROXY_CFG"
      if ha_haproxy_check "$HAPROXY_BIN" "$HAPROXY_CFG"; then
        [ "$SANDBOX" = "1" ] && [ -r "$HAPROXY_PIDFILE" ] \
          && kill -USR2 "$(head -n1 "$HAPROXY_PIDFILE")" || true
        [ "$SANDBOX" != "1" ] && systemctl reload haproxy 2>/dev/null || true
        note "restored from $BAK and reloaded"
      else
        die "restored backup also fails validation — manual action required ($HAPROXY_CFG)"
      fi
    else
      die "no haproxy.cfg backup found under $BACKUP_BASE — manual action required"
    fi
  fi
fi
# ACME issuance hooks (production only)
if [ "$SANDBOX" != "1" ]; then
  [ -f /etc/letsencrypt/renewal-hooks/deploy/ops-terminal-haproxy.sh ] \
    && rm -f /etc/letsencrypt/renewal-hooks/deploy/ops-terminal-haproxy.sh \
    && note "certbot renewal deploy hook removed (haproxy)"
  [ -f /etc/letsencrypt/renewal-hooks/deploy/ops-terminal-standalone.sh ] \
    && rm -f /etc/letsencrypt/renewal-hooks/deploy/ops-terminal-standalone.sh \
    && note "certbot renewal deploy hook removed (standalone)"
fi

# --- 1b-standalone. CP13: only-this-project LE certificate + webroot ---------
if [ "$TOPOLOGY" = "standalone" ] && [ "$SANDBOX" != "1" ]; then
  DOMAIN="$(sed -n 's/^OPS_DOMAIN=//p' "$ETC_DIR/env" 2>/dev/null | head -n1)"
  DOMAIN="${DOMAIN:-ops.hanaso.ir}"
  if [ -d "/etc/letsencrypt/live/$DOMAIN" ] || [ -f "/etc/letsencrypt/renewal/$DOMAIN.conf" ]; then
    if command -v certbot >/dev/null 2>&1; then
      note "removing THIS panel's Let's Encrypt material for $DOMAIN (certbot delete)"
      certbot delete --cert-name "$DOMAIN" --non-interactive 2>/dev/null \
        && note "LE certificate/renewal config deleted" \
        || warn "certbot delete failed — remove /etc/letsencrypt for $DOMAIN manually"
    else
      warn "certbot not installed — LE material for $DOMAIN left in place"
    fi
  fi
  if [ -d "$WEBROOT_DIR" ]; then
    rm -rf "$WEBROOT_DIR" && note "standalone ACME webroot removed: $WEBROOT_DIR"
  fi
fi

# --- 2. kill the detached tmux server (owned by this panel only) -------------
if command -v tmux >/dev/null 2>&1; then
  if TMUX_TMPDIR="$VARTMP_DIR" tmux kill-server 2>/dev/null; then
    note "tmux server for session 'ops' terminated"
  fi
fi
[ -d "$VARTMP_DIR" ] && rm -rf "$VARTMP_DIR"

# --- 3. remove nginx vhost (nginx-direct topology only) ----------------------
if [ "$SANDBOX" != "1" ]; then
  if [ "$TOPOLOGY" = "nginx-direct" ] \
     && { [ -e "$VHOST_FILE" ] || [ -L "/etc/nginx/sites-enabled/ops-terminal.conf" ]; }; then
    note "removing nginx vhost: $VHOST_FILE"
    [ -e "$VHOST_FILE" ] && cp -a "$VHOST_FILE" "/tmp/ops-terminal-vhost.last.bak"
    rm -f "$VHOST_FILE" "/etc/nginx/sites-enabled/ops-terminal.conf"
    if nginx -t 2>/dev/null; then
      note "nginx configuration valid — reloading (not restarting)"
      systemctl reload nginx
      systemctl is-active nginx >/dev/null || die "nginx not active after reload!"
      note "nginx reloaded; all other vhosts remain online"
    else
      die "nginx -t failed after vhost removal — restoring backup"
    fi
  else
    note "no nginx vhost found (loopback-only install or HAProxy topology)"
  fi
else
  [ -e "$VHOST_FILE" ] && rm -f "$VHOST_FILE"
fi

# --- 4. remove unit files + tools ---------------------------------------------
if [ "$SANDBOX" != "1" ]; then
  rm -f /etc/systemd/system/ops-terminal.service \
        /etc/systemd/system/ops-terminal-gateway.service \
        /etc/systemd/system/ops-terminal-nginx.service \
        /etc/systemd/system/ops-terminal-front.service \
        /etc/systemd/system/ops-terminal-tls-renew.service \
        /etc/systemd/system/ops-terminal-tls-renew.timer \
        /etc/logrotate.d/ops-terminal \
        /usr/local/bin/ops-terminal-passwd
  systemctl daemon-reload 2>/dev/null || true
  if id ops-gw >/dev/null 2>&1; then
    userdel ops-gw 2>/dev/null && note "system user ops-gw removed" || note "ops-gw still has processes/files elsewhere — not removed"
  fi
  if [ "$PURGE_PACKAGES" = "1" ]; then
    note "--purge-packages: apt-purging the distro nginx + certbot packages (standalone install brought them in)"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y nginx nginx-common nginx-core certbot 2>/dev/null \
      && note "packages purged" || warn "apt purge reported problems — check package state"
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || true
  else
    note "distro packages (nginx, certbot) kept — pass --purge-packages to remove them"
  fi
fi

# --- 5. remove files ------------------------------------------------------------
note "removing $OPT_DIR"
rm -rf "$OPT_DIR"
note "removing $ETC_DIR (credentials + internal/front nginx config included)"
rm -rf "$ETC_DIR"
rm -rf "$VARLIB_DIR" "$RUN_DIR"
if [ "$PURGE" = "1" ]; then
  note "--purge: removing logs + state + backups"
  rm -rf "$VARLOG_DIR" "$BACKUP_BASE"
else
  note "kept: $VARLOG_DIR (logs) and $BACKUP_BASE (backups) — use --purge to remove"
fi

printf '\n[uninstall] DONE — panel fully removed; shared services untouched.\n'
[ "$SANDBOX" != "1" ] && [ "$TOPOLOGY" = "nginx-direct" ] \
  && note "verify: nginx -t && systemctl status nginx"
exit 0
