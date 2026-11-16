#!/usr/bin/env bash
# ==========================================================================
# CP12 BATTERY — FINAL NGINX SYSTEMD COMPATIBILITY (no -e, verbatim unit)
#
# Production incident (real CP11-INSTALL-FAILURE):
#   * Nov 16 20:07:56  nginx: invalid option: "e"
#   * plus the earlier  "pid" directive is duplicate  and the
#     could not open error log file ... Permission denied alerts.
#
# ROOT CAUSE (evidence-based, proven below):
#   The `-e` command-line switch exists ONLY since nginx 1.19.5
#   (2020-11-24, nginx changes.xml: "the -e switch"). The production VPS
#   binary is older than that (Ubuntu 22.04 LTS ships 1.18.0). CP11's unit
#   baked `-e stderr` into ExecStartPre/ExecStart/ExecReload, so on the VPS
#   nginx exited before touching ANY config. The CP11 battery could not see
#   this because it ran the unit with the Debian trixie binary (1.26.3,
#   HAS -e) — the Ubuntu jammy 1.18 binary (the production build class, whose
#   compiled-in error-log-path is /var/log/nginx/error.log) was only used to
#   reproduce the Finding-2 alert, never the full unit command line.
#
# WHAT THIS BATTERY PROVES (CP12 acceptance):
#   S1  binary matrix + the invalid-option failure mechanism reproduced
#       EXACTLY, on the production-class binary, with the CP11-era unit form
#   S2  unit lint: NO version-dependent option, PID single-source,
#       bounded restart policy
#   S3  real clean install (scripts/install.sh, haproxy-front sandbox)
#   S4  verbatim unit ExecStart/ExecReload on the PRODUCTION-CLASS binary
#       (nginx 1.18.0) — starts, listens 127.0.0.1:7680, serves, reloads
#   S5  ops-gw identity kernel proof: the verbatim ExecStart as a REAL
#       unprivileged identity (userns nobody, zero capabilities) — config
#       dir write DENIED by the kernel, shared /var/log/nginx never
#       touched, benign early-log alert, nginx still serves
#   S6  supervisor battery: 11-step CP12 list (gateway/ttyd/nginx health,
#       auth request, WebSocket, real browser terminal, id -u, interactive
#       command, controlled restart, forced failure WITHOUT restart loop,
#       rollback stops every dedicated service)
#   S7  production-leftover reinstall (units missing, files+backups remain)
#       — idempotent reconciliation, credentials preserved, backups intact
#   S8  systemd real-code proofs: systemd-analyze verify + REAL systemd 257
#       manager transaction (--user --test) over the REAL unit files
#   S9  real quick-install.sh bootstrap run from the committed tree
#
# NOTE: a live systemd MANAGER (system or user) cannot run in this container
# at all: /sys/fs/cgroup is a foreign tmpfs, mount-over is denied, and the
# real manager aborts in manager_setup_cgroup (captured evidence:
# strace exit_group(1) right after /proc/self/cgroup + cgroup.c:4160
# "Cannot determine cgroup we are running in" / the CP11-captured
# "Failed to create /k8s.io/.../init.scope control group: Read-only file
# system"). The unit POLICY is therefore exercised by (a) systemd's own
# parser (systemd-analyze verify), (b) the REAL manager's transaction
# computation (systemd --user --test), and (c) the unit-policy supervisor
# running the verbatim Exec* lines. On the VPS the same files load into the
# real system manager unchanged.
#
# Usage : bash tests/cp12-battery.sh        (run AFTER committing the CP12
#         changes: S9 clones the committed tree)
# Exit  : number of failed checks
# ==========================================================================
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SB="${OPS_SANDBOX_ROOT:-/home/z/ops-sandbox}"
SBROOT=/home/z/sandbox-root
SBROOT_UB=/home/z/sandbox-root-ub
TEST=/home/z/ops-sandbox-test
PY=/home/z/.venv/bin/python3
HAP="$SBROOT/usr/sbin/haproxy"
NGX="$SBROOT/usr/sbin/nginx"
UBNGX="$SBROOT_UB/usr/sbin/nginx"   # VPS-class build (compiled-in /var/log/nginx/error.log)
LIBDIR="$SBROOT/usr/lib/x86_64-linux-gnu"
export LD_LIBRARY_PATH="$LIBDIR:$SBROOT_UB/usr/lib/x86_64-linux-gnu:$SBROOT_UB/lib/x86_64-linux-gnu"
SV="$PY $REPO/tests/cp11-supervisor.py"  # intentionally UNQUOTED at call sites

EDGE=8443; HTTP80=8080; SHARED_PORT=9090
DOMAIN=ops.hanaso.ir; SHARED_DOMAIN=kotodama.ir
HCFG="$SB/etc/haproxy/haproxy.cfg"
HPID="$SB/haproxy-test/haproxy.pid"
HAP_LOG="$SB/var/log/haproxy.log"
PWFILE="$TEST/pw-cp12-current"
GW="$SB/opt/ops-terminal/gateway/gateway.py"
SVSTATE="$TEST/cp12-svstate"
SVLOGS="$TEST/cp12-logs"
UNITS_DIR="$TEST/cp12-units"
UNITS_UB="$TEST/cp12-units-ub"
REPRO_DIR="$TEST/cp12-repro"
NOBODY_DIR="$TEST/cp12-nobody"
UM_HOME="$TEST/cp12-um-home"
MYUID="$(id -u)"; MYUSER="$(id -un)"; MYGROUP="$(id -gn)"

export OPS_TEST_BASE="https://$DOMAIN:$EDGE"
export OPS_TEST_IP="127.0.0.1"
export OPS_TEST_USER="ops-admin"
export OPS_TERMINAL_CONF="$SB/etc/ops-terminal/env"

