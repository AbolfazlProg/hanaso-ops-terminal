#!/usr/bin/env bash
# ==========================================================================
# HANASO OPS Web Terminal — HAProxy topology sandbox battery
# Replicates the production incident topology on the unprivileged sandbox:
#   * HAProxy terminates TLS on a shared edge bind (crt FILE style) and
#     serves the SHARED site (kotodama.ir) — exactly like the real VPS
#   * the panel (ops.hanaso.ir) is routed via a MANAGED SNI/Host ACL to the
#     panel's internal loopback nginx (127.0.0.1:7680)
#   * certificate integration uses the REVERSIBLE crt -> crt-list conversion
#
# Steps: harness build -> ops-env/ops-haproxy unit tests -> install -> e2e
#        (curl + websocket + real browser) -> shared-site isolation ->
#        HSTS/XFF-spoof checks -> idempotent reinstall -> FORCED ROLLBACK
#        (e2e failure AFTER haproxy wiring) -> revert assertions -> clean
#        reinstall -> uninstall -> revert assertions -> final reinstall.
#
# Usage: bash tests/haproxy-battery.sh
# Env  : OPS_SANDBOX_ROOT (default /home/z/ops-sandbox)
# Exit : number of failed steps
# ==========================================================================
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SB="${OPS_SANDBOX_ROOT:-/home/z/ops-sandbox}"
SBROOT=/home/z/sandbox-root
TEST=/home/z/ops-sandbox-test
PY=/home/z/.venv/bin/python3
HAP="$SBROOT/usr/sbin/haproxy"
NGX="$SBROOT/usr/sbin/nginx"
LIBDIR="$SBROOT/usr/lib/x86_64-linux-gnu"
export LD_LIBRARY_PATH="$LIBDIR"

EDGE=8443; HTTP80=8080; SHARED_PORT=9090
DOMAIN=ops.hanaso.ir; SHARED_DOMAIN=kotodama.ir
HCFG="$SB/etc/haproxy/haproxy.cfg"
HPID="$SB/haproxy-test/haproxy.pid"          # OUTSIDE the panel's run dir (uninstall removes $SB/run)
CRTLIST="$SB/etc/haproxy/ops-terminal.crtlist"
PEM="$SB/etc/haproxy/certs/ops-terminal.pem"
HAP_LOG="$SB/var/log/haproxy.log"
PWFILE="$TEST/pw-haproxy-current"
GW="$SB/opt/ops-terminal/gateway/gateway.py"

export OPS_TEST_BASE="https://$DOMAIN:$EDGE"
export OPS_TEST_IP="127.0.0.1"
export OPS_TEST_USER="ops-admin"
export OPS_TERMINAL_CONF="$SB/etc/ops-terminal/env"

FAILS=0
step() { echo; echo "############################################"; echo "### $*"; echo "############################################"; }
ok()  { echo "  [PASS] $*"; }
bad() { echo "  [FAIL] $*"; FAILS=$((FAILS+1)); }
rc_run() { "$@"; local r=$?; [ "$r" -eq 0 ] && ok "$1 ... rc=0" || bad "$1 ... rc=$r"; return 0; }
chk_eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', want '$3')"; }
chk_has()  { grep -qF -- "$3" "$2" 2>/dev/null && ok "$1" || bad "$1 (missing '$3' in $2)"; }
chk_not()  { grep -qF -- "$3" "$2" 2>/dev/null && bad "$1 (found '$3' in $2)" || ok "$1"; }
chk_rc()   { [ "$1" -eq 0 ] && ok "$2" || bad "$2"; }

# ---------------------------------------------------------------- helpers --
build_harness() {
  mkdir -p "$SB/etc/haproxy/certs" "$SB/haproxy-test" "$SB/var/log" "$TEST"
  cp "$TEST/hanaso.pem" "$SB/etc/haproxy/certs/hanaso.pem"
  cat > "$HCFG" <<EOF
# sandbox harness — mirrors the REAL VPS: HAProxy owns the public TLS edge
# and serves the shared site (kotodama.ir) from a crt-FILE bind.
global
    maxconn 512
    stats socket $SB/haproxy-test/admin.sock mode 600 level admin

defaults
    mode http
    option httplog
    timeout connect 5s
    timeout client  30s
    timeout server  30s

frontend f_shared_443
    bind *:$EDGE ssl crt $SB/etc/haproxy/certs/hanaso.pem
    acl SHARED_KT hdr(host) -i $SHARED_DOMAIN
    acl SHARED_HN hdr(host) -i hanaso.ir
    use_backend b_shared if SHARED_KT || SHARED_HN
    default_backend b_shared

frontend f_shared_80
    bind *:$HTTP80
    default_backend b_shared

backend b_shared
    server shared 127.0.0.1:$SHARED_PORT check inter 2s fall 3 rise 2
EOF
  cat > "$TEST/shared-server.py" <<'PYEOF'
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"SHARED-SITE-OK"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", 9090), H).serve_forever()
PYEOF
}

