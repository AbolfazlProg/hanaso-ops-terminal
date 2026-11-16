#!/usr/bin/env bash
# ==========================================================================
# HANASO OPS Web Terminal — CP10 battery
# Replicates the REAL VPS clean-install scenario reported 2026-11-17:
#   preflight finds NO covering certificate  -> PREFLIGHT_CERT_PATH=''
#   certbot IS available                     -> Let's Encrypt issuance branch
#   DNS A-record OK                          -> HTTP-01 via the HAProxy :80 route
#
# The installer must:
#   accept the empty path through the STRICT parser (the CP10 parser bug),
#   activate the certbot branch, add the managed ACME HTTP-01 route on :80,
#   issue a NEW certificate, validate it (readable/valid/domain/key-match),
#   wire HAProxy with it, and keep the shared site untouched throughout —
#   with rollback and uninstall paths verified too. A stub certbot
#   (tests/stub-certbot.sh) proves the challenge round-trip through the REAL
#   edge (HAProxy :80 -> acme backend -> internal nginx -> webroot).
#
# Usage: bash tests/cp10-battery.sh
# Env  : OPS_SANDBOX_ROOT (default /home/z/ops-sandbox-cp10)
# Exit : number of failed steps
# ==========================================================================
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SB="${OPS_SANDBOX_ROOT:-/home/z/ops-sandbox-cp10}"
export OPS_SANDBOX_ROOT="$SB"
SBROOT=/home/z/sandbox-root
TEST=/home/z/ops-sandbox-test
PY=/home/z/.venv/bin/python3
HAP="$SBROOT/usr/sbin/haproxy"
NGX="$SBROOT/usr/sbin/nginx"
LIBDIR="$SBROOT/usr/lib/x86_64-linux-gnu"
export LD_LIBRARY_PATH="$LIBDIR"

EDGE=8444; HTTP80=8081; SHARED_PORT=9091
DOMAIN=ops.hanaso.ir; SHARED_DOMAIN=kotodama.ir
HCFG="$SB/etc/haproxy/haproxy.cfg"
HPID="$SB/haproxy-test/haproxy.pid"
CRTLIST="$SB/etc/haproxy/ops-terminal.crtlist"
PEM="$SB/etc/haproxy/certs/ops-terminal.pem"
HAP_LOG="$SB/var/log/haproxy.log"
STUB="$REPO/tests/stub-certbot.sh"
LEBASE="$SB/etc/letsencrypt"                    # sandbox letsencrypt base (OPS_LE_LIVE_BASE)
LIVECERT="$LEBASE/live/$DOMAIN/fullchain.pem"
LIVEKEY="$LEBASE/live/$DOMAIN/privkey.pem"
PWFILE="$TEST/pw-cp10-current"

export OPS_LE_LIVE_BASE="$LEBASE"
export OPS_STUB_HTTP80="$HTTP80"
export OPS_STUB_CA_DIR="$TEST"
# the test CA is a session artifact — recreate it when the environment was
# recycled (tests/setup-sandbox-toolchain.sh does not create it)
if [ ! -r "$TEST/ca.crt" ] || [ ! -r "$TEST/ca.key" ]; then
  openssl req -x509 -newkey rsa:2048 -keyout "$TEST/ca.key" -out "$TEST/ca.crt" \
    -days 365 -nodes -subj "/CN=cp10-stub-ca" 2>/dev/null \
    && echo "  [battery] test CA regenerated at $TEST/ca.{crt,key}"
fi
export OPS_STUB_LIVE_BASE="$LEBASE"

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
master_pid() { [ -r "$HPID" ] && head -n1 "$HPID" || echo ""; }
edge_alive() { ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":$EDGE$"; }

# ---------------------------------------------------------------- helpers --
build_harness() {
  # mirrors the REAL VPS: HAProxy owns the public TLS edge + a plain :80
  # frontend for the shared site; NO panel certificate exists anywhere yet
  # (clean-install scenario; the panel cert comes ONLY from certbot).
  mkdir -p "$SB/etc/haproxy/certs" "$SB/haproxy-test" "$SB/var/log" "$SB/var/www/html" "$TEST"
  cp "$TEST/hanaso.pem" "$SB/etc/haproxy/certs/hanaso.pem"
  rm -rf "$LEBASE"                                # NO prior letsencrypt state
  cat > "$HCFG" <<EOF
# sandbox harness — mirrors the REAL VPS (HAProxy owns 443 + plain :80)
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
  cat > "$TEST/shared-server-cp10.py" <<'PYEOF'
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
HTTPServer(("127.0.0.1", 9091), H).serve_forever()
PYEOF
}