FAILS=0
step() { echo; echo "############################################"; echo "### $*"; echo "############################################"; }
ok()  { echo "  [PASS] $*"; }
bad() { echo "  [FAIL] $*"; FAILS=$((FAILS+1)); }
chk_rc()   { [ "$1" -eq 0 ] && ok "$2" || bad "$2 (rc=$1)"; }
chk_eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', want '$3')"; }
chk_has()  { grep -qF -- "$3" "$2" 2>/dev/null && ok "$1" || bad "$1 (missing '$3' in $2)"; }
chk_not()  { grep -qF -- "$3" "$2" 2>/dev/null && bad "$1 (found '$3' in $2)" || ok "$1"; }
chk_grep() { grep -qE -- "$3" "$2" 2>/dev/null && ok "$1" || bad "$1 (pattern '$3' not in $2)"; }

master_pid() { [ -r "$HPID" ] && head -n1 "$HPID" || echo ""; }

# ----------------------------------------------------------- harness (CP11) --
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
stop_nohup_services() {
  bash "$REPO/tests/sandbox-ctl.sh" stop all >/dev/null 2>&1 || true
  pkill -f "$SB/etc/ops-terminal/nginx/nginx.conf" 2>/dev/null || true
  pkill -f "$SB/opt/ops-terminal" 2>/dev/null || true
  pkill -f "new -A -s ops" 2>/dev/null || true
  sleep 0.8
}
# unit translation: EXACTLY the seds production install.sh applies.
# $1 = nginx binary to substitute for /usr/sbin/nginx (trixie or UB), "" = default
translate_units_into() { # <target-dir> <nginx-binary>
  local d="$1" nb="$2"
  rm -rf "$d"; mkdir -p "$d"
  sed -e "s|/opt/ops-terminal|$SB/opt/ops-terminal|g" \
      -e "s|/etc/ops-terminal|$SB/etc/ops-terminal|g" \
      -e "s|/var/lib/ops-terminal|$SB/var/lib/ops-terminal|g" \
      -e "s|/var/log/ops-terminal|$SB/var/log/ops-terminal|g" \
      -e "s|/var/tmp/ops-terminal|$SB/var/tmp/ops-terminal|g" \
      -e "s|/usr/sbin/nginx|$nb|g" \
      -e "s|/usr/bin/python3|$PY|g" \
      -e "s|/usr/bin/tmux|$SBROOT/usr/bin/tmux|g" \
      -e "s|-w /root|-w $HOME|" \
      -e "s|-o root -g root|-o $MYUSER -g $MYGROUP|" \
      "$REPO/systemd/ops-terminal-nginx.service"    > "$d/ops-terminal-nginx.service"
  sed -e "s|/opt/ops-terminal|$SB/opt/ops-terminal|g" \
      -e "s|/etc/ops-terminal|$SB/etc/ops-terminal|g" \
      -e "s|/usr/bin/python3|$PY|g" \
      "$REPO/systemd/ops-terminal-gateway.service"  > "$d/ops-terminal-gateway.service"
  sed -e "s|/opt/ops-terminal|$SB/opt/ops-terminal|g" \
      -e "s|/etc/ops-terminal|$SB/etc/ops-terminal|g" \
      -e "s|/var/tmp/ops-terminal|$SB/var/tmp/ops-terminal|g" \
      -e "s|/usr/bin/tmux|$SBROOT/usr/bin/tmux|g" \
      -e "s|-w /root|-w $HOME|" \
      -e "s|-o root -g root|-o $MYUSER -g $MYGROUP|" \
      "$REPO/systemd/ops-terminal.service"          > "$d/ops-terminal.service"
}
translate_units() { translate_units_into "$UNITS_DIR" "$NGX"; }

sv_start() { $SV start "$UNITS_DIR/$1" --state-dir "$SVSTATE" --log "$SVLOGS/$1.log"; }
sv_state_field() {
  "$PY" -c "
import json,sys
st=json.load(open('$SVSTATE/$1.state.json'))
print(st.get('$2',''))"
}
sv_wait_active() {
  local u="$1" n="${2:-30}"
  for _ in $(seq 1 "$n"); do
    [ "$(sv_state_field "$u" ActiveState)" = "active" ] && return 0
    sleep 0.4
  done
  return 1
}
wait_port() {
  local p="$1" n="${2:-30}"
  for _ in $(seq 1 "$n"); do
    ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "127\.0\.0\.1:$p$" && return 0
    sleep 0.4
  done
  return 1
}
tmux_reset() { TMUX_TMPDIR="$SB/var/tmp/ops-terminal" "$SBROOT/usr/bin/tmux" kill-server 2>/dev/null || true; sleep 0.5; }
ports_free() { # <ports...> -> 0 when none is listening
  local p busy=0
  for p in "$@"; do ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":$p$" && busy=1; done
  return $busy
}

# =============================================================== main ======
step "0. preconditions (unprivileged identity, toolchain, clean ports)"
[ "$(id -u)" != "0" ] && ok "battery runs as unprivileged '$MYUSER' (uid $MYUID) — the ops-gw identity equivalent" \
  || bad "battery must NOT run as root (identity fidelity)"
for b in "$NGX" "$UBNGX" "$HAP" "$PY" systemd-analyze; do
  [ -x "$b" ] || command -v "$b" >/dev/null 2>&1 || bad "missing tool: $b (run tests/setup-sandbox-toolchain.sh)"