start_harness() {
  pkill -f "$TEST/shared-server.py" 2>/dev/null || true
  pkill -f "$HCFG" 2>/dev/null || true
  sleep 0.4
  nohup "$PY" "$TEST/shared-server.py" > "$TEST/shared-server.log" 2>&1 &
  echo $! > "$TEST/shared-server.pid"
  nohup "$HAP" -W -db -f "$HCFG" -p "$HPID" > "$HAP_LOG" 2>&1 &
  sleep 1.2
  MASTER_BEFORE="$(master_pid)"
}

stop_harness() {
  [ -f "$TEST/shared-server.pid" ] && kill "$(cat "$TEST/shared-server.pid")" 2>/dev/null
  [ -f "$HPID" ] && kill "$(head -n1 "$HPID")" 2>/dev/null
  pkill -f "$HCFG" 2>/dev/null || true
  sleep 0.4
}

edge_alive() { ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":$EDGE$"; }
master_pid() { [ -r "$HPID" ] && head -n1 "$HPID" || echo ""; }

install_panel() { # logfile extra-args...
  local log="$1"; shift
  bash "$REPO/scripts/install.sh" --sandbox --sandbox-topology haproxy --yes \
    --haproxy-cfg "$HCFG" --haproxy-bin "$HAP" --haproxy-pidfile "$HPID" \
    --https-port "$EDGE" --http-port "$HTTP80" \
    --tls-cert "$TEST/ops-panel.fullchain.pem" --tls-key "$TEST/ops-panel.key" \
    --nginx-bin "$NGX" --mime-types "$SBROOT/etc/nginx/mime.types" \
    --tmux-bin "$SBROOT/usr/bin/tmux" --tmux-ld-path "$LIBDIR" \
    --python-bin "$PY" "$@" > "$log" 2>&1
  local r=$?
  [ "$r" -ne 0 ] && { echo "  --- install tail ($log) ---"; tail -n 25 "$log" | sed 's/^/    /'; }
  return $r
}

# =============================================================== main ======
step "-1. clean room (sweep leftovers from previous battery runs)"
# a previous battery (nginx-direct or cp12) leaves panel services, its own
# harness haproxy and shared-site stubs on these ports — this battery owns
# the sandbox root and starts from scratch.
pkill -f "cp11-supervisor.py" 2>/dev/null || true
pkill -f "$SB/opt/ops-terminal" 2>/dev/null || true
pkill -f "$SB/etc/ops-terminal" 2>/dev/null || true
pkill -f "$SB/nginx/nginx.conf" 2>/dev/null || true
pkill -f "new -A -s ops" 2>/dev/null || true
pkill -f "/home/z/ops-sandbox" 2>/dev/null || true
pkill -f "shared-server" 2>/dev/null || true
sleep 1
rm -rf "$SB"

step "0. harness: shared site + HAProxy edge (baseline, NO panel)"
build_harness
start_harness
chk_rc $? "harness started"
rc_run "$HAP" -c -q -f "$HCFG"
if edge_alive; then ok "edge :$EDGE listening (haproxy)"; else bad "edge :$EDGE NOT listening"; fi
# HAProxy marks the backend UP only after rise-2 health checks (~4s) — wait for it
SHARED_OUT=""; for _ in 1 2 3 4 5 6 7 8 9 10; do
  SHARED_OUT="$(curl -sk --resolve "$SHARED_DOMAIN:$EDGE:127.0.0.1" "https://$SHARED_DOMAIN:$EDGE/" 2>/dev/null)"
  [ "$SHARED_OUT" = "SHARED-SITE-OK" ] && break
  sleep 1
