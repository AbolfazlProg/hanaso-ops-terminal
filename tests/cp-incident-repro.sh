#!/usr/bin/env bash
# ==========================================================================
# CP v1.3.1 — reproduce the PRODUCTION incident inside the clean VM:
#   E: Unable to locate package nginx
#   E: Unable to locate package certbot
#   [install][FATAL] apt-get install failed for: nginx certbot
#
# Two candidate mechanisms are tested empirically (mission section 1 forbids
# concluding "nginx is filtered" from the message alone):
#   A) empty/no active apt sources  -> apt-get update is a NO-OP (rc 0)
#   B) unreachable default mirror   -> apt-get update behavior + rc
# The cp13 systemctl shim is NOT needed here (no installer run yet) — run
# through tests/cp13-vm-run.sh.
# ==========================================================================
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EV=/mnt/shared/evidence
LOG="$EV/cp-incident-repro.log"
: > "$LOG"

log() { echo "$@" | tee -a "$LOG"; }

log "=== incident reproduction — $(date -u +%FT%TZ) ==="
log "VM: $(. /etc/os-release && echo "$PRETTY_NAME ($VERSION_CODENAME)") / $(uname -m) / uid=$(id -u)"
log "pre-state index files: $(ls /var/lib/apt/lists/ 2>/dev/null | grep -c Packages) Packages files"
log ""

cp -a /etc/apt/sources.list /root/sources.list.orig

# ---- scenario A: provider image with NO active sources -------------------
log "--- A) sources.list EMPTY (no active sources) ---"
: > /etc/apt/sources.list
rm -rf /var/lib/apt/lists/*
mkdir -p /var/lib/apt/lists/partial
apt-get update > /tmp/a-update.log 2>&1; rc=$?
log "apt-get update rc=$rc"
tail -2 /tmp/a-update.log | sed 's/^/  /' >> "$LOG"
apt-get install -y nginx certbot > /tmp/a-install.log 2>&1; rc=$?
log "apt-get install nginx certbot rc=$rc"
grep -E "^(E:|W:)" /tmp/a-install.log | sed 's/^/  /' >> "$LOG"

# ---- scenario B: unreachable default mirror -------------------------------
log ""
log "--- B) sources.list = unreachable archive.ubuntu.com (netns has no egress) ---"
printf 'deb http://archive.ubuntu.com/ubuntu noble main universe\n' > /etc/apt/sources.list
timeout 60 apt-get update > /tmp/b-update.log 2>&1; rc=$?
log "apt-get update rc=$rc (timeout 60s)"
grep -E "^(Err|E:|W:)" /tmp/b-update.log | head -4 | sed 's/^/  /' >> "$LOG"
timeout 30 apt-get install -y nginx certbot > /tmp/b-install.log 2>&1; rc=$?
log "apt-get install nginx certbot rc=$rc"
grep -E "^(E:|W:)" /tmp/b-install.log | head -4 | sed 's/^/  /' >> "$LOG"

# ---- restore ---------------------------------------------------------------
cp -a /root/sources.list.orig /etc/apt/sources.list
apt-get update > /tmp/r-update.log 2>&1; rc=$?
log ""
log "restored original flat-mirror sources: apt-get update rc=$rc"
apt-cache policy nginx 2>/dev/null | sed -n '2,3p' | sed 's/^/  /' >> "$LOG"
log "=== REPRO_DONE ==="