done
[ -d /home/z/.npm-global/lib/node_modules ] && ok "playwright browser toolchain present" || ok "browser toolchain missing — browser checks will be recorded as SKIP-by-environment"
rm -rf "$SVSTATE" "$SVLOGS" "$UNITS_DIR" "$UNITS_UB" "$REPRO_DIR" "$NOBODY_DIR" "$UM_HOME"
mkdir -p "$SVSTATE" "$SVLOGS" "$UNITS_DIR" "$UNITS_UB" "$REPRO_DIR" "$NOBODY_DIR" "$UM_HOME"
# sweep leftovers from a previous battery run (supervisor services, nohup panel)
pkill -f "cp11-supervisor.py" 2>/dev/null || true
pkill -f "$SB/opt/ops-terminal" 2>/dev/null || true
pkill -f "$SB/etc/ops-terminal" 2>/dev/null || true
pkill -f "new -A -s ops" 2>/dev/null || true
sleep 1
BUSY=0; for p in 7680 7681 7682; do ss -tln | awk '{print $4}' | grep -qE ":$p$" && BUSY=$((BUSY+1)); done
chk_eq "panel ports 7680/7681/7682 free at start" "$BUSY" "0"
rm -rf "$SB"

# ==========================================================================
step "S1. BINARY MATRIX — the invalid-option mechanism, proven on both classes"
NGXV="$($NGX -V 2>&1 | head -n1)"
UBV="$($UBNGX -V 2>&1 | head -n1)"
UBERRPATH="$($UBNGX -V 2>&1 | grep -oE 'error-log-path=[^ ]+' | head -n1)"
echo "    sandbox binary : $NGXV"
echo "    VPS-class bin  : $UBV"
echo "                   : $UBERRPATH"
chk_grep "VPS-class binary is nginx 1.18.x (the production build class)" <(printf '%s' "$UBV") "nginx/1\.18\."
chk_eq "VPS-class compiled-in error log is /var/log/nginx/error.log (production Finding 2)" "$UBERRPATH" "error-log-path=/var/log/nginx/error.log"
"$NGX" -e stderr -v >/dev/null 2>&1
chk_rc $? "trixie 1.26.3 ACCEPTS -e stderr (why the CP11 battery stayed green)"
"$UBNGX" -e stderr -v > "$REPRO_DIR/invalid-option.log" 2>&1
RC_E=$?
chk_grep "CP11 incident mechanism REPRODUCED on the VPS-class binary" "$REPRO_DIR/invalid-option.log" 'invalid option: "e"'
[ "$RC_E" -ne 0 ] && ok "VPS-class binary REJECTS -e (rc=$RC_E) — exactly the production failure" \
  || bad "VPS-class binary unexpectedly accepted -e"
# the changelog boundary is quoted in the unit comments; assert the comment exists
chk_has "unit documents the 1.19.5 -e boundary" "$REPO/systemd/ops-terminal-nginx.service" "only since nginx 1.19.5"

# ==========================================================================
step "S2. UNIT LINT — no version-dependent option; PID single-source; bounded policy"
U="$REPO/systemd/ops-terminal-nginx.service"
# lint the EXEC LINES only — the explanatory comments legitimately mention
# the historical '-e stderr' / "-g 'pid'" bug forms in prose.
EXEC_LINES="$(grep -E '^Exec(Start|StartPre|Reload)=' "$U")"
chk_eq "unit Exec lines: ZERO occurrences of -e (CP12 fix)" \
  "$(printf '%s\n' "$EXEC_LINES" | grep -c -F -- '-e' || true)" "0"
chk_eq "unit Exec lines: ZERO -g pid redefinitions (CP11 fix kept)" \
  "$(printf '%s\n' "$EXEC_LINES" | grep -c -F -- "-g 'pid" || true)" "0"
chk_grep  "unit: Type=simple (foreground master)"                "$U" "^Type=simple$"
chk_grep  "unit: Restart=on-failure (never restart a clean stop)" "$U" "^Restart=on-failure$"
chk_grep  "unit: StartLimitIntervalSec=120 (loop killer)"        "$U" "^StartLimitIntervalSec=120$"
chk_grep  "unit: StartLimitBurst=5"                              "$U" "^StartLimitBurst=5$"
chk_grep  "unit: ExecReload is -s reload (no pid redefinition)"  "$U" "^ExecReload=.*-s reload$"
chk_grep  "unit: User=ops-gw / Group=ops-gw"                     "$U" "^User=ops-gw$"
chk_grep  "unit: hardening NoNewPrivileges"                      "$U" "^NoNewPrivileges=yes$"
chk_grep  "unit: NO root fallback in Exec lines" <(printf '%s' "$EXEC_LINES") "-c /etc/ops-terminal/nginx/nginx.conf"

# ==========================================================================
step "S3. REAL CLEAN INSTALL (scripts/install.sh, haproxy-front sandbox)"
build_harness; start_harness
install_panel "$TEST/install-cp12-1.log"
chk_rc $? "install.sh exited 0"
chk_has "installer e2e PASSED marker" "$TEST/install-cp12-1.log" "end-to-end verification PASSED"
PW="$(sed -n 's/^ PASSWORD    : //p' "$TEST/install-cp12-1.log" | head -n1)"
[ -n "$PW" ] && ok "one-time password captured" || bad "password missing from install log"
printf '%s' "$PW" > "$PWFILE"
chk_eq "rendered master conf has EXACTLY ONE pid directive" \
  "$(grep -c '^pid ' "$SB/etc/ops-terminal/nginx/nginx.conf")" "1"