done
chk_eq "shared site answers through the edge (baseline)" "$SHARED_OUT" "SHARED-SITE-OK"
kill -0 "$(cat "$TEST/shared-server.pid")" 2>/dev/null && ok "shared marker server alive" \
  || { bad "shared marker server dead"; cat "$TEST/shared-server.log"; }
chk_eq "pidfile holds exactly the master pid" "$(wc -l < "$HPID" | tr -d ' ')" "1"
# MASTER_BEFORE is refreshed inside start_harness (each harness restart makes the old pid stale)

step "1. ops-env.sh — strict env-file serialization (incident 2026-11-16 regression)"
TDIR="$(mktemp -d)"
(
  set -u
  . "$REPO/scripts/ops-env.sh"
  OPS_ENV_OUT="$TDIR/safe.env" ops_env_kv PREFLIGHT_HOST_IPS "87.107.129.210 172.18.0.1" || exit 10
  OPS_ENV_OUT="$TDIR/safe.env" ops_env_kv PREFLIGHT_DOMAIN "$DOMAIN" || exit 11
  grep -qF "PREFLIGHT_HOST_IPS='87.107.129.210 172.18.0.1'" "$TDIR/safe.env" || exit 12
  ops_env_read "$TDIR/safe.env" || exit 13
  [ "$PREFLIGHT_HOST_IPS" = "87.107.129.210 172.18.0.1" ] || exit 14
  # legacy UNQUOTED file (the exact incident content): the STRICT reader must
  # parse it WITHOUT executing anything — the full space-containing value
  # lands in the variable as ONE string (the incident bug was sourcing it,
  # which made bash execute the second word)
  printf 'PREFLIGHT_HOST_IPS=87.107.129.210 172.18.0.1\n' > "$TDIR/legacy.env"
  ops_env_read "$TDIR/legacy.env" || exit 15
  [ "$PREFLIGHT_HOST_IPS" = "87.107.129.210 172.18.0.1" ] || exit 151
  # sourcing the LEGACY file executes the second word (proves the bug class)
  bash -c "source '$TDIR/legacy.env'" >/dev/null 2>&1 && exit 16
  # safe file is INERT when sourced (quoted assignment only)
  bash -c "set -u; source '$TDIR/safe.env'; [ \"\$PREFLIGHT_HOST_IPS\" = '87.107.129.210 172.18.0.1' ]" || exit 17
  # unknown key must fail closed
  printf "NOT_A_REAL_KEY='x'\n" > "$TDIR/evil.env"
  ops_env_read "$TDIR/evil.env" 2>/dev/null && exit 18
  exit 0
)
chk_rc $? "ops-env write/read roundtrip + legacy rejection + inert-sourcing"
rm -rf "$TDIR"

step "2. ops-haproxy.sh — config analysis + surgical edit library"
T2=$(mktemp -d)
(
  set -u
  . "$REPO/scripts/ops-haproxy.sh"
  SEC="$(ha_find_bind_section "$HCFG" "$EDGE")" || exit 20
  NAME="${SEC%%|*}"; [ "$NAME" = "f_shared_443" ] || exit 21
  BIND="${SEC##*|}"
  printf '%s' "$BIND" | grep -qF "ssl crt $SB/etc/haproxy/certs/hanaso.pem" || exit 22
  ha_bind_ssl "$BIND" || exit 23
  CRT="$(ha_bind_crt "$BIND")"
  [ "$CRT" = "crt|$SB/etc/haproxy/certs/hanaso.pem" ] || exit 24
  [ "$(ha_version_major "$HAP")" -ge 3 ] || exit 25
  # surgical removal: only OUR blocks disappear
  cp "$HCFG" "$T2/copy.cfg"
  printf '# BEGIN ops-terminal (managed)\nacl X hdr(host) -i x\n# END ops-terminal\n' >> "$T2/copy.cfg"
  N="$(ha_remove_managed "$T2/copy.cfg")"
  [ "$N" = "1" ] || exit 26
  grep -q 'BEGIN ops-terminal' "$T2/copy.cfg" && exit 27
  grep -q 'frontend f_shared_443' "$T2/copy.cfg" || exit 28
  # insertion right after the frontend header
  printf '# BLOCKLINE\n' > "$T2/blk"
  ha_insert_after_line "$T2/copy.cfg" 4 "$T2/blk"
  [ "$(sed -n '5p' "$T2/copy.cfg")" = "# BLOCKLINE" ] || exit 29
  exit 0
)
chk_rc $? "ops-haproxy find/ssl/crt/version/remove/insert"
rm -rf "$T2"

