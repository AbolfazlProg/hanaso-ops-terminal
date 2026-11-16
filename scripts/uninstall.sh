#!/usr/bin/env bash
# ==========================================================================
# HANASO OPS Web Terminal — Uninstaller
# Removes ONLY files/services owned by this panel. Never touches other
# vhosts, services, containers, volumes or the shared nginx config beyond
# its own vhost file. A RELOAD (never restart) of nginx is performed after
# syntax validation.
#
# Usage:  uninstall.sh [--yes] [--sandbox] [--purge]
#   --yes     skip confirmation
#   --sandbox remove a --sandbox test installation
#   --purge   also remove logs, state and backups (default: kept)
# ==========================================================================
set -Eeuo pipefail
die()  { printf '[uninstall][FATAL] %s\n' "$*" >&2; exit 1; }
note() { printf '[uninstall] %s\n' "$*"; }

ASSUME_YES=0; SANDBOX=0; PURGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) ASSUME_YES=1; shift ;;
    --sandbox) SANDBOX=1; shift ;;
    --purge) PURGE=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [ "$SANDBOX" = "1" ]; then
  SB_ROOT="${OPS_SANDBOX_ROOT:-$HOME/ops-sandbox}"
  OPT_DIR="$SB_ROOT/opt/ops-terminal";  ETC_DIR="$SB_ROOT/etc/ops-terminal"
  VARLIB_DIR="$SB_ROOT/var/lib/ops-terminal"; VARLOG_DIR="$SB_ROOT/var/log/ops-terminal"
  VARTMP_DIR="$SB_ROOT/var/tmp/ops-terminal"; RUN_DIR="$SB_ROOT/run"
  NGX_DIR="$SB_ROOT/nginx"
  VHOST_FILE="$NGX_DIR/ops-terminal.conf"
  NGINX_BIN="${OPS_SANDBOX_NGINX_BIN:-}"
  BACKUP_BASE="$SB_ROOT/backups"
else
  [ "$(id -u)" = "0" ] || die "run as root"
  OPT_DIR="/opt/ops-terminal";  ETC_DIR="/etc/ops-terminal"
  VARLIB_DIR="/var/lib/ops-terminal"; VARLOG_DIR="/var/log/ops-terminal"
  VARTMP_DIR="/var/tmp/ops-terminal"; RUN_DIR="/run/ops-terminal"
  VHOST_FILE="/etc/nginx/sites-available/ops-terminal.conf"
  [ -e "$VHOST_FILE" ] || VHOST_FILE="/etc/nginx/conf.d/ops-terminal.conf"
  BACKUP_BASE="/var/backups/ops-terminal"
fi

[ -e "$ETC_DIR/env" ] || [ -e "$OPT_DIR" ] || die "no installation found at $ETC_DIR / $OPT_DIR"

if [ "$ASSUME_YES" != "1" ]; then
  printf 'Remove HANASO OPS Web Terminal completely?\n'
  printf '  (services, files, nginx vhost — other vhosts/services untouched)\n'
  printf '  logs/state/backups are KEPT unless --purge\n'
  printf 'Type YES to continue: '; read -r ANS; [ "$ANS" = "YES" ] || die "aborted"
fi

# --- 1. stop services -------------------------------------------------------
if [ "$SANDBOX" = "1" ]; then
  for f in gateway ttyd; do
    if [ -f "$RUN_DIR/$f.pid" ]; then
      note "stopping sandbox $f (pid $(cat "$RUN_DIR/$f.pid"))"
      kill "$(cat "$RUN_DIR/$f.pid")" 2>/dev/null || true
      rm -f "$RUN_DIR/$f.pid"
    fi
  done
  if [ -f "$RUN_DIR/nginx.pid" ] && [ -n "$NGINX_BIN" ]; then
    note "stopping sandbox nginx harness"
    "$NGINX_BIN" -c "$NGX_DIR/nginx.conf" -s stop 2>/dev/null || kill "$(cat "$RUN_DIR/nginx.pid")" 2>/dev/null || true
  fi
else
  note "stopping + disabling systemd services"
  systemctl disable --now ops-terminal.service ops-terminal-gateway.service 2>/dev/null || true
fi

# --- 2. kill the detached tmux server (owned by this panel only) -------------
if command -v tmux >/dev/null 2>&1; then
  if TMUX_TMPDIR="$VARTMP_DIR" tmux kill-server 2>/dev/null; then
    note "tmux server for session 'ops' terminated"
  fi
fi
[ -d "$VARTMP_DIR" ] && rm -rf "$VARTMP_DIR"

# --- 3. remove nginx vhost (with syntax test + reload) -----------------------
if [ "$SANDBOX" != "1" ]; then
  if [ -e "$VHOST_FILE" ] || [ -L "/etc/nginx/sites-enabled/ops-terminal.conf" ]; then
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
    note "no nginx vhost found (loopback-only install)"
  fi
else
  [ -e "$VHOST_FILE" ] && rm -f "$VHOST_FILE"
fi

# --- 4. remove unit files + tools ---------------------------------------------
if [ "$SANDBOX" != "1" ]; then
  rm -f /etc/systemd/system/ops-terminal.service \
        /etc/systemd/system/ops-terminal-gateway.service \
        /etc/logrotate.d/ops-terminal \
        /usr/local/bin/ops-terminal-passwd
  systemctl daemon-reload 2>/dev/null || true
  if id ops-gw >/dev/null 2>&1; then
    userdel ops-gw 2>/dev/null && note "system user ops-gw removed" || note "ops-gw still has processes/files elsewhere — not removed"
  fi
fi

# --- 5. remove files ------------------------------------------------------------
note "removing $OPT_DIR"
rm -rf "$OPT_DIR"
note "removing $ETC_DIR (credentials included)"
rm -rf "$ETC_DIR"
rm -rf "$VARLIB_DIR" "$RUN_DIR"
if [ "$PURGE" = "1" ]; then
  note "--purge: removing logs + state + backups"
  rm -rf "$VARLOG_DIR" "$BACKUP_BASE"
else
  note "kept: $VARLOG_DIR (logs) and $BACKUP_BASE (backups) — use --purge to remove"
fi

printf '\n[uninstall] DONE — panel fully removed; shared services untouched.\n'
[ "$SANDBOX" != "1" ] && note "verify: nginx -t && systemctl status nginx"
exit 0