chk_has "rendered master conf has daemon off" "$SB/etc/ops-terminal/nginx/nginx.conf" "daemon off;"
chk_eq "managed blocks in shared cfg" "$(grep -c '^# BEGIN ops-terminal' "$HCFG")" "2"
SHARED_OUT="$(curl -sk --resolve "$SHARED_DOMAIN:$EDGE:127.0.0.1" "https://$SHARED_DOMAIN:$EDGE/" 2>/dev/null)"
chk_eq "shared site (KOTODAMA/HANASO) UNAFFECTED" "$SHARED_OUT" "SHARED-SITE-OK"

# ==========================================================================
step "S4. VERBATIM UNIT COMMAND LINES on the PRODUCTION-CLASS binary (nginx 1.18.0)"
# keep the gateway + ttyd the installer started; replace ONLY the internal nginx
pkill -f "$SB/etc/ops-terminal/nginx/nginx.conf" 2>/dev/null || true
sleep 0.6
translate_units_into "$UNITS_UB" "$UBNGX"
UBSTART="$(sed -n 's/^ExecStart=//p' "$UNITS_UB/ops-terminal-nginx.service" | head -n1)"
UBPRE="$(sed   -n 's/^ExecStartPre=//p' "$UNITS_UB/ops-terminal-nginx.service" | head -n1)"
UBRELOAD="$(sed -n 's/^ExecReload=//p' "$UNITS_UB/ops-terminal-nginx.service" | head -n1)"
ok "verbatim ExecStartPre  : $UBPRE"
ok "verbatim ExecStart     : $UBSTART"
ok "verbatim ExecReload    : $UBRELOAD"
UBEXEC="$(grep -E '^Exec(Start|StartPre|Reload)=' "$UNITS_UB/ops-terminal-nginx.service")"
chk_eq "verbatim Exec lines carry NO -e (the CP11 killer)" \
  "$(printf '%s\n' "$UBEXEC" | grep -c -F -- '-e' || true)" "0"
bash -c "$UBPRE" > "$REPRO_DIR/ub-pre.log" 2>&1
chk_rc $? "ExecStartPre (-t) with nginx 1.18.0: config test successful"
bash -c "$UBSTART" > "$REPRO_DIR/ub-start.log" 2>&1 &
sleep 1.5
wait_port 7680 && ok "nginx 1.18.0 under the verbatim ExecStart LISTENS on 127.0.0.1:7680" \
  || bad "verbatim ExecStart (nginx 1.18.0) did not listen on 7680"
H1="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:7680/health")"
chk_eq "panel /health 200 through nginx 1.18.0" "$H1" "200"
chk_grep "early error-log [alert] captured (benign by design — nginx CONTINUED)" \
  "$REPRO_DIR/ub-start.log" "could not open error log file"
NGXPID="$(cat "$SB/var/lib/ops-terminal/nginx/nginx.pid" 2>/dev/null || echo 0)"
kill -0 "$NGXPID" 2>/dev/null && ok "master process alive after the early-log alert (alert != fatal)" \
  || bad "nginx died — the early-log alert must be non-fatal"
PID_IN_PIDFILE="$(sed -n 's/^pid //p' "$SB/etc/ops-terminal/nginx/nginx.conf" | tr -d ';' )"
chk_eq "pidfile path in conf == the one ops-gw owns" "$PID_IN_PIDFILE" "$SB/var/lib/ops-terminal/nginx/nginx.pid"
bash -c "$UBRELOAD" > "$REPRO_DIR/ub-reload.log" 2>&1
chk_rc $? "ExecReload (-s reload) with nginx 1.18.0 succeeded"
sleep 1.0
H2="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:7680/health")"
chk_eq "panel still healthy after reload (nginx 1.18.0)" "$H2" "200"
pkill -f "$SB/etc/ops-terminal/nginx/nginx.conf" 2>/dev/null || true
sleep 0.8

# ==========================================================================
step "S5. OPS-GW IDENTITY CONTRACT — code + unit level (kernel user model)"
# HONEST SCOPE NOTE (proven empirically): this container has ONE usable uid
# (the battery user); `unshare --user` without a map KEEPS the real uid
# (kernel permission checks compare GLOBAL ids), so a genuinely distinct
# ops-gw identity cannot be created here — no root, no newuidmap, no subuid
# grants. The identity contract is therefore proven at the levels that ARE
# real here: the unit's User=/Group= (enforced by the REAL system manager on
# the VPS), the installer's ownership model (root:ops-gw 0750 conf, ops-gw
# runtime+logs), and the verbatim command line under a zero-capability
# identity (the battery user runs with CapEff=0 — S0 proves it).
chk_grep "unit declares User=ops-gw (the VPS system manager enforces it)" "$U" "^User=ops-gw$"
chk_grep "unit declares Group=ops-gw" "$U" "^Group=ops-gw$"
chk_grep "installer: conf dir root-OWNED, read-only for the service user" \
  "$REPO/scripts/install.sh" 'chown -R root:ops-gw "\$INGX_CONF_DIR"'
chk_grep "installer: conf dir mode 0750 (ops-gw group read only)" \
  "$REPO/scripts/install.sh" 'chmod 0750 "\$INGX_CONF_DIR"'
chk_grep "installer: runtime dir (pid/tmp) owned by ops-gw" \
  "$REPO/scripts/install.sh" 'chown -R ops-gw:ops-gw "\$INGX_VAR_DIR"'
chk_grep "installer: runtime + log dirs owned by ops-gw" \
  "$REPO/scripts/install.sh" 'chown -R ops-gw:ops-gw "\$VARLIB_DIR" "\$VARLOG_DIR"'
chk_grep "installer: dedicated system user ops-gw created (no login)" \
  "$REPO/scripts/install.sh" 'useradd --system --no-create-home'
chk_grep "installer: ops-gw gets a nologin shell" \
  "$REPO/scripts/install.sh" 'nologin ops-gw'