start_harness() {
  pkill -f "$TEST/shared-server-cp10.py" 2>/dev/null || true
  pkill -f "$HCFG" 2>/dev/null || true
  sleep 0.4
  nohup "$PY" "$TEST/shared-server-cp10.py" > "$TEST/shared-server-cp10.log" 2>&1 &
  echo $! > "$TEST/shared-server-cp10.pid"
  nohup "$HAP" -W -db -f "$HCFG" -p "$HPID" > "$HAP_LOG" 2>&1 &
  sleep 1.2
  MASTER_BEFORE="$(master_pid)"
}

stop_harness() {
  [ -f "$TEST/shared-server-cp10.pid" ] && kill "$(cat "$TEST/shared-server-cp10.pid")" 2>/dev/null
  [ -f "$HPID" ] && kill "$(head -n1 "$HPID")" 2>/dev/null
  pkill -f "$HCFG" 2>/dev/null || true
  sleep 0.4
}

wait_shared() {
  local out=""; for _ in 1 2 3 4 5 6 7 8 9 10; do
    out="$(curl -sk --resolve "$SHARED_DOMAIN:$EDGE:127.0.0.1" "https://$SHARED_DOMAIN:$EDGE/" 2>/dev/null)"
    [ "$out" = "SHARED-SITE-OK" ] && break
    sleep 1
  done
  printf '%s' "$out"
}

tmux_reset() { TMUX_TMPDIR="$SB/var/tmp/ops-terminal" "$SBROOT/usr/bin/tmux" kill-server 2>/dev/null || true; sleep 0.5; }

install_panel() { # logfile extra-args...
  local log="$1"; shift
  bash "$REPO/scripts/install.sh" --sandbox --sandbox-topology haproxy --yes \
    --haproxy-cfg "$HCFG" --haproxy-bin "$HAP" --haproxy-pidfile "$HPID" \
    --https-port "$EDGE" --http-port "$HTTP80" \
    --nginx-bin "$NGX" --mime-types "$SBROOT/etc/nginx/mime.types" \
    --tmux-bin "$SBROOT/usr/bin/tmux" --tmux-ld-path "$LIBDIR" \
    --python-bin "$PY" "$@" > "$log" 2>&1
  local r=$?
  [ "$r" -ne 0 ] && { echo "  --- install tail ($log) ---"; tail -n 30 "$log" | sed 's/^/    /'; }
  return $r
}

# =============================================================== main ======
# Panel ports (7680-7682) are GLOBAL constants across sandboxes — no other
# sandbox's panel may be alive while this battery runs (a leftover gateway
# would answer the health checks and poison the e2e login).
step "0-pre. port hygiene: no stray panel from any sandbox"
pkill -f 'opt/ops-terminal/gateway/gateway.py' 2>/dev/null || true
pkill -f 'opt/ops-terminal/bin/ttyd' 2>/dev/null || true
pkill -f 'ops-terminal-internal.conf' 2>/dev/null || true
pkill -f 'ops-terminal/nginx/nginx.conf' 2>/dev/null || true
pkill -f 'new -A -s ops' 2>/dev/null || true
# a previous haproxy-front battery leaves its own edge + shared stub behind
pkill -f '/home/z/ops-sandbox' 2>/dev/null || true
pkill -f 'shared-server' 2>/dev/null || true
sleep 1
BUSY=0; for p in 7680 7681 7682; do
  ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":$p$" && BUSY=$((BUSY+1))
done
chk_eq "panel ports 7680-7682 free before the battery" "$BUSY" "0"

step "0. harness: clean VPS-like baseline (NO panel cert, NO letsencrypt state)"
build_harness
start_harness
chk_rc $? "harness started"
if edge_alive; then ok "edge :$EDGE listening (haproxy)"; else bad "edge :$EDGE NOT listening"; fi
chk_eq "shared site answers through the edge (baseline)" "$(wait_shared)" "SHARED-SITE-OK"
chk_eq "no crt-list on the bind yet" "$(grep -c 'crt-list' "$HCFG")" "0"
[ -e "$LEBASE" ] && bad "letsencrypt state exists before install" || ok "no letsencrypt state (clean)"