step "3. INSTALL (sandbox, haproxy-front, crt-FILE conversion path)"
rm -rf "$SB"                      # clean room
build_harness; start_harness
install_panel "$TEST/install-1.log"
chk_rc $? "install.sh exited 0 (includes its own e2e: login->websocket->shell)"
chk_has "install e2e PASSED marker" "$TEST/install-1.log" "end-to-end verification PASSED"
PW="$(sed -n 's/^ PASSWORD    : //p' "$TEST/install-1.log" | head -n1)"
[ -n "$PW" ] && ok "one-time password captured for battery" || bad "password not found in install log"
printf '%s' "$PW" > "$PWFILE"
export OPS_TEST_PW="$PW"

step "4. haproxy.cfg managed-state assertions (post-install)"
BLOCKS="$(grep -c '^# BEGIN ops-terminal' "$HCFG")"
chk_eq "exactly 2 managed blocks in shared cfg" "$BLOCKS" "2"
chk_has "bind converted to managed crt-list" "$HCFG" "crt-list $CRTLIST"
chk_not "original shared crt NO LONGER on the bind" "$HCFG" "ssl crt $SB/etc/haproxy/certs/hanaso.pem"
chk_eq "crtlist has the original cert first" "$(head -n1 "$CRTLIST")" "$SB/etc/haproxy/certs/hanaso.pem"
chk_eq "crtlist has the panel PEM second" "$(tail -n1 "$CRTLIST")" "$PEM"
[ -f "$PEM" ] && [ "$(stat -c %a "$PEM")" = "600" ] && ok "panel PEM present, mode 0600" || bad "panel PEM missing or wrong mode"
rc_run "$HAP" -c -q -f "$HCFG"
chk_eq "HAProxy master pid UNCHANGED (reload, not restart)" "$(master_pid)" "$MASTER_BEFORE"
if edge_alive; then ok "edge :$EDGE still listening"; else bad "edge :$EDGE DOWN"; fi

step "5. routing through the shared edge"
SHARED_OUT="$(curl -sk --resolve "$SHARED_DOMAIN:$EDGE:127.0.0.1" "https://$SHARED_DOMAIN:$EDGE/")"
chk_eq "shared site UNAFFECTED (kotodama.ir -> shared backend)" "$SHARED_OUT" "SHARED-SITE-OK"
HEALTH="$(curl -sk --resolve "$DOMAIN:$EDGE:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$DOMAIN:$EDGE/health")"
chk_eq "panel /health via HAProxy -> internal nginx -> gateway" "$HEALTH" "200"
LOGIN="$(curl -sk --resolve "$DOMAIN:$EDGE:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$DOMAIN:$EDGE/login")"
chk_eq "panel /login via HAProxy" "$LOGIN" "200"
HSTS="$(curl -skI --resolve "$DOMAIN:$EDGE:127.0.0.1" "https://$DOMAIN:$EDGE/login" | grep -ci 'strict-transport-security')"
chk_eq "HSTS header added by managed backend block" "$HSTS" "1"
for p in 7680 7681 7682; do
  if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "127\.0\.0\.1:$p$"; then ok "panel port $p loopback-only"
  else bad "panel port $p binding unexpected"; fi
done

step "6. XFF spoof-proofing + real failed-login logging through the managed backend"
CSRF="$(curl -sk --resolve "$DOMAIN:$EDGE:127.0.0.1" -c "$TEST/cookies6.txt" "https://$DOMAIN:$EDGE/login" \
        | grep -oP 'name="csrf" value="\K[^"]+' | head -n1)"
[ -n "$CSRF" ] && ok "csrf token fetched from login page" || bad "csrf missing on login page"
curl -sk --resolve "$DOMAIN:$EDGE:127.0.0.1" -b "$TEST/cookies6.txt" -o /dev/null \
     -H "X-Forwarded-For: 6.6.6.6" -X POST "https://$DOMAIN:$EDGE/login" \
     --data "csrf=$CSRF&username=$OPS_TEST_USER&password=WrongPassword$RANDOM" 2>/dev/null