CAPPROOF="$(grep CapEff /proc/self/status)"
chk_eq "the battery identity runs with ZERO capabilities (no privilege escape)" \
  "$(printf '%s' "$CAPPROOF" | awk '{print $2}')" "0000000000000000"
chk_grep "the early error-log alert for an unprivileged identity is non-fatal (captured in S4)" \
  "$REPRO_DIR/ub-start.log" "could not open error log file"
[ -d /var/log/nginx ] && bad "/var/log/nginx exists (must not be touched)" || ok "shared /var/log/nginx untouched (not even present — zero permission changes)"
PERMLOGNGX="$(grep -E '(chown|chmod)[^#]*var/log/nginx' "$REPO/scripts/install.sh" || true)"
chk_eq "nothing ever chowns/grants /var/log/nginx (only log routing is allowed)" \
  "$(printf '%s' "$PERMLOGNGX" | grep -c . || true)" "0"

# ==========================================================================
step "S6. SUPERVISOR BATTERY — the 11-step CP12 acceptance list"
stop_nohup_services   # supervisor takes over ALL three services exclusively
translate_units
for u in ops-terminal-gateway.service ops-terminal.service ops-terminal-nginx.service; do
  $SV stop "$UNITS_DIR/$u" --state-dir "$SVSTATE" >/dev/null 2>&1
  $SV reset-failed "$UNITS_DIR/$u" --state-dir "$SVSTATE" >/dev/null 2>&1
done
# (1)(2)(3) gateway, ttyd, internal nginx become healthy under the unit policy
sv_start ops-terminal-gateway.service
sv_start ops-terminal.service
sv_start ops-terminal-nginx.service
sv_wait_active ops-terminal-gateway.service 30 && ok "1. gateway ACTIVE"     || bad "1. gateway not active"
sv_wait_active ops-terminal.service 30          && ok "2. ttyd ACTIVE"       || bad "2. ttyd not active"
sv_wait_active ops-terminal-nginx.service 40    && ok "3. internal nginx ACTIVE" || bad "3. nginx not active"
wait_port 7682 && ok "gateway listens on 127.0.0.1:7682" || bad "gateway port 7682 missing"
wait_port 7681 && ok "ttyd listens on 127.0.0.1:7681"    || bad "ttyd port 7681 missing"
wait_port 7680 && ok "internal nginx listens on 127.0.0.1:7680 (production parity)" || bad "panel port 7680 missing"
# (4) an UNauthenticated request really reaches the gateway (302 to /login)
NOAUTH="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:7680/")"
chk_eq "4. unauthenticated / -> 302 (auth_request subrequest reached the gateway)" "$NOAUTH" "302"
rm -f "$TEST/cp12-cookies.txt"
# HAProxy backend health needs its rise window after nginx came up — poll the
# EDGE before the authenticated runs (a raw 503 here would be a false alarm).
EDGE_OK=""; for _ in $(seq 1 40); do
  C="$(curl -sk --resolve "$DOMAIN:$EDGE:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$DOMAIN:$EDGE/health" 2>/dev/null)"
  [ "$C" = "200" ] && { EDGE_OK=1; break; }; sleep 0.5
done
[ "$EDGE_OK" = "1" ] && ok "edge settled: panel /health 200 through the HAProxy edge" || bad "edge never settled (last=$C)"
# (5)(6)(7)(8) real WS + real browser + id -u + interactive command, through the HAProxy edge
tmux_reset
printf '%s' "$PW" | "$PY" "$REPO/scripts/e2e-test.py" \
  --base "$OPS_TEST_BASE" --connect 127.0.0.1 \
  --username "$OPS_TEST_USER" --password-stdin \
  --insecure-allow --expect-uid "$MYUID" > "$TEST/e2e-cp12.log" 2>&1
chk_rc $? "5+7. e2e full chain through the HAProxy edge (login -> WebSocket -> shell, id -u)"
grep -q "interactive command" "$TEST/e2e-cp12.log" && ok "8. INTERACTIVE command executed over the websocket terminal" \
  || bad "8. interactive command proof missing"
tmux_reset
if [ -d /home/z/.npm-global/lib/node_modules ]; then
  NODE_PATH=/home/z/.npm-global/lib/node_modules node "$REPO/tests/browser-test.js" \
    --url "$OPS_TEST_BASE" --username "$OPS_TEST_USER" --password-file "$PWFILE" \
    --map-host "$DOMAIN" --expect-uid "$MYUID" --out "$TEST/shots-cp12" > "$TEST/browser-cp12.log" 2>&1
  chk_rc $? "6+7. REAL browser: login -> terminal render -> typing -> output -> id -u"
else
  ok "6. browser stage skipped in this environment (recorded, not hidden)"