step "1. PARSER — the exact VPS fixture: PREFLIGHT_CERT_PATH='' must PASS (CP10 incident)"
T1="$(mktemp -d)"
(
  set -u
  . "$REPO/scripts/ops-env.sh"
  # the exact situation from the 2026-11-17 VPS evidence: no covering cert,
  # certbot available, haproxy-front topology (values as preflight writes them)
  cat > "$T1/fixture.env" <<'EOF'
PREFLIGHT_DOMAIN='ops.hanaso.ir'
PREFLIGHT_TOPOLOGY='haproxy-front'
PREFLIGHT_HAPROXY_BIND_MODE='ssl-term'
PREFLIGHT_HAPROXY_CRT_STYLE='file'
PREFLIGHT_HAPROXY_CRT_PATH='/etc/haproxy/haproxy.pem'
PREFLIGHT_HAPROXY_FRONTEND='f_shared_443'
PREFLIGHT_HAPROXY_RELOAD='systemd'
PREFLIGHT_HAPROXY_ACME_ROUTED='0'
PREFLIGHT_HAPROXY_HTTP80='1'
PREFLIGHT_HAPROXY_OPS_CERT_EXISTS='0'
PREFLIGHT_CERT_PATH=''
PREFLIGHT_CERT_KEY=''
PREFLIGHT_CERTBOT='/usr/bin/certbot'
PREFLIGHT_DNS_MATCH='1'
EOF
  ops_env_read "$T1/fixture.env" || exit 10
  [ -z "$PREFLIGHT_CERT_PATH" ] || exit 11
  [ "$PREFLIGHT_HAPROXY_OPS_CERT_EXISTS" = "0" ] || exit 12
  # non-empty values still parse intact
  [ "$PREFLIGHT_HAPROXY_CRT_PATH" = "/etc/haproxy/haproxy.pem" ] || exit 13
  # fail-closed REGRESSIONS: garbage path, unknown key, empty domain
  printf "PREFLIGHT_CERT_PATH='/etc/hapro xy/bad.pem'\n" > "$T1/garbage.env"
  ops_env_read "$T1/garbage.env" 2>/dev/null && exit 14
  printf "TOTALLY_UNKNOWN_KEY='x'\n" > "$T1/unknown.env"
  ops_env_read "$T1/unknown.env" 2>/dev/null && exit 15
  printf "PREFLIGHT_DOMAIN=''\n" > "$T1/emptydom.env"
  ops_env_read "$T1/emptydom.env" 2>/dev/null && exit 16
  exit 0
)
chk_rc $? "empty PREFLIGHT_CERT_PATH accepted + garbage/unknown/empty-domain still fail-closed"
rm -rf "$T1"

step "2. CLEAN INSTALL — no certificate, certbot branch activates (production code path)"
rm -rf "$SB"
build_harness; start_harness
install_panel "$TEST/cp10-install-1.log" --simulate-acme --certbot-bin "$STUB"
chk_rc $? "install.sh exited 0 (clean install, stub certbot)"
chk_has "parser accepted the empty-cert state (no strict-validation FATAL)" "$TEST/cp10-install-1.log" "ACME simulation"
chk_has "certbot branch ACTIVATED" "$TEST/cp10-install-1.log" "certbot: issuing Let's Encrypt certificate"
chk_has "managed ACME HTTP-01 route added to :80 (validated + reloaded)" "$TEST/cp10-install-1.log" "managed ACME HTTP-01 route added"
chk_has "stub: ACME challenge round-trip through the REAL edge" "$TEST/cp10-install-1.log" "ACME challenge round-trip OK through the real edge"
chk_has "stub: certificate issued" "$TEST/cp10-install-1.log" "certificate issued for $DOMAIN"
chk_has "installer e2e PASSED (login->websocket->shell)" "$TEST/cp10-install-1.log" "end-to-end verification PASSED"
PW="$(sed -n 's/^ PASSWORD    : //p' "$TEST/cp10-install-1.log" | head -n1)"
[ -n "$PW" ] && ok "one-time password captured" || bad "password not found in install log"
printf '%s' "$PW" > "$PWFILE"; chmod 600 "$PWFILE"
export OPS_TEST_PW="$PW"

step "3. issued certificate: exists, valid, covers the domain, matches its key"
[ -r "$LIVECERT" ] && [ -r "$LIVEKEY" ] && ok "certificate + private key exist at the letsencrypt live path" \
  || bad "live cert/key missing ($LIVECERT)"
openssl x509 -in "$LIVECERT" -noout -checkend 86400 >/dev/null 2>&1 \
  && ok "issued certificate valid (>24h remaining)" || bad "issued certificate invalid/expired"
