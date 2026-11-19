#!/usr/bin/env bash
# ==========================================================================
# CP v1.3.1 battery — APT Mirror Discovery & Fallback engine.
# Runs INSIDE the clean Ubuntu 24.04 VM (see tests/cp-mirror-run.sh).
#
#   cp-mirror-battery.sh <scenario>
#     M1  incident replay: EMPTY sources + EMPTY index -> engine rewrites via
#         a validated mirror -> nginx+certbot install -> SUCCESS
#     M2  primary mirror DEAD -> second mirror selected -> SUCCESS
#     M3  mirror responds but index INCOMPLETE (no universe) -> rejected,
#         next mirror selected -> SUCCESS
#     M4  mirror serves TAMPERED InRelease -> apt signature validation
#         rejects it -> next mirror selected -> SUCCESS
#     M5  current config has universe DISABLED (main only) -> rejected,
#         rewrite adds universe -> SUCCESS
#     M6  DNS-broken mirror + TLS-broken mirror -> both rejected with exact
#         reasons -> next mirror selected -> SUCCESS
#     M7  ALL mirrors fail -> fail-closed: rc!=0, sources untouched, nothing
#         installed, per-mirror reasons recorded
#     M8  deb822 (ubuntu.sources) system: engine disables ONLY the Ubuntu
#         stanza file and writes a deb822 replacement -> SUCCESS
#     MA  natural full install regression (no forced mirrors; current config
#         passes) + auth_request LIVE proof + e2e
#
# Mock mirrors (signed with a TEST key installed into the VM apt keyrings —
# apt-secure stays fully ON; the engine never writes trusted=yes):
#   http://127.0.0.1:8081/ubuntu  m1         full, valid
#   http://127.0.0.1:8082/ubuntu  m2         full, valid
#   http://127.0.0.1:8083/ubuntu  nouniverse main only
#   http://127.0.0.1:8084/ubuntu  badsig     tampered InRelease
#   https://127.0.0.1:8086/ubuntu tls-broken wrong-domain cert (curl rc=60)
#   http://127.0.0.1:1/ubuntu     dead       connection refused
#   http://dns-dead.test.invalid  dns        resolver failure
# ==========================================================================
set -u
SC="${1:-M1}"
REPO=/root/hanaso-ops-terminal
EV=/mnt/shared/evidence
LOGDIR=/root/cp13-logs
MOCKS=/opt/cp-mirrors
DOMAIN=ops.hanaso.ir
export REPO EV LOGDIR DOMAIN SC MOCKS
mkdir -p "$EV" "$LOGDIR"
PASS=0; FAIL=0; CUR="-"
echo "cp-mirror battery scenario $SC — $(date -u +%FT%TZ)" > "$EV/cpm-$SC.log"

pass() { PASS=$((PASS+1)); printf '  [PASS] %s/%s\n' "$CUR" "$1" >> "$EV/cpm-$SC.log"; }
fail() { FAIL=$((FAIL+1)); printf '  [FAIL] %s/%s\n' "$CUR" "$1" >> "$EV/cpm-$SC.log"; }
step() { CUR="$1"; printf '[step %s] %s\n' "$SC" "$1" >> "$EV/cpm-$SC.log"; }
assert() { local n="$1"; shift; if "$@" >>"$LOGDIR/$SC-assert.log" 2>&1; then pass "$n"; else fail "$n"; printf '    ^ cmd: %s\n' "$*" >> "$EV/cpm-$SC.log"; fi; }
chk_eq() { local n="$1" want="$2" got="$3"; if [ "$want" = "$got" ]; then pass "$n"; else fail "$n (want=$want got=$got)"; fi; }

M1=http://127.0.0.1:8081/ubuntu
M2=http://127.0.0.1:8082/ubuntu
MNU=http://127.0.0.1:8083/ubuntu
MBS=http://127.0.0.1:8084/ubuntu
MTLS=https://127.0.0.1:8086/ubuntu
MDEAD=http://127.0.0.1:1/ubuntu
MDNS=http://dns-dead.test.invalid/ubuntu