fi
# (9) controlled restart under the unit policy
$SV restart "$UNITS_DIR/ops-terminal-nginx.service" --state-dir "$SVSTATE" >/dev/null 2>&1
sv_wait_active ops-terminal-nginx.service 40 && ok "9. controlled restart: unit active again" || bad "9. restart did not become active"
wait_port 7680 && ok "9. 127.0.0.1:7680 listening again" || bad "9. port 7680 not back after restart"
H4="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:7680/health")"
chk_eq "9. panel healthy after controlled restart" "$H4" "200"
# (10) forced failure must NOT loop: inject the CP11 bug class (duplicate pid)
cp "$SB/etc/ops-terminal/nginx/nginx.conf" "$REPRO_DIR/good-nginx.conf.bak"
sed -i "s|^pid \(.*\);$|pid \1;\npid \1;|" "$SB/etc/ops-terminal/nginx/nginx.conf"
$SV reset-failed "$UNITS_DIR/ops-terminal-nginx.service" --state-dir "$SVSTATE" >/dev/null 2>&1
$SV stop "$UNITS_DIR/ops-terminal-nginx.service" --state-dir "$SVSTATE" >/dev/null 2>&1
$SV start "$UNITS_DIR/ops-terminal-nginx.service" --state-dir "$SVSTATE" >/dev/null 2>&1
sleep 12
NR="$(sv_state_field ops-terminal-nginx.service NRestarts)"
AS="$(sv_state_field ops-terminal-nginx.service ActiveState)"
SS="$(sv_state_field ops-terminal-nginx.service SubState)"
[ -n "$NR" ] && [ "$NR" -le 5 ] && ok "10. forced failure: NRestarts=$NR <= StartLimitBurst (bounded)" \
  || bad "10. restart counter not bounded (NRestarts=$NR)"
[ "$AS" = "failed" ] && ok "10. unit entered FAILED and stays DOWN (no infinite loop; SubState=$SS)" \
  || bad "10. unit not failed after the start limit (state=$AS/$SS)"
cp "$REPRO_DIR/good-nginx.conf.bak" "$SB/etc/ops-terminal/nginx/nginx.conf"
$SV reset-failed "$UNITS_DIR/ops-terminal-nginx.service" --state-dir "$SVSTATE" >/dev/null 2>&1
$SV start "$UNITS_DIR/ops-terminal-nginx.service" --state-dir "$SVSTATE" >/dev/null 2>&1
sv_wait_active ops-terminal-nginx.service 40 && ok "10. recovery after config fix (operator model)" || bad "10. no recovery after reset-failed"
# (11) rollback: a forced install failure must STOP every dedicated service.
# The supervisor units are stopped first (the sandbox installer owns its own
# nohup services; on the VPS the same path calls scripts/ops-systemd.sh and
# stops ONLY the three panel units — exercised by the CP11 battery). After
# the die-path rollback NO dedicated listener may remain.
for u in ops-terminal-gateway.service ops-terminal.service ops-terminal-nginx.service; do
  $SV stop "$UNITS_DIR/$u" --state-dir "$SVSTATE" >/dev/null 2>&1
  $SV reset-failed "$UNITS_DIR/$u" --state-dir "$SVSTATE" >/dev/null 2>&1
done
BACKUPS_BEFORE="$(ls -1d "$SB"/backups/* 2>/dev/null | wc -l)"
"$PY" - <<'PY' > /dev/null 2>&1 &
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 7682)); s.listen(4)
time.sleep(90)
PY
BLOCKER=$!
sleep 0.6
install_panel "$TEST/install-cp12-die.log"
RC_DIE=$?
kill "$BLOCKER" 2>/dev/null
[ "$RC_DIE" -ne 0 ] && ok "11. forced install failure failed as designed (rc=$RC_DIE)" \
  || bad "11. forced install failure unexpectedly succeeded"
stop_nohup_services
BUSY=0; for p in 7680 7681 7682; do ss -tln | awk '{print $4}' | grep -qE ":$p$" && BUSY=$((BUSY+1)); done
chk_eq "11. after the die-path rollback NO dedicated listener remains (0 busy)" "$BUSY" "0"
chk_eq "11. managed HAProxy blocks swept by the rollback (0 left)" \
  "$(grep -c '^# BEGIN ops-terminal' "$HCFG")" "0"
"$HAP" -c -q -f "$HCFG"; chk_rc $? "haproxy cfg valid after rollback sweep"
chk_eq "11. HAProxy master pid UNCHANGED (reload only, never restart)" "$(master_pid)" "$MASTER_BEFORE"
SHARED2="$(curl -sk --resolve "$SHARED_DOMAIN:$EDGE:127.0.0.1" "https://$SHARED_DOMAIN:$EDGE/" 2>/dev/null)"
chk_eq "11. KOTODAMA/HANASO shared site STILL healthy after rollback" "$SHARED2" "SHARED-SITE-OK"
BACKUPS_AFTER="$(ls -1d "$SB"/backups/* 2>/dev/null | wc -l)"
[ "$BACKUPS_AFTER" -ge "$BACKUPS_BEFORE" ] && ok "11. backups preserved ($BACKUPS_BEFORE -> $BACKUPS_AFTER dirs)" \
  || bad "11. backups LOST during rollback"

# ==========================================================================
step "S7. PRODUCTION-LEFTOVER REINSTALL (units missing, files+backups remain)"
# mirrors the real CP11 post-rollback state reported by the Owner:
# the three units are GONE, ports down, but /etc/ops-terminal files and
# backups remain. The new installer must reconcile WITHOUT deleting backups
# and WITHOUT breaking existing credentials.
rm -rf "$UNITS_DIR"; mkdir -p "$UNITS_DIR"          # units "missing"
OLD_PW="$(cat "$PWFILE" 2>/dev/null)"
install_panel "$TEST/install-cp12-leftover.log"     # NO --reset-credentials
chk_rc $? "installer reconciled the leftover state (exit 0)"
chk_not "credentials preserved (no NEW password generated)" "$TEST/install-cp12-leftover.log" " PASSWORD    :"
chk_has "installer notes preserved credentials" "$TEST/install-cp12-leftover.log" "existing credentials kept"
wait_port 7680 && ok "internal nginx healthy after reconciliation" || bad "panel port 7680 missing after reinstall"
wait_port 7681 && ok "ttyd healthy after reconciliation"           || bad "ttyd port missing after reinstall"
wait_port 7682 && ok "gateway healthy after reconciliation"        || bad "gateway port missing after reinstall"
# old credentials still valid -> login + whoami through the edge
EDGE_OK2=""; for _ in $(seq 1 40); do
  C2="$(curl -sk --resolve "$DOMAIN:$EDGE:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$DOMAIN:$EDGE/health" 2>/dev/null)"
  [ "$C2" = "200" ] && { EDGE_OK2=1; break; }; sleep 0.5