openssl x509 -in "$LIVECERT" -noout -ext subjectAltName 2>/dev/null | grep -qi "DNS:$DOMAIN" \
  && ok "issued certificate SAN covers $DOMAIN" || bad "SAN does not cover $DOMAIN"
C="$(openssl x509 -in "$LIVECERT" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
K="$(openssl pkey -in "$LIVEKEY" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
chk_eq "issued key matches issued certificate" "$C" "$K"
[ -f "$PEM" ] && { printf '%s\n' "$(cat "$LIVECERT" "$LIVEKEY")" | diff -q - "$PEM" >/dev/null 2>&1 \
  && ok "HAProxy PEM built EXACTLY from the newly issued cert+key (path replaced initial '')" \
  || bad "HAProxy PEM does not match the issued pair"; } || bad "panel PEM missing"

step "4. HAProxy config state: valid, cert integrated, shared site untouched"
rc_run "$HAP" -c -q -f "$HCFG"
chk_has "bind converted to managed crt-list (reversible)" "$HCFG" "crt-list $CRTLIST"
chk_eq "crtlist: original shared cert first" "$(head -n1 "$CRTLIST")" "$SB/etc/haproxy/certs/hanaso.pem"
chk_eq "crtlist: panel PEM (from certbot) second" "$(tail -n1 "$CRTLIST")" "$PEM"
chk_eq "exactly 4 managed blocks (panel + backend + acme + acme-backend)" \
  "$(grep -c '^# BEGIN ops-terminal' "$HCFG")" "4"
chk_eq "HAProxy master pid UNCHANGED (reload only)" "$(master_pid)" "$MASTER_BEFORE"
chk_eq "shared site UNAFFECTED on :443 (kotodama.ir)" "$(wait_shared)" "SHARED-SITE-OK"
HTTP_SHARED="$(curl -s -m 3 "http://127.0.0.1:$HTTP80/" 2>/dev/null)"
chk_eq "shared site UNAFFECTED on :80 (ACME ACL did not break default routing)" "$HTTP_SHARED" "SHARED-SITE-OK"

step "5. ACME HTTP-01 route: independent challenge round-trip THROUGH the :80 edge"
TOK="battery-token-$$"; BODY="acme-proof-$TOK"
printf '%s' "$BODY" > "$SB/var/www/html/.well-known/acme-challenge/$TOK"
GOT="$(curl -sf -m 5 "http://127.0.0.1:$HTTP80/.well-known/acme-challenge/$TOK" 2>/dev/null)"
chk_eq "HTTP-01 challenge routed: HAProxy :80 -> acme backend -> internal nginx -> webroot" "$GOT" "$BODY"
GOT443="$(curl -sk --resolve "$SHARED_DOMAIN:$EDGE:127.0.0.1" -m 5 \
  "https://$SHARED_DOMAIN:$EDGE/.well-known/acme-challenge/UNRELATED" -o /dev/null -w '%{http_code}' 2>/dev/null)"
chk_eq "non-challenge paths still hit the shared backend on :443 (no route leak)" "$GOT443" "200"

step "6. HTTPS + SNI + WebSocket e2e through the NEW certificate"
tmux_reset
printf '%s' "$PW" | "$PY" "$REPO/scripts/e2e-test.py" \
  --base "$OPS_TEST_BASE" --connect 127.0.0.1 \
  --username "$OPS_TEST_USER" --password-stdin \
  --insecure-allow --expect-uid "$(id -u)" > "$TEST/cp10-e2e.log" 2>&1
chk_rc $? "e2e-test.py full chain (TLS served by the certbot-issued cert)"
HEALTH="$(curl -sk --resolve "$DOMAIN:$EDGE:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$DOMAIN:$EDGE/health")"
chk_eq "panel /health via HAProxy SNI -> internal nginx" "$HEALTH" "200"

step "7. real browser E2E through the new certificate (Playwright)"
tmux_reset
if [ -d /home/z/.npm-global/lib/node_modules ]; then
  NODE_PATH=/home/z/.npm-global/lib/node_modules node "$REPO/tests/browser-test.js" \
    --url "$OPS_TEST_BASE" --username "$OPS_TEST_USER" --password-file "$PWFILE" \
    --map-host "$DOMAIN" --expect-uid "$(id -u)" --out "$TEST/shots-cp10" > "$TEST/browser-cp10.log" 2>&1
  chk_rc $? "browser: login -> terminal render -> typing -> output"
else
  bad "npm-global node_modules missing — browser test skipped"
fi