# ----------------------------------------------------------------- harness --
start_mirrors() {
  # signed mock mirrors + tls-broken server, INSIDE the VM netns
  pkill -f "cp-mirror-http" 2>/dev/null || true
  sleep 0.4
  python3 -c "
import http.server, socketserver, functools, ssl, os, threading
root='$MOCKS'
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
srvs=[]
for port, doc in ((8081,'m1'),(8082,'m2'),(8083,'nouniverse'),(8084,'badsig')):
    h=functools.partial(H, directory=os.path.join(root,doc))
    s=socketserver.ThreadingTCPServer(('127.0.0.1',port),h)
    s.allow_reuse_address=True
    t=threading.Thread(target=s.serve_forever,daemon=True); t.start(); srvs.append(s)
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(os.path.join(root,'tls-broken','cert.pem'),os.path.join(root,'tls-broken','key.pem'))
h=functools.partial(H, directory=os.path.join(root,'m1'))
s=socketserver.ThreadingTCPServer(('127.0.0.1',8086),h)
s.allow_reuse_address=True
s.socket=ctx.wrap_socket(s.socket,server_side=True)
t=threading.Thread(target=s.serve_forever,daemon=True); t.start(); srvs.append(s)
import time
print('cp-mirror-http up',flush=True)
time.sleep(3600)
" > /tmp/cp-mirror-http.log 2>&1 &
echo $! > /tmp/cp-mirror-http.pid
  sleep 1.2
  for p in 8081 8082 8083 8084; do
    curl -fsS -m 3 -o /dev/null "http://127.0.0.1:$p/ubuntu/dists/noble/InRelease" || { echo "mirror :$p NOT UP"; return 1; }
  done
  echo "mirrors UP"
}

stop_mirrors() { [ -f /tmp/cp-mirror-http.pid ] && kill "$(cat /tmp/cp-mirror-http.pid)" 2>/dev/null || true; pkill -f "cp-mirror-http" 2>/dev/null || true; sleep 0.3; }

