#!/usr/bin/env bash
# ==========================================================================
# HANASO OPS Web Terminal — Health Check
# Verifies: services up (systemd or pidfiles), gateway /health, ttyd page,
# loopback-only listening, optional external HTTPS check.
#
# Usage: health-check.sh [--conf /etc/ops-terminal/env] [--url https://...] [--sandbox]
# Exit:  0 healthy / 1 problems
# ==========================================================================
set -u
CONF="/etc/ops-terminal/env"; EXT_URL=""; SANDBOX=0
while [ $# -gt 0 ]; do
  case "$1" in
    --conf) CONF="$2"; shift 2 ;;
    --url)  EXT_URL="$2"; shift 2 ;;
    --sandbox) SANDBOX=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
FAIL=0
say() { printf '  [%s] %s\n' "$1" "$2"; }
chk() { if [ "$1" = "OK" ]; then say OK "$2"; else say FAIL "$2"; FAIL=1; fi; }

get() { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -1; }
GW_PORT="$(get GATEWAY_PORT)"; GW_PORT="${GW_PORT:-7682}"
TD_PORT="$(get TTYD_PORT)";    TD_PORT="${TD_PORT:-7681}"
TOPOLOGY="$(get OPS_TOPOLOGY)"; TOPOLOGY="${TOPOLOGY:-nginx-direct}"
PANEL_PORT="$(get PANEL_LISTEN_PORT)"; PANEL_PORT="${PANEL_PORT:-7680}"

echo "== HANASO OPS Web Terminal — health check (topology: $TOPOLOGY) =="

if [ "$SANDBOX" = "0" ] && command -v systemctl >/dev/null 2>&1; then
  for u in ops-terminal-gateway ops-terminal; do
    if systemctl is-active --quiet "$u" 2>/dev/null; then chk OK "systemd: $u active"
    elif systemctl list-unit-files "$u.service" >/dev/null 2>&1 && systemctl cat "$u" >/dev/null 2>&1; then chk FAIL "systemd: $u NOT active"
    else say INFO "systemd unit $u not installed (sandbox?)"; fi
  done
  if [ "$TOPOLOGY" != "nginx-direct" ]; then
    if systemctl is-active --quiet ops-terminal-nginx 2>/dev/null; then chk OK "systemd: ops-terminal-nginx active"
    elif systemctl list-unit-files ops-terminal-nginx.service >/dev/null 2>&1; then chk FAIL "systemd: ops-terminal-nginx NOT active"
    else say INFO "ops-terminal-nginx unit not installed"; fi
  fi
  if [ "$TOPOLOGY" = "standalone" ]; then
    # CP13: the panel's OWN edge nginx is a required unit here
    if systemctl is-active --quiet ops-terminal-front 2>/dev/null; then chk OK "systemd: ops-terminal-front (edge :80/:443) active"
    elif systemctl list-unit-files ops-terminal-front.service >/dev/null 2>&1; then chk FAIL "systemd: ops-terminal-front NOT active"
    else say INFO "ops-terminal-front unit not installed"; fi
    if systemctl is-enabled nginx.service >/dev/null 2>&1; then
      chk FAIL "distro nginx.service is enabled (standalone: the panel's own edge must own :80/:443)"
    else say OK "distro nginx.service not enabled (panel edge owns :80/:443)"; fi
  elif [ "$TOPOLOGY" != "nginx-direct" ]; then
    # shared edge (owned by the platform, not by this panel) — informational
    if systemctl is-active --quiet haproxy 2>/dev/null; then say INFO "systemd: haproxy active"
    else say INFO "systemd: haproxy not active (panel is unreachable externally — check the shared edge)"; fi
  fi
fi

if curl -sf -m 5 "http://127.0.0.1:$GW_PORT/health" >/dev/null 2>&1; then
  chk OK "gateway /health on 127.0.0.1:$GW_PORT"
else chk FAIL "gateway /health on 127.0.0.1:$GW_PORT"; fi

if curl -sf -m 5 "http://127.0.0.1:$TD_PORT/" -o /dev/null; then
  chk OK "ttyd page on 127.0.0.1:$TD_PORT"
else chk FAIL "ttyd page on 127.0.0.1:$TD_PORT"; fi

if [ "$TOPOLOGY" != "nginx-direct" ]; then
  if curl -sf -m 5 "http://127.0.0.1:$PANEL_PORT/health" >/dev/null 2>&1; then
    chk OK "internal nginx /health on 127.0.0.1:$PANEL_PORT"
  else chk FAIL "internal nginx /health on 127.0.0.1:$PANEL_PORT"; fi
fi

if [ "$TOPOLOGY" = "standalone" ]; then
  # CP13: the dedicated edge must own :80 AND :443 on this fresh server
  for p in 80 443; do
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":$p\$"; then
      chk OK "edge port $p listening (ops-terminal-front)"
    else chk FAIL "edge port $p NOT listening"
    fi
  done
fi

# loopback binding check (never accept external binding of the raw services)
LB_PORTS="$GW_PORT $TD_PORT"
[ "$TOPOLOGY" != "nginx-direct" ] && LB_PORTS="$LB_PORTS $PANEL_PORT"
for p in $LB_PORTS; do
  if ss -tln 2>/dev/null | awk '{print $4}' | grep -E "127\.0\.0\.1:$p\$|^\[::1\]:$p\$" >/dev/null; then
    chk OK "port $p listens on loopback only"
  elif ss -tln 2>/dev/null | awk '{print $4}' | grep -E ":$p\$" >/dev/null; then
    chk FAIL "port $p listens on a NON-loopback address!"
  else
    chk FAIL "port $p not listening"
  fi
done

if [ -n "$EXT_URL" ]; then
  CODE="$(curl -sk -m 8 -o /dev/null -w '%{http_code}' "$EXT_URL/login" 2>/dev/null || echo 000)"
  case "$CODE" in
    200|302|401|423) chk OK "external login endpoint answers (HTTP $CODE)" ;;
    *) chk FAIL "external login endpoint: HTTP $CODE" ;;
  esac
fi

echo "----------------------------------------------"
if [ "$FAIL" = "0" ]; then echo " RESULT: HEALTHY"; exit 0; else echo " RESULT: PROBLEMS FOUND"; exit 1; fi