step "8. ROOT proof: id -u -> 0 from a REAL BROWSER through the certbot-installed panel"
# swap ttyd to a userns-root instance (same code path as tests/rootproof.sh)
kill "$(cat "$SB/run/ttyd.pid")" 2>/dev/null || true
rm -f "$SB/run/ttyd.pid"; sleep 0.5
tmux_reset
nohup unshare -Ur env TMUX_TMPDIR="$SB/var/tmp/ops-terminal" \
  LD_LIBRARY_PATH="$LIBDIR" \
  "$SB/opt/ops-terminal/bin/ttyd" -i 127.0.0.1 -p 7681 -W -O -m 2 \
  -T xterm-256color -w "$HOME" \
  "$SBROOT/usr/bin/tmux" new -A -s ops \
  >> "$SB/var/log/ops-terminal/ttyd.log" 2>&1 &
echo $! > "$SB/run/ttyd.pid"
sleep 1
curl -sf -m 2 "http://127.0.0.1:7681/" -o /dev/null && ok "userns ttyd up (uid 0 shell)" || bad "userns ttyd down"
CRED="$("$PY" "$SB/opt/ops-terminal/gateway/gateway.py" passwd --generate --print-once 2>/dev/null)"
printf '%s' "$CRED" | sed -n 's/^PANEL_PASSWORD=//p' > "$PWFILE"; chmod 600 "$PWFILE"
printf '%s' "$(cat "$PWFILE")" | "$PY" "$REPO/scripts/e2e-test.py" \
  --base "$OPS_TEST_BASE" --connect 127.0.0.1 \
  --username "$OPS_TEST_USER" --password-stdin \
  --insecure-allow --expect-uid 0 > "$TEST/cp10-e2e-root.log" 2>&1
chk_rc $? "WS-level e2e with --expect-uid 0"
if [ -d /home/z/.npm-global/lib/node_modules ]; then
  NODE_PATH=/home/z/.npm-global/lib/node_modules node "$REPO/tests/browser-test.js" \
    --url "$OPS_TEST_BASE" --username "$OPS_TEST_USER" --password-file "$PWFILE" \
    --map-host "$DOMAIN" --expect-uid 0 --out "$TEST/shots-cp10-root" > "$TEST/browser-cp10-root.log" 2>&1
  chk_rc $? "REAL BROWSER: id -u printed 0 through the certbot-installed panel"
else
  bad "npm-global node_modules missing — root browser test skipped"
fi

step "9. idempotent re-install (certbot keep-until-expiring + no duplicate blocks)"
install_panel "$TEST/cp10-install-2.log" --simulate-acme --certbot-bin "$STUB"
chk_rc $? "re-install exited 0"
chk_has "stub renewed NOTHING (keep-until-expiring no-op)" "$TEST/cp10-install-2.log" "already present, keeping until expiring"
chk_eq "still exactly 4 managed blocks (no duplicates)" "$(grep -c '^# BEGIN ops-terminal' "$HCFG")" "4"
chk_eq "single managed ACME acl (idempotent)" "$(grep -c 'acl OPS_TERM_ACME' "$HCFG")" "1"
chk_eq "single panel SNI acl (idempotent)" "$(grep -c 'acl OPS_TERM_SNI' "$HCFG")" "1"
chk_eq "HAProxy master pid STILL unchanged" "$(master_pid)" "$MASTER_BEFORE"
chk_eq "shared site OK after re-install" "$(wait_shared)" "SHARED-SITE-OK"

step "10. FORCED ROLLBACK (e2e failure AFTER certbot+HAProxy wiring)"
install_panel "$TEST/cp10-install-3.log" --simulate-acme --certbot-bin "$STUB" --reset-credentials --e2e-expect-uid 999999
RC3=$?
[ "$RC3" -ne 0 ] && ok "install exited non-zero on forced e2e failure (rc=$RC3)" || bad "install unexpectedly succeeded"
chk_has "rollback banner present" "$TEST/cp10-install-3.log" "[install][ROLLBACK]"
chk_eq "ALL managed blocks reverted (incl. acme + acme-backend)" "$(grep -c '^# BEGIN ops-terminal' "$HCFG")" "0"
chk_has "bind RESTORED to original crt file" "$HCFG" "ssl crt $SB/etc/haproxy/certs/hanaso.pem"
chk_not "no crt-list reference left" "$HCFG" "crt-list"
[ -e "$CRTLIST" ] && bad "crtlist still present after rollback" || ok "crtlist removed"
[ -e "$PEM" ] && bad "panel PEM still present after rollback" || ok "panel PEM removed"
rc_run "$HAP" -c -q -f "$HCFG"
chk_eq "HAProxy master pid UNCHANGED through rollback" "$(master_pid)" "$MASTER_BEFORE"
chk_eq "shared site still serving after rollback" "$(wait_shared)" "SHARED-SITE-OK"
BUSY=0; for p in 7680 7681 7682; do
  ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":$p$" && BUSY=$((BUSY+1))