sleep 0.6
if tail -n 20 "$SB/var/log/ops-terminal/gateway.log" 2>/dev/null | grep -q '6\.6\.6\.6'; then
  bad "spoofed XFF leaked into gateway log"
else ok "spoofed XFF deleted by HAProxy (never reaches gateway)"; fi
tail -n 20 "$SB/var/log/ops-terminal/gateway.log" 2>/dev/null | grep -q 'LOGIN_FAIL.*ip=127\.0\.0\.1' \
  && ok "real wrong-password attempt logged as LOGIN_FAIL with the true client IP" \
  || bad "no LOGIN_FAIL event for a real wrong-password attempt"
rm -f "$TEST/cookies6.txt"

tmux_reset() { TMUX_TMPDIR="$SB/var/tmp/ops-terminal" "$SBROOT/usr/bin/tmux" kill-server 2>/dev/null || true; sleep 0.5; }

step "7. standalone e2e (fresh login + websocket + shell + uid proof)"
tmux_reset
printf '%s' "$PW" | "$PY" "$REPO/scripts/e2e-test.py" \
  --base "$OPS_TEST_BASE" --connect 127.0.0.1 \
  --username "$OPS_TEST_USER" --password-stdin \
  --insecure-allow --expect-uid "$(id -u)" > "$TEST/e2e-haproxy.log" 2>&1
chk_rc $? "e2e-test.py full chain (through HAProxy TLS+SNI)"

step "8. real browser (Playwright + Chromium) through HAProxy"
tmux_reset
[ -d /home/z/.npm-global/lib/node_modules ] && \
  NODE_PATH=/home/z/.npm-global/lib/node_modules node "$REPO/tests/browser-test.js" \
    --url "$OPS_TEST_BASE" --username "$OPS_TEST_USER" --password-file "$PWFILE" \
    --map-host "$DOMAIN" --expect-uid "$(id -u)" --out "$TEST/shots-haproxy" > "$TEST/browser-haproxy.log" 2>&1
chk_rc $? "browser: login -> terminal render -> typing -> output"

step "9. account flows (whoami/logout/change-password/invalidation)"
export OPS_TEST_OLD_PW="$PW"; export OPS_TEST_PW_FILE="$PWFILE"
"$PY" "$REPO/tests/test_account.py" > "$TEST/account-haproxy.log" 2>&1
chk_rc $? "account test battery"
export OPS_TEST_PW="$(cat "$PWFILE" 2>/dev/null || true)"
[ -n "${OPS_TEST_PW:-}" ] && ok "rotated password captured" || bad "no password after account test"

step "10. brute-force layers through HAProxy (429 cap + persistent lockout)"
"$PY" "$REPO/tests/test_bruteforce.py" > "$TEST/bruteforce-haproxy.log" 2>&1
chk_rc $? "brute-force battery"
sleep 2

step "11. health-check script (topology-aware)"
bash "$REPO/scripts/health-check.sh" --conf "$SB/etc/ops-terminal/env" --sandbox > "$TEST/health-haproxy.log" 2>&1
chk_rc $? "health-check.sh --sandbox (haproxy topology)"
grep -q "topology: haproxy-front" "$TEST/health-haproxy.log" && ok "health-check sees haproxy-front" || bad "health-check topology line wrong"

step "12. idempotent re-install (credentials preserved)"
install_panel "$TEST/install-2.log"
chk_rc $? "re-install exited 0"
chk_has "e2e skipped (credentials preserved)" "$TEST/install-2.log" "credentials were preserved"
chk_eq "still exactly 2 managed blocks (no duplicates)" "$(grep -c '^# BEGIN ops-terminal' "$HCFG")" "2"
chk_eq "single managed SNI acl definition (idempotent)" "$(grep -c 'acl OPS_TERM_SNI' "$HCFG")" "1"
chk_eq "SNI acl referenced by the managed use_backend" "$(grep -c 'OPS_TERM_SNI' "$HCFG")" "2"
HEALTH2="$(curl -sk --resolve "$DOMAIN:$EDGE:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$DOMAIN:$EDGE/health")"
chk_eq "panel healthy after reinstall" "$HEALTH2" "200"