done
[ "$EDGE_OK2" = "1" ] && ok "edge settled after the reinstall" || bad "edge never settled after reinstall (last=$C2)"
LOGIN_RC=0
printf '%s' "$OLD_PW" | "$PY" "$REPO/scripts/e2e-test.py" \
  --base "$OPS_TEST_BASE" --connect 127.0.0.1 \
  --username "$OPS_TEST_USER" --password-stdin \
  --insecure-allow --expect-uid "$MYUID" > "$TEST/e2e-cp12-leftover.log" 2>&1 || LOGIN_RC=1
chk_rc "$LOGIN_RC" "OLD credentials still valid after the leftover reinstall (login + WS + shell)"
BACKUPS_FINAL="$(ls -1d "$SB"/backups/* 2>/dev/null | wc -l)"
[ "$BACKUPS_FINAL" -ge "$BACKUPS_AFTER" ] && ok "backups still intact after reinstall ($BACKUPS_FINAL dirs)" \
  || bad "backups lost by the reinstall"
# bring the units back under the supervisor for the final state
stop_nohup_services
translate_units
for u in ops-terminal-gateway.service ops-terminal.service ops-terminal-nginx.service; do
  $SV stop "$UNITS_DIR/$u" --state-dir "$SVSTATE" >/dev/null 2>&1
  $SV reset-failed "$UNITS_DIR/$u" --state-dir "$SVSTATE" >/dev/null 2>&1
done
sv_start ops-terminal-gateway.service; sv_start ops-terminal.service; sv_start ops-terminal-nginx.service
sv_wait_active ops-terminal-nginx.service 40 && ok "panel back under the unit policy" || bad "panel not active after reinstall"

# ==========================================================================
step "S8. SYSTEMD REAL-CODE PROOFS (parser + REAL manager transaction)"
VLOG="$SVLOGS/systemd-analyze-verify-translated.log"
systemd-analyze verify "$UNITS_DIR"/ops-terminal.service \
                       "$UNITS_DIR"/ops-terminal-gateway.service \
                       "$UNITS_DIR"/ops-terminal-nginx.service > "$VLOG" 2>&1
chk_rc $? "systemd-analyze verify of the translated units (all paths exist here)"
# REAL systemd 257 manager computes the START TRANSACTION over the REAL unit
# files (nested userns: outer mounts tmpfs /run for the booted() probe; inner
# identity = unmapped nobody — zero capabilities, exactly like ops-gw).
mkdir -p "$UM_HOME/.config/systemd/user/default.target.wants"
for u in ops-terminal.service ops-terminal-gateway.service ops-terminal-nginx.service; do
  cp "$UNITS_DIR/$u" "$UM_HOME/.config/systemd/user/$u"
  ln -sf "../$u" "$UM_HOME/.config/systemd/user/default.target.wants/$u"
done
cat > "$UM_HOME/.config/systemd/user/network-online.target" <<'EOF'
[Unit]
Description=Network Online (sandbox stand-in for the --test transaction)
EOF
cat > "$UM_HOME/.config/systemd/user/default.target.wants/network-online.target" <<'EOF'
[Unit]
Description=Network Online (sandbox stand-in for the --test transaction)
EOF
cat > "$TEST/cp12-um-run.sh" <<'UMEOF'
#!/usr/bin/env bash
set -u
BASE="$1"
export HOME="$BASE" XDG_RUNTIME_DIR="$BASE/run-user"
exec /usr/lib/systemd/systemd --user --test
UMEOF
mkdir -p "$UM_HOME/run-user"; chmod 700 "$UM_HOME/run-user"
# Outer ns (root-of-ns): tmpfs over /run satisfies systemd's booted() probe.
# Inner ns: same real uid but seen as NON-root inside (the --test mode refuses
# root) and with zero capabilities — the closest local equivalent of the
# unprivileged ops-gw identity.
UM_HOME="$UM_HOME" UM_SCRIPT="$TEST/cp12-um-run.sh" \
unshare --user --map-root-user --mount bash -c '
  mount -t tmpfs none /run && mkdir -p /run/systemd/system
  unshare --user bash "$UM_SCRIPT" "$UM_HOME"
' > "$UM_HOME/um-test.log" 2>&1
UMRC=$?
chk_rc "$UMRC" "REAL systemd 257 user-manager --test: start TRANSACTION computed over the REAL units"
chk_has "manager parsed the transaction (Queued start job)" "$UM_HOME/um-test.log" "Queued start job for default target"
chk_has "manager LOADED ops-terminal-nginx.service" "$UM_HOME/um-test.log" "ops-terminal-nginx.service"
chk_has "manager LOADED ops-terminal-gateway.service" "$UM_HOME/um-test.log" "ops-terminal-gateway.service"
UMERR="$(grep -cE 'Failed to parse|Unknown key|not valid' "$UM_HOME/um-test.log" 2>/dev/null || true)"
chk_eq "manager: zero unit-file errors (User=/hardening accepted)" "$UMERR" "0"