done
chk_eq "panel ports released after rollback" "$BUSY" "0"

step "11. clean reinstall after rollback + UNINSTALL (letsencrypt state is PRESERVED)"
rm -rf "$SB"
build_harness; start_harness
install_panel "$TEST/cp10-install-4.log" --simulate-acme --certbot-bin "$STUB"
chk_rc $? "clean reinstall exited 0 (stub re-issues from the kept LE state)"
bash "$REPO/scripts/uninstall.sh" --sandbox --yes \
  --haproxy-cfg "$HCFG" --haproxy-bin "$HAP" --haproxy-pidfile "$HPID" \
  > "$TEST/cp10-uninstall.log" 2>&1
chk_rc $? "uninstall.sh exited 0"
chk_eq "ALL managed blocks removed from shared cfg" "$(grep -c '^# BEGIN ops-terminal' "$HCFG")" "0"
chk_has "bind RESTORED to original crt file" "$HCFG" "ssl crt $SB/etc/haproxy/certs/hanaso.pem"
chk_not "no crt-list reference left" "$HCFG" "crt-list"
[ -e "$CRTLIST" ] && bad "crtlist still present after uninstall" || ok "crtlist removed"
[ -e "$PEM" ] && bad "panel PEM still present after uninstall" || ok "panel PEM removed"
[ -r "$LIVECERT" ] && ok "letsencrypt live certificate PRESERVED (never touches LE state)" \
  || bad "letsencrypt live cert was deleted by uninstall"
[ -e "$LEBASE/renewal-hooks/deploy/ops-terminal-haproxy.sh" ] \
  && bad "renewal hook still present after uninstall" || ok "no renewal deploy hook left in sandbox"
rc_run "$HAP" -c -q -f "$HCFG"
chk_eq "HAProxy master pid UNCHANGED through uninstall" "$(master_pid)" "$MASTER_BEFORE"
chk_eq "shared site still serving after uninstall" "$(wait_shared)" "SHARED-SITE-OK"

step "12. NEGATIVE path: certbot issuance FAILS -> fail-closed TLS GATE (loopback-only)"
rm -rf "$SB"
build_harness; start_harness
OPS_STUB_FAIL=1 install_panel "$TEST/cp10-install-fail.log" --simulate-acme --certbot-bin "$STUB"
chk_rc $? "install exited 0 with the SAFE loopback-only outcome (fail-closed, not a crash)"
chk_has "TLS GATE banner shown" "$TEST/cp10-install-fail.log" "TLS GATE"
chk_has "stub issuance failure reached the installer" "$TEST/cp10-install-fail.log" "simulated ACME failure"
chk_has "loopback-only DONE" "$TEST/cp10-install-fail.log" "DONE (loopback-only, TLS/DNS gate)"
chk_eq "ZERO managed blocks after failed issuance" "$(grep -c '^# BEGIN ops-terminal' "$HCFG")" "0"
chk_has "bind UNTOUCHED (shared cert still on the bind)" "$HCFG" "ssl crt $SB/etc/haproxy/certs/hanaso.pem"
chk_eq "shared site OK after failed issuance" "$(wait_shared)" "SHARED-SITE-OK"
for p in 7680 7681 7682; do
  ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "127\.0\.0\.1:$p$" \
    && ok "loopback-only: panel port $p stays loopback" || bad "panel port $p not loopback after TLS GATE"
done
# teardown the loopback-only panel so later batteries never collide with it
# (the safe fail-closed state intentionally keeps services RUNNING)
bash "$REPO/scripts/uninstall.sh" --sandbox --yes > "$TEST/cp10-uninstall-fail.log" 2>&1
chk_rc $? "uninstall teardown of the loopback-only panel"
BUSY=0; for p in 7680 7681 7682; do
  ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":$p$" && BUSY=$((BUSY+1))
done
chk_eq "panel ports freed after teardown" "$BUSY" "0"

stop_harness
echo
echo "############################################"
echo " CP10 BATTERY COMPLETE — TOTAL FAILED STEPS: $FAILS"
echo "############################################"
exit "$FAILS"