step "13. FORCED ROLLBACK (e2e failure AFTER haproxy wiring) — incident path"
install_panel "$TEST/install-3.log" --reset-credentials --e2e-expect-uid 999999
RC3=$?
[ "$RC3" -ne 0 ] && ok "install exited non-zero on forced e2e failure (rc=$RC3)" || bad "install unexpectedly succeeded"
chk_has "rollback banner present" "$TEST/install-3.log" "[install][ROLLBACK]"
chk_has "e2e failure detected" "$TEST/install-3.log" "END-TO-END VERIFICATION FAILED"
chk_eq "managed blocks reverted to 0" "$(grep -c '^# BEGIN ops-terminal' "$HCFG")" "0"
chk_has "bind RESTORED to original crt file" "$HCFG" "ssl crt $SB/etc/haproxy/certs/hanaso.pem"
chk_not "no crt-list reference left" "$HCFG" "crt-list"
[ -e "$CRTLIST" ] && bad "crtlist file still present after rollback" || ok "crtlist removed"
[ -e "$PEM" ] && bad "panel PEM still present after rollback" || ok "panel PEM removed"
rc_run "$HAP" -c -q -f "$HCFG"
chk_eq "HAProxy master pid UNCHANGED through rollback" "$(master_pid)" "$MASTER_BEFORE"
SHARED3="$(curl -sk --resolve "$SHARED_DOMAIN:$EDGE:127.0.0.1" "https://$SHARED_DOMAIN:$EDGE/" 2>/dev/null)"
chk_eq "shared site still UNAFFECTED after rollback" "$SHARED3" "SHARED-SITE-OK"
sleep 1
BUSY=0
for p in 7680 7681 7682; do
  ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":$p$" && BUSY=$((BUSY+1))
done
chk_eq "panel ports released after rollback" "$BUSY" "0"

step "14. clean reinstall from scratch (post-rollback integrity)"
rm -rf "$SB"
build_harness; start_harness
install_panel "$TEST/install-4.log"
chk_rc $? "clean install exited 0"
chk_has "e2e PASSED after clean install" "$TEST/install-4.log" "end-to-end verification PASSED"

step "15. UNINSTALL (haproxy topology)"
bash "$REPO/scripts/uninstall.sh" --sandbox --yes \
  --haproxy-cfg "$HCFG" --haproxy-bin "$HAP" --haproxy-pidfile "$HPID" \
  > "$TEST/uninstall-haproxy.log" 2>&1
chk_rc $? "uninstall.sh exited 0"
chk_eq "managed blocks removed from shared cfg" "$(grep -c '^# BEGIN ops-terminal' "$HCFG")" "0"
chk_has "bind RESTORED to original crt file" "$HCFG" "ssl crt $SB/etc/haproxy/certs/hanaso.pem"
chk_not "no crt-list reference left" "$HCFG" "crt-list"
[ -e "$CRTLIST" ] && bad "crtlist still present after uninstall" || ok "crtlist removed"
[ -e "$PEM" ] && bad "panel PEM still present after uninstall" || ok "panel PEM removed"
rc_run "$HAP" -c -q -f "$HCFG"
chk_eq "HAProxy master pid UNCHANGED through uninstall" "$(master_pid)" "$MASTER_BEFORE"
[ -e "$SB/etc/ops-terminal" ] && bad "etc/ops-terminal still present" || ok "panel config removed"
[ -e "$SB/opt/ops-terminal" ] && bad "opt/ops-terminal still present" || ok "panel binaries removed"
SHARED4="$(curl -sk --resolve "$SHARED_DOMAIN:$EDGE:127.0.0.1" "https://$SHARED_DOMAIN:$EDGE/" 2>/dev/null)"
chk_eq "shared site still serving after uninstall" "$SHARED4" "SHARED-SITE-OK"

step "16. final clean reinstall (leave the panel RUNNING for inspection)"
install_panel "$TEST/install-5.log"
chk_rc $? "final install exited 0"
bash "$REPO/scripts/health-check.sh" --conf "$SB/etc/ops-terminal/env" --sandbox > "$TEST/health-final.log" 2>&1
chk_rc $? "final health check"
SHARED5="$(curl -sk --resolve "$SHARED_DOMAIN:$EDGE:127.0.0.1" "https://$SHARED_DOMAIN:$EDGE/")"
chk_eq "final: shared site OK" "$SHARED5" "SHARED-SITE-OK"

echo
echo "############################################"
echo " HAPROXY BATTERY COMPLETE — TOTAL FAILED STEPS: $FAILS"
echo "############################################"
exit "$FAILS"