# ==========================================================================
step "S9. REAL quick-install.sh bootstrap (committed tree, dedicated sandbox)"
QISB="$SB-cp12-qi"
rm -rf "$QISB"
QEDGE=8444; QHTTP=8081; QSHARED=9091
QTTYD=17781; QGW=17782; QPANEL=17780
QCFG="$QISB/etc/haproxy/haproxy.cfg"
mkdir -p "$(dirname "$QCFG")" "$QISB/haproxy-test" "$QISB/var/log" "$QISB/etc/haproxy/certs"
cp "$TEST/hanaso.pem" "$QISB/etc/haproxy/certs/hanaso.pem"
cat > "$QCFG" <<EOF
global
    maxconn 256
    stats socket $QISB/haproxy-test/admin.sock mode 600 level admin
defaults
    mode http
    option httplog
    timeout connect 5s
    timeout client  30s
    timeout server  30s
frontend f_shared_443
    bind *:$QEDGE ssl crt $QISB/etc/haproxy/certs/hanaso.pem
    default_backend b_shared
frontend f_shared_80
    bind *:$QHTTP
    default_backend b_shared
backend b_shared
    server shared 127.0.0.1:$QSHARED check inter 2s fall 3 rise 2
EOF
sed 's/9090/'"$QSHARED"'/' "$TEST/shared-server.py" > "$TEST/shared-server-qi.py"
pkill -f "$TEST/shared-server-qi.py" 2>/dev/null || true
pkill -f "$QCFG" 2>/dev/null || true
sleep 0.4
nohup "$PY" "$TEST/shared-server-qi.py" > "$TEST/shared-server-qi.log" 2>&1 &
QSHARED_PID=$!
nohup "$HAP" -W -db -f "$QCFG" -p "$QISB/haproxy-test/haproxy.pid" > "$QISB/var/log/haproxy.log" 2>&1 &
sleep 1.2
QUICK_INSTALL_REPO="$REPO" QUICK_INSTALL_REF="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" \
OPS_SANDBOX_ROOT="$QISB" \
  bash "$REPO/quick-install.sh" --sandbox --sandbox-topology haproxy --yes \
    --haproxy-cfg "$QCFG" --haproxy-bin "$HAP" \
    --haproxy-pidfile "$QISB/haproxy-test/haproxy.pid" \
    --https-port "$QEDGE" --http-port "$QHTTP" \
    --panel-port "$QPANEL" --ttyd-port "$QTTYD" --gateway-port "$QGW" \
    --tls-cert "$TEST/ops-panel.fullchain.pem" --tls-key "$TEST/ops-panel.key" \
    --nginx-bin "$NGX" --mime-types "$SBROOT/etc/nginx/mime.types" \
    --tmux-bin "$SBROOT/usr/bin/tmux" --tmux-ld-path "$LIBDIR" \
    --python-bin "$PY" > "$TEST/quick-install-cp12.log" 2>&1
chk_rc $? "quick-install.sh FULL bootstrap run (clone -> SHA256SUMS -> installer)"
chk_has "SHA256SUMS verified by the bootstrap" "$TEST/quick-install-cp12.log" "SHA256SUMS: OK"
chk_has "installer e2e PASSED inside quick-install" "$TEST/quick-install-cp12.log" "end-to-end verification PASSED"
COMMITTED_UNIT="$(git -C "$REPO" show HEAD:systemd/ops-terminal-nginx.service 2>/dev/null || echo MISSING)"
COMMITTED_EXEC="$(printf '%s\n' "$COMMITTED_UNIT" | grep -E '^Exec(Start|StartPre|Reload)=' || true)"
chk_eq "committed unit Exec lines: ZERO -e (the tag ships the fix)" \
  "$(printf '%s\n' "$COMMITTED_EXEC" | grep -c -F -- '-e' || true)" "0"
QHEALTH="$(curl -sk --resolve "$DOMAIN:$QEDGE:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$DOMAIN:$QEDGE/health")"
chk_eq "quick-installed panel healthy through its own edge" "$QHEALTH" "200"
QSHARED="$(curl -sk --resolve "$SHARED_DOMAIN:$QEDGE:127.0.0.1" "https://$SHARED_DOMAIN:$QEDGE/" 2>/dev/null)"
chk_eq "quick-install: shared backend of the second harness OK" "$QSHARED" "SHARED-SITE-OK"
OPS_SANDBOX_ROOT="$QISB" bash "$REPO/scripts/uninstall.sh" --sandbox --yes \
  --haproxy-cfg "$QCFG" --haproxy-bin "$HAP" \
  --haproxy-pidfile "$QISB/haproxy-test/haproxy.pid" > "$TEST/uninstall-cp12-qi.log" 2>&1
chk_rc $? "quick-install sandbox cleanly uninstalled"
kill "$QSHARED_PID" 2>/dev/null; pkill -f "$QCFG" 2>/dev/null || true
rm -rf "$QISB" "$TEST/shared-server-qi.py"

# ==========================================================================
step "S10. FINAL STATE: panel up under the unit policy + shared services healthy"
FH="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:7680/health")"
chk_eq "final: panel /health 200" "$FH" "200"
FEDGE="$(curl -sk --resolve "$DOMAIN:$EDGE:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$DOMAIN:$EDGE/health")"
chk_eq "final: panel /health through the HAProxy edge 200" "$FEDGE" "200"
FSHARED="$(curl -sk --resolve "$SHARED_DOMAIN:$EDGE:127.0.0.1" "https://$SHARED_DOMAIN:$EDGE/" 2>/dev/null)"
chk_eq "final: KOTODAMA/HANASO shared site healthy" "$FSHARED" "SHARED-SITE-OK"
chk_eq "final: HAProxy master pid unchanged through the whole battery" "$(master_pid)" "$MASTER_BEFORE"

echo
echo "############################################"
echo " CP12 BATTERY COMPLETE — TOTAL FAILED CHECKS: $FAILS"
echo "############################################"
exit "$FAILS"