reset_apt_fresh() {
  # fresh-server apt state: flat mirror config (like the CP13 image), purge
  # panel packages, drop the mirror engine's files
  # ALWAYS re-sync the repo clone to the CURRENT snapshot first
  if [ -d /root/hanaso-ops-terminal/.git ]; then
    git -C /root/hanaso-ops-terminal fetch -q origin 2>/dev/null || true
    git -C /root/hanaso-ops-terminal reset --hard -q FETCH_HEAD 2>/dev/null || {
      rm -rf /root/hanaso-ops-terminal
      git clone -q /mnt/shared/repo.git /root/hanaso-ops-terminal; }
  else
    git clone -q /mnt/shared/repo.git /root/hanaso-ops-terminal
  fi
  # minimal VM base lacks the dirs a real systemd server always has
  mkdir -p /usr/local/bin /usr/libexec \
           /etc/systemd/system /etc/systemd/system/multi-user.target.wants \
           /etc/logrotate.d /etc/apt/preferences.d /var/backups /var/log/apt
  cp "$REPO/tests/cp13-systemctl-shim.sh" /usr/bin/systemctl && chmod 0755 /usr/bin/systemctl
  cp "$REPO/tests/cp11-supervisor.py" /usr/libexec/cp13-supervisor.py 2>/dev/null || true
  pkill -f "cp13-supervisor" 2>/dev/null || true
  pkill -f "/opt/ops-terminal" 2>/dev/null || true
  sleep 0.5
  DEBIAN_FRONTEND=noninteractive apt-get purge -y nginx nginx-common nginx-core certbot python3-certbot >>"$LOGDIR/purge.log" 2>&1 || true
  rm -rf /etc/ops-terminal /opt/ops-terminal /var/lib/ops-terminal /var/log/ops-terminal \
         /var/tmp/ops-terminal /run/ops-terminal /var/www/ops-terminal /var/backups/ops-terminal \
         /etc/letsencrypt /usr/local/bin/ops-terminal-passwd /etc/logrotate.d/ops-terminal
  rm -f /etc/systemd/system/ops-terminal-* /etc/apt/sources.list.d/00-hanaso-mirror.* \
        /etc/apt/sources.list.d/*.disabled-by-ops-terminal /root/cp13-pw.txt
  printf 'deb [trusted=yes] file:/opt/mirror ./\n' > /etc/apt/sources.list
  rm -rf /var/lib/apt/lists/*; mkdir -p /var/lib/apt/lists/partial
  apt-get update >>"$LOGDIR/purge.log" 2>&1 || true
  hash -r
}

assert_no_panel_packages() {
  if dpkg -l nginx 2>/dev/null | grep -q "^ii"; then return 1; fi
  if dpkg -l certbot 2>/dev/null | grep -q "^ii"; then return 1; fi
  if dpkg -l nginx-core 2>/dev/null | grep -q "^ii"; then return 1; fi
  return 0
}

installer() { # <logfile> [args...] -> runs the REAL installer
  local out="$1"; shift
  bash "$REPO/scripts/install.sh" --yes "$@" >"$out" 2>&1
  local rc=$?
  sed -n 's/^ PASSWORD    : //p' "$out" | head -1 > /tmp/cpm-pw.new
  if [ -s /tmp/cpm-pw.new ]; then mv /tmp/cpm-pw.new /root/cp13-pw.txt; else rm -f /tmp/cpm-pw.new; fi
  chmod 0600 /root/cp13-pw.txt 2>/dev/null || true
  return $rc
}

acme_args() {
  # drive the PRODUCTION ACME branch with the CP13 stub certbot so the
  # engine must provide a certbot CANDIDATE (mission scenario core)
  OPS_STUB_HTTP80=80 OPS_STUB_CA_DIR=/root/cp13-ca OPS_STUB_LIVE_BASE=/etc/letsencrypt \
  bash "$REPO/scripts/install.sh" --yes --domain "$DOMAIN" --server-ip 127.0.0.1 \
    --tls-mode acme --simulate-acme --certbot-bin "$REPO/tests/stub-certbot.sh" "$@"
}

acme_env() { echo "OPS_STUB_HTTP80=80 OPS_STUB_CA_DIR=/root/cp13-ca OPS_STUB_LIVE_BASE=/etc/letsencrypt"; }

# runs the installer WITH mirror-engine overrides (env(1): assignments must be
# real argv words — "$(cmd)" output is NOT re-parsed as assignments)
run_install() { # <logfile> <forced-mirrors|""> [extra args...]
  local out="$1" forced="$2"; shift 2
  if [ -n "$forced" ]; then
    env OPS_APT_FORCE_MIRRORS="$forced" OPS_STUB_HTTP80=80 OPS_STUB_CA_DIR=/root/cp13-ca \
      OPS_STUB_LIVE_BASE=/etc/letsencrypt \
      bash "$REPO/scripts/install.sh" --yes \
      --domain "$DOMAIN" --server-ip 127.0.0.1 --tls-mode acme \
      --simulate-acme --certbot-bin "$REPO/tests/stub-certbot.sh" "$@" >"$out" 2>&1
  else
    env OPS_STUB_HTTP80=80 OPS_STUB_CA_DIR=/root/cp13-ca \
      OPS_STUB_LIVE_BASE=/etc/letsencrypt \
      bash "$REPO/scripts/install.sh" --yes \
      --domain "$DOMAIN" --server-ip 127.0.0.1 --tls-mode acme \
      --simulate-acme --certbot-bin "$REPO/tests/stub-certbot.sh" "$@" >"$out" 2>&1
  fi
  local rc=$?
  sed -n 's/^ PASSWORD    : //p' "$out" | head -1 > /tmp/cpm-pw.new
  if [ -s /tmp/cpm-pw.new ]; then mv /tmp/cpm-pw.new /root/cp13-pw.txt; else rm -f /tmp/cpm-pw.new; fi
  chmod 0600 /root/cp13-pw.txt 2>/dev/null || true
  return $rc
}

setup_acme_stub() {
  mkdir -p /root/cp13-ca /usr/local/share/ca-certificates
  if [ ! -s /root/cp13-ca/ca.crt ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 -sha256 \
      -keyout /root/cp13-ca/ca.key -out /root/cp13-ca/ca.crt \
      -subj "/CN=CP13 Stub CA" -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
  fi
  cp /root/cp13-ca/ca.crt /usr/local/share/ca-certificates/cp13-stub-ca.crt
  update-ca-certificates >/dev/null 2>&1
}

install_test_key() {
  # VM-only: trust the mock-mirror TEST key in BOTH apt keyring locations
  # (.list style reads /etc/apt/trusted.gpg.d; the deb822 Signed-By pins the
  # ubuntu keyring file, which the merge below extends)
  cp "$MOCKS/cp-mirror-test-key.gpg" /etc/apt/trusted.gpg.d/cp-mirror-test-key.gpg
  chmod 0644 /etc/apt/trusted.gpg.d/cp-mirror-test-key.gpg
  if ! gpg --no-default-keyring --keyring /usr/share/keyrings/ubuntu-archive-keyring.gpg --list-keys "cp-mirror-test" >/dev/null 2>&1; then
    cp -a /usr/share/keyrings/ubuntu-archive-keyring.gpg /root/ubuntu-keyring.orig.gpg
    cat /usr/share/keyrings/ubuntu-archive-keyring.gpg "$MOCKS/cp-mirror-test-key.gpg" \
      > /usr/share/keyrings/ubuntu-archive-keyring.merged.gpg \
      && mv /usr/share/keyrings/ubuntu-archive-keyring.merged.gpg \
            /usr/share/keyrings/ubuntu-archive-keyring.gpg
  fi
}

# assertions on the engine report inside an install log
grep_engine() { grep "^\[apt-mirror\]" "$1" 2>/dev/null; }
assert_selected() { grep_engine "$1" | grep -q "SELECT\|selected mirror: $2"; }
assert_reject_reason() { grep_engine "$1" | grep -q "REJECT reason=.*$2"; }

latest_backup_dir() { ls -1d /var/backups/ops-terminal/* 2>/dev/null | sort | tail -1; }

e2e_run() {
  command -v python3 >/dev/null || return 1
  TMUX_TMPDIR=/var/tmp/ops-terminal tmux kill-server 2>/dev/null || true
  [ -s /root/cp13-pw.txt ] || return 1
  printf '%s' "$(cat /root/cp13-pw.txt)" | python3 "$REPO/scripts/e2e-test.py" \
    --base "https://$DOMAIN" --connect 127.0.0.1 --port 443 \
    --username ops-admin --password-stdin --insecure-allow --expect-uid 0
}

PANEL_UNITS="ops-terminal.service ops-terminal-gateway.service ops-terminal-nginx.service ops-terminal-front.service"

stop_panel() {
  systemctl disable --now $PANEL_UNITS 2>/dev/null || true
  pkill -f "cp13-supervisor" 2>/dev/null || true
  pkill -f "/opt/ops-terminal/bin/ttyd" 2>/dev/null || true
  pkill -f "/opt/ops-terminal/gateway/gateway.py" 2>/dev/null || true
  pkill -f "nginx-internal|nginx-front|ops-terminal/nginx" 2>/dev/null || true
  pkill -f "tmux new -A -s ops" 2>/dev/null || true
  sleep 0.7
}

# --------------------------------------------------------------------------- #
install_test_key
start_mirrors || { echo "FATAL: mock mirrors failed to start"; exit 1; }

case "$SC" in
M1) # ---- incident replay: EMPTY sources + EMPTY index -----------------------
  step M1-0 "replay state: sources.list EMPTY + apt lists EMPTY + nothing installed"
  reset_apt_fresh
  : > /etc/apt/sources.list
  rm -rf /var/lib/apt/lists/*; mkdir -p /var/lib/apt/lists/partial
  assert "M1-0-no-packages" assert_no_panel_packages

  step M1-1 "PROOF of the incident: bare apt-get update rc (must be 0 = silent no-op)"
  apt-get update >/tmp/m1-update.log 2>&1; URC=$?
  chk_eq "M1-1-update-rc-zero" 0 "$URC"

  step M1-2 "installer run — mirror engine must rescue the install"
  run_install "$LOGDIR/M1-install.log" "$M1"
  chk_eq "M1-2-installer-rc" 0 "$?"

  step M1-3 "engine evidence: probe queue, forced mirror selected"
  assert "M1-3-probe-queue" grep -q "probe queue (1): $M1" "$LOGDIR/M1-install.log"
  assert "M1-3-select-m1" grep -q "selected mirror: $M1" "$LOGDIR/M1-install.log"
  assert "M1-3-update-timing" grep -qE "final apt-get update OK in [0-9]+s" "$LOGDIR/M1-install.log"
  assert "M1-3-candidates-logged" grep -q "candidates(live): nginx=" "$LOGDIR/M1-install.log"

  step M1-4 "packages installed BY THE INSTALLER through apt"
  assert "M1-4-nginx" bash -c 'dpkg -l nginx 2>/dev/null | grep -q "^ii"'
  assert "M1-4-certbot" bash -c 'dpkg -l certbot 2>/dev/null | grep -q "^ii"'
  assert "M1-4-nginx-auth-flag" bash -c 'nginx -V 2>&1 | tr " " "\n" | grep -q -- --with-http_auth_request_module'
  assert "M1-4-auth-request-LIVE" grep -q "auth_request LIVE test: PASS" "$LOGDIR/M1-install.log"
  assert "M1-4-installed-versions" grep -q "apt: installed: nginx=" "$LOGDIR/M1-install.log"

  step M1-5 "sources rewritten (list style) + backup + report file"
  assert "M1-5-engine-list" test -f /etc/apt/sources.list.d/00-hanaso-mirror.list
  assert "M1-5-no-trusted" bash -c '! grep -rE "trusted=yes|trusted \[yes\]" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | grep -v "disabled-by-ops-terminal" | grep -q .'
  assert "M1-5-backup-dir" bash -c '[ -d "$(latest_backup_dir)/apt-backup" ]'
  assert "M1-5-report-file" bash -c '[ -s "$(latest_backup_dir)/apt-mirror-report.txt" ]'
  assert "M1-5-e2e-passed" grep -q "end-to-end verification PASSED" "$LOGDIR/M1-install.log"
  ;;

M2) # ---- primary dead -> second mirror wins ---------------------------------
  step M2-0 "fresh state"
  reset_apt_fresh
  assert "M2-0-no-packages" assert_no_panel_packages
  step M2-1 "installer (forced: dead primary + healthy m2)"
  run_install "$LOGDIR/M2-install.log" "$MDEAD $M2"
  chk_eq "M2-1-installer-rc" 0 "$?"
  step M2-2 "engine evidence"
  assert "M2-2-dead-rejected" grep_engine "$LOGDIR/M2-install.log" | grep -q "TEST $MDEAD -> REJECT"
  assert "M2-2-m2-selected" grep -q "selected mirror: $M2" "$LOGDIR/M2-install.log"
  assert "M2-2-installed" bash -c 'dpkg -l nginx 2>/dev/null | grep -q "^ii" && dpkg -l certbot 2>/dev/null | grep -q "^ii"'
  assert "M2-2-e2e" grep -q "end-to-end verification PASSED" "$LOGDIR/M2-install.log"
  ;;

M3) # ---- incomplete index (no universe) -> rejected ------------------------
  step M3-0 "fresh state"
  reset_apt_fresh
  assert "M3-0-no-packages" assert_no_panel_packages
  step M3-1 "installer (forced: nouniverse mirror first, m1 second)"
  run_install "$LOGDIR/M3-install.log" "$MNU $M1"
  chk_eq "M3-1-installer-rc" 0 "$?"
  step M3-2 "engine evidence: certbot candidate missing is the REJECTION reason"
  assert "M3-2-nouniverse-rejected" grep_engine "$LOGDIR/M3-install.log" | grep -q "TEST $MNU -> REJECT"
  assert "M3-2-reason-mentions-certbot" grep_engine "$LOGDIR/M3-install.log" | grep -E "REJECT reason=.*certbot=\(none\)" >/dev/null
  assert "M3-2-m1-selected" grep -q "selected mirror: $M1" "$LOGDIR/M3-install.log"
  assert "M3-2-installed" bash -c 'dpkg -l nginx 2>/dev/null | grep -q "^ii" && dpkg -l certbot 2>/dev/null | grep -q "^ii"'
  ;;

M4) # ---- invalid signature -> rejected --------------------------------------
  step M4-0 "fresh state"
  reset_apt_fresh
  assert "M4-0-no-packages" assert_no_panel_packages
  step M4-1 "installer (forced: TAMPERED InRelease mirror first, m1 second)"
  run_install "$LOGDIR/M4-install.log" "$MBS $M1"
  chk_eq "M4-1-installer-rc" 0 "$?"
  step M4-2 "engine evidence: apt-secure rejects the tampered mirror"
  assert "M4-2-badsig-rejected" grep_engine "$LOGDIR/M4-install.log" | grep -q "TEST $MBS -> REJECT"
  assert "M4-2-signature-reason" grep_engine "$LOGDIR/M4-install.log" | grep -iE "REJECT reason=.*(GPG|signature|invalid)" >/dev/null
  assert "M4-2-m1-selected" grep -q "selected mirror: $M1" "$LOGDIR/M4-install.log"
  assert "M4-2-installed" bash -c 'dpkg -l nginx 2>/dev/null | grep -q "^ii" && dpkg -l certbot 2>/dev/null | grep -q "^ii"'
  assert "M4-2-no-trusted-yes" bash -c '! grep -rE "trusted=yes" /etc/apt/sources.list.d/00-hanaso-mirror.list 2>/dev/null | grep -q .'
  ;;

M5) # ---- current config has universe DISABLED ------------------------------
  step M5-0 "fresh + current config = main-ONLY mirror (certbot unreachable)"
  reset_apt_fresh
  assert "M5-0-no-packages" assert_no_panel_packages
  printf 'deb %s noble main\n' "$MNU" > /etc/apt/sources.list
  rm -rf /var/lib/apt/lists/*; mkdir -p /var/lib/apt/lists/partial
  apt-get update >/dev/null 2>&1 || true
  apt-cache policy certbot >/dev/null 2>&1
  step M5-1 "installer (forced healthy m1; current main-only config must be rejected)"
  run_install "$LOGDIR/M5-install.log" "$M1"
  chk_eq "M5-1-installer-rc" 0 "$?"
  step M5-2 "engine evidence"
  assert "M5-2-current-rejected-no-universe" grep_engine "$LOGDIR/M5-install.log" | grep -E "TEST $MNU -> REJECT" >/dev/null
  assert "M5-2-m1-selected" grep -q "selected mirror: $M1" "$LOGDIR/M5-install.log"
  assert "M5-2-rewrite-includes-universe" grep -q "rewrite-components: main universe" "$LOGDIR/M5-install.log"
  assert "M5-2-certbot-installed" bash -c 'dpkg -l certbot 2>/dev/null | grep -q "^ii"'
  assert "M5-2-old-line-disabled" bash -c 'grep -q "disabled-by-ops-terminal" /etc/apt/sources.list'
  ;;

M6) # ---- DNS-broken + TLS-broken mirrors -> exact reasons ------------------
  step M6-0 "fresh state"
  reset_apt_fresh
  assert "M6-0-no-packages" assert_no_panel_packages
  step M6-1 "installer (forced: dns-broken + tls-broken + healthy m1)"
  run_install "$LOGDIR/M6-install.log" "$MDNS $MTLS $M1"
  chk_eq "M6-1-installer-rc" 0 "$?"
  step M6-2 "engine evidence"
  assert "M6-2-dns-rejected" grep_engine "$LOGDIR/M6-install.log" | grep -q "TEST $MDNS -> REJECT"
  assert "M6-2-dns-reason" grep_engine "$LOGDIR/M6-install.log" | grep -iE "REJECT reason=.*(DNS|resolution)" >/dev/null
  assert "M6-2-tls-rejected" grep_engine "$LOGDIR/M6-install.log" | grep -q "TEST $MTLS -> REJECT"
  assert "M6-2-tls-reason" grep_engine "$LOGDIR/M6-install.log" | grep -iE "REJECT reason=.*(TLS|certificate)" >/dev/null
  assert "M6-2-m1-selected" grep -q "selected mirror: $M1" "$LOGDIR/M6-install.log"
  assert "M6-2-installed" bash -c 'dpkg -l nginx 2>/dev/null | grep -q "^ii" && dpkg -l certbot 2>/dev/null | grep -q "^ii"'
  ;;

M7) # ---- ALL mirrors fail -> safe stop, ZERO changes ------------------------
  step M7-0 "fresh state + snapshot of apt files"
  reset_apt_fresh
  : > /etc/apt/sources.list
  rm -rf /var/lib/apt/lists/*; mkdir -p /var/lib/apt/lists/partial
  cp -a /etc/apt/sources.list /root/m7-sources.before
  assert "M7-0-no-packages" assert_no_panel_packages
  step M7-1 "installer with ONLY broken mirrors (dead + dns + bad signature)"
  run_install "$LOGDIR/M7-install.log" "$MDEAD $MDNS $MBS"
  RC=$?
  chk_eq "M7-1-installer-failed-rc" 1 "$RC"
  step M7-2 "engine evidence: every rejection recorded"
  assert "M7-2-report-header" grep -q "APT MIRROR REPORT" "$LOGDIR/M7-install.log"
  assert "M7-2-dead-rejected" grep_engine "$LOGDIR/M7-install.log" | grep -q "TEST $MDEAD -> REJECT"
  assert "M7-2-dns-rejected" grep_engine "$LOGDIR/M7-install.log" | grep -q "TEST $MDNS -> REJECT"
  assert "M7-2-badsig-rejected" grep_engine "$LOGDIR/M7-install.log" | grep -q "TEST $MBS -> REJECT"
  assert "M7-2-no-healthy" grep -q "RESULT: NO healthy mirror found" "$LOGDIR/M7-install.log"
  assert "M7-2-fatal-banner" grep -q "APT MIRROR ENGINE FAILED" "$LOGDIR/M7-install.log"
  step M7-3 "fail-closed: zero side effects"
  assert "M7-3-sources-untouched" bash -c 'cmp -s /etc/apt/sources.list /root/m7-sources.before'
  assert "M7-3-no-engine-files" bash -c '! ls /etc/apt/sources.list.d/00-hanaso-mirror.* >/dev/null 2>&1'
  assert "M7-3-no-packages" assert_no_panel_packages
  assert "M7-3-no-panel-dir" test ! -e /etc/ops-terminal
  step M7-4 "report archived in the backup dir (for the post-mortem)"
  assert "M7-4-report-archived" bash -c 'B="$(ls -1d /var/backups/ops-terminal/* 2>/dev/null | sort | tail -1)"; [ -n "$B" ] && [ -s "$B/apt-mirror-report.txt" ]'
  rm -f /root/m7-sources.before
  ;;

M8) # ---- deb822 (ubuntu.sources) support ------------------------------------
  step M8-0 "fresh + deb822-only configuration (main-only mirror)"
  reset_apt_fresh
  : > /etc/apt/sources.list
  rm -rf /etc/apt/sources.list.d/*
  rm -rf /var/lib/apt/lists/*; mkdir -p /var/lib/apt/lists/partial
  cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: $MNU
Suites: noble noble-updates noble-backports noble-security
Components: main
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

EOF
  apt-get update >/dev/null 2>&1 || true
  assert "M8-0-no-packages" assert_no_panel_packages
  step M8-1 "installer (forced healthy m1; custom-host Ubuntu repo declared)"
  export OPS_APT_EXTRA_UBUNTU_HOSTS="127.0.0.1"
  run_install "$LOGDIR/M8-install.log" "$M1"
  RC=$?; unset OPS_APT_EXTRA_UBUNTU_HOSTS
  chk_eq "M8-1-installer-rc" 0 "$RC"
  step M8-2 "engine evidence: deb822 disabled + deb822 rewrite"
  assert "M8-2-ubuntu-sources-disabled" test -f /etc/apt/sources.list.d/ubuntu.sources.disabled-by-ops-terminal
  assert "M8-2-engine-sources-written" test -f /etc/apt/sources.list.d/00-hanaso-mirror.sources
  assert "M8-2-deb822-shape" bash -c 'grep -q "^Types: deb" /etc/apt/sources.list.d/00-hanaso-mirror.sources && grep -q "^URIs: $M1" /etc/apt/sources.list.d/00-hanaso-mirror.sources'
  assert "M8-2-signed-by-pinned" bash -c 'grep -q "^Signed-By:" /etc/apt/sources.list.d/00-hanaso-mirror.sources'
  assert "M8-2-no-trusted-yes" bash -c '! grep -qE "trusted" /etc/apt/sources.list.d/00-hanaso-mirror.sources'
  assert "M8-2-components-include-universe" bash -c 'grep -q "Components: main universe" /etc/apt/sources.list.d/00-hanaso-mirror.sources'
  assert "M8-2-installed" bash -c 'dpkg -l nginx 2>/dev/null | grep -q "^ii" && dpkg -l certbot 2>/dev/null | grep -q "^ii"'
  ;;

MA) # ---- natural regression: current config passes, full install + e2e -----
  step MA-0 "fresh state (flat mirror config intact, NO forced mirrors)"
  reset_apt_fresh
  assert "MA-0-no-packages" assert_no_panel_packages
  step MA-1 "installer (natural engine flow)"
  run_install "$LOGDIR/MA-install.log" ""
  chk_eq "MA-1-installer-rc" 0 "$?"
  step MA-2 "engine evidence: current config selected with zero rewrite"
  assert "MA-2-current-passed" grep -q "CURRENT CONFIG passed" "$LOGDIR/MA-install.log"
  assert "MA-2-no-rewrite" bash -c '! ls /etc/apt/sources.list.d/00-hanaso-mirror.* >/dev/null 2>&1'
  assert "MA-2-flat-sources-intact" bash -c 'grep -q "file:/opt/mirror" /etc/apt/sources.list'
  assert "MA-2-candidates-logged" grep -q "candidates(live): nginx=" "$LOGDIR/MA-install.log"
  assert "MA-2-installed" bash -c 'dpkg -l nginx 2>/dev/null | grep -q "^ii" && dpkg -l certbot 2>/dev/null | grep -q "^ii"'
  assert "MA-2-auth-live" grep -q "auth_request LIVE test: PASS" "$LOGDIR/MA-install.log"
  assert "MA-2-e2e" grep -q "end-to-end verification PASSED" "$LOGDIR/MA-install.log"
  assert "MA-2-front-443" bash -c 'ss -tln | awk "{print \$4}" | grep -qE ":443$"'
  ;;

*)
  echo "unknown scenario: $SC"; exit 2 ;;
esac

stop_mirrors
printf '\ncp-mirror battery scenario %s: PASS=%s FAIL=%s\n' "$SC" "$PASS" "$FAIL" | tee -a "$EV/cpm-$SC.log"
[ "$FAIL" = "0" ]
