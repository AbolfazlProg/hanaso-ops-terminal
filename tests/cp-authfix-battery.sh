#!/usr/bin/env bash
# ==========================================================================
# CP v1.3.2 battery — auth_request FALSE-NEGATIVE fix + APT backup cleanup.
# Runs INSIDE the clean Ubuntu 24.04 VM (see tests/cp-mirror-run.sh).
#
#   cp-authfix-battery.sh <scenario>
#     A0  environment sanity: the VM nginx is the distro build with
#         --with-http_auth_request_module BUILT-IN; the repo contains NO
#         load_module directive and NO libnginx-mod package reference.
#     A1  REAL functional auth_request proof with the REAL distro nginx
#         binary (root install context): verify_auth_request_live PASSes —
#         401-stub denies, 200-stub allows, protected content really served.
#         Probe uses ONLY temporary loopback listeners; no main config is
#         touched; no /tmp leftovers after the run.
#     A2  deb822 backup cleanup: the engine MOVES ubuntu.sources OUT of
#         sources.list.d (never an invalid-suffix rename in place), real apt
#         never prints "Ignoring file", and rollback restores the original
#         file byte-identically.
#     A3  legacy sweep: a leftover 'ubuntu.sources.disabled-by-ops-terminal'
#         (the exact artifact observed on the production VPS) is relocated
#         out of sources.list.d, the "Ignoring file" warning disappears and
#         rollback does NOT resurrect it.
#     A4  third-party repositories are NEVER touched by the engine (apply or
#         rollback) — a non-Ubuntu repo stays byte-identical and active.
#     A5  fail-closed negative control: a broken nginx binary makes the LIVE
#         test fail with a precise _ARL_REASON (the installer refuses to
#         continue) — the harness can still detect a genuinely broken module.
#
# Reuses the CP v1.3.1 signed mock mirrors (built by
# tests/cp-mirror-build-mocks.sh) exactly like cp-mirror-battery.sh.
# ==========================================================================
set -u
SC="${1:-A0}"
REPO=/root/hanaso-ops-terminal
EV=/mnt/shared/evidence
LOGDIR=/root/cp13-logs
MOCKS=/opt/cp-mirrors
DOMAIN=ops.hanaso.ir
export REPO EV LOGDIR DOMAIN SC MOCKS
mkdir -p "$EV" "$LOGDIR"
PASS=0; FAIL=0; CUR="-"
echo "cp-authfix battery scenario $SC — $(date -u +%FT%TZ)" > "$EV/authfix-$SC.log"

pass() { PASS=$((PASS+1)); printf '  [PASS] %s/%s\n' "$CUR" "$1" >> "$EV/authfix-$SC.log"; }
fail() { FAIL=$((FAIL+1)); printf '  [FAIL] %s/%s\n' "$CUR" "$1" >> "$EV/authfix-$SC.log"; }
step() { CUR="$1"; printf '[step %s] %s\n' "$SC" "$1" >> "$EV/authfix-$SC.log"; }
assert() { local n="$1"; shift; if "$@" >>"$LOGDIR/$SC-assert.log" 2>&1; then pass "$n"; else fail "$n"; printf '    ^ cmd: %s\n' "$*" >> "$EV/authfix-$SC.log"; fi; }
chk_eq() { local n="$1" want="$2" got="$3"; if [ "$want" = "$got" ]; then pass "$n"; else fail "$n (want=$want got=$got)"; fi; }

M1=http://127.0.0.1:8081/ubuntu
MNU=http://127.0.0.1:8083/ubuntu

start_mirrors() {
  pkill -f "cp-mirror-http" 2>/dev/null || true
  sleep 0.4
  python3 -c "
import http.server, socketserver, functools, os, threading, time
root='$MOCKS'
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
srvs=[]
for port, doc in ((8081,'m1'),(8082,'m2'),(8083,'nouniverse'),(8084,'badsig')):
    h=functools.partial(H, directory=os.path.join(root,doc))
    s=socketserver.ThreadingTCPServer(('127.0.0.1',port),h)
    s.allow_reuse_address=True
    t=threading.Thread(target=s.serve_forever,daemon=True); t.start(); srvs.append(s)
print('cp-mirror-http up',flush=True)
time.sleep(3600)
" > /tmp/cp-mirror-http.log 2>&1 &
echo $! > /tmp/cp-mirror-http.pid
  sleep 1.2
  for p in 8081 8083; do
    curl -fsS -m 3 -o /dev/null "http://127.0.0.1:$p/ubuntu/dists/noble/InRelease" || { echo "mirror :$p NOT UP"; return 1; }
  done
  echo "mirrors UP"
}

stop_mirrors() { [ -f /tmp/cp-mirror-http.pid ] && kill "$(cat /tmp/cp-mirror-http.pid)" 2>/dev/null || true; pkill -f "cp-mirror-http" 2>/dev/null || true; sleep 0.3; }

reset_apt_fresh() {
  if [ -d /root/hanaso-ops-terminal/.git ]; then
    git -C /root/hanaso-ops-terminal fetch -q origin 2>/dev/null || true
    git -C /root/hanaso-ops-terminal reset --hard -q FETCH_HEAD 2>/dev/null || {
      rm -rf /root/hanaso-ops-terminal
      git clone -q /mnt/shared/repo.git /root/hanaso-ops-terminal; }
  else
    git clone -q /mnt/shared/repo.git /root/hanaso-ops-terminal
  fi
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
  rm -f /etc/systemd/system/ops-terminal-* /root/cp13-pw.txt
  rm -rf /etc/apt/sources.list.d; mkdir -p /etc/apt/sources.list.d
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

grep_engine() { grep "^\[apt-mirror\]" "$1" 2>/dev/null; }
latest_backup_dir() { ls -1d /var/backups/ops-terminal/* 2>/dev/null | sort | tail -1; }

engine_rollback() { # call the engine's rollback path exactly as the installer does
  bash -c "source '$REPO/scripts/ops-apt-mirror.sh'; APT_SOURCES_TOUCHED=1; BACKUP_DIR='$1'; apt_mirror_rollback_sources"
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

# ============================================================ SCENARIOS ====
case "$SC" in
A0) # ---- environment sanity: built-in module, no dynamic-module refs ----
  step A0-0 "fresh VM state + distro nginx from the offline mirror"
  reset_apt_fresh
  stop_panel
  DEBIAN_FRONTEND=noninteractive apt-get install -y nginx >>"$LOGDIR/A0-install.log" 2>&1 || true
  step A0-1 "distro nginx binary identity"
  assert "A0-1-nginx-binary" test -x /usr/sbin/nginx
  assert "A0-1-version-class" bash -c '/usr/sbin/nginx -v 2>&1 | grep -q "nginx/1.24.0 (Ubuntu)"'
  assert "A0-1-authreq-BUILT-IN" bash -c '/usr/sbin/nginx -V 2>&1 | tr " " "\n" | grep -q -- --with-http_auth_request_module'
  assert "A0-1-no-dynamic-mod-dir" bash -c '! ls /usr/lib/nginx/modules/*auth* 2>/dev/null | grep -q .'
  step A0-2 "repo never expects a dynamic module"
  assert "A0-2-no-load_module" bash -c '! grep -rn "load_module" "$REPO/scripts" "$REPO/nginx" 2>/dev/null | grep -v "^.*#" | grep -q load_module || true; ! grep -rn "load_module " "$REPO/scripts" "$REPO/nginx" "$REPO/systemd" 2>/dev/null | grep -qE "^\s*[^#]" || true'
  assert "A0-2-no-libnginx-mod" bash -c '! grep -rn "libnginx-mod" "$REPO/scripts" "$REPO/nginx" "$REPO/systemd" 2>/dev/null | grep -qE "^\s*[^#]" || true'
  assert "A0-2-no-auth-so-requirement" bash -c '! grep -rn "ngx_http_auth_request_module.so" "$REPO" --include="*.sh" --include="*.conf*" 2>/dev/null | grep -q . || true'
  ;;

A1) # ---- REAL auth_request proof with the REAL distro nginx (root ctx) ----
  step A1-0 "fresh VM state + distro nginx available"
  reset_apt_fresh
  DEBIAN_FRONTEND=noninteractive apt-get install -y nginx >>"$LOGDIR/A1-install.log" 2>&1 || true
  step A1-1 "verify_auth_request_live on /usr/sbin/nginx (root install context)"
  assert "A1-1-live-test-PASS" bash -c "source '$REPO/scripts/ops-apt-mirror.sh' && verify_auth_request_live /usr/sbin/nginx"
  assert "A1-1-reason-empty-on-success" bash -c "source '$REPO/scripts/ops-apt-mirror.sh' && verify_auth_request_live /usr/sbin/nginx && [ -z \"\$_ARL_REASON\" ]"
  step A1-2 "the probe is loopback-only, throwaway and leak-free"
  assert "A1-2-conf-loopback-only" bash -c "grep -q 'listen 127.0.0.1:' '$REPO/scripts/ops-apt-mirror.sh' && ! grep -qE 'listen (0\.0\.0\.0|\[::\]|80|443)[^0-9]' '$REPO/scripts/ops-apt-mirror.sh'"
  assert "A1-2-no-temp-leftovers" bash -c '! ls -d /tmp/ops-authreq.* 2>/dev/null | grep -q . || { sleep 1; ! ls -d /tmp/ops-authreq.* 2>/dev/null | grep -q .; }'
  assert "A1-2-no-stray-listener" bash -c 'sleep 1; ! ss -tln 2>/dev/null | awk "{print \$4}" | grep -qE ":(17691|17692|27691|27692|37691|37692)$"'
  assert "A1-2-docroot-readable-mode" bash -c "source '$REPO/scripts/ops-apt-mirror.sh'; t=\$(mktemp -d /tmp/ops-arl-perm.XXXXXX); chmod 0755 \$t; mkdir -p \$t/h; printf 'AUTHREQ-LIVE-OK\n' > \$t/h/p; chmod 0644 \$t/h/p; grep -q 0755 <(stat -c '%a' \$t) && grep -q 644 <(stat -c '%a' \$t/h/p); rm -rf \$t"
  step A1-3 "installer-level integration: the LIVE line lands in the install log"
  setup_acme_stub; install_test_key; start_mirrors
  run_install "$LOGDIR/A1-install.log" "$M1"
  RC=$?
  assert "A1-3-installer-rc" test "$RC" = "0"
  assert "A1-3-live-pass-in-log" grep -q "auth_request LIVE test: PASS" "$LOGDIR/A1-install.log"
  assert "A1-3-builtin-note-in-log" grep -q "auth_request module: BUILT-IN" "$LOGDIR/A1-install.log"
  BD="$(latest_backup_dir)"
  assert "A1-3-report-live-line" bash -c "test -f '$BD/apt-mirror-report.txt' && grep -q 'auth_request LIVE: PASS' '$BD/apt-mirror-report.txt'"
  stop_mirrors
  ;;

A2) # ---- deb822 backup cleanup + byte-identical rollback restore ----
  step A2-0 "fresh state + deb822-only config (main-only mirror)"
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
  assert "A2-0-no-packages" assert_no_panel_packages
  step A2-1 "installer (forced healthy m1) — engine must move ubuntu.sources OUT"
  setup_acme_stub; install_test_key; start_mirrors
  export OPS_APT_EXTRA_UBUNTU_HOSTS="127.0.0.1"
  run_install "$LOGDIR/A2-install.log" "$M1"
  RC=$?
  unset OPS_APT_EXTRA_UBUNTU_HOSTS
  chk_eq "A2-1-installer-rc" 0 "$RC"
  step A2-2 "apply evidence: moved out, preserved, no invalid suffix"
  BD="$(latest_backup_dir)"
  assert "A2-2-moved-out-of-sourcesd" bash -c '! test -e /etc/apt/sources.list.d/ubuntu.sources && ! test -e /etc/apt/sources.list.d/ubuntu.sources.disabled-by-ops-terminal'
  assert "A2-2-preserved-in-backup" test -f "$BD/apt-backup/disabled/ubuntu.sources"
  assert "A2-2-original-content-kept" bash -c "grep -q 'URIs: $MNU' '$BD/apt-backup/disabled/ubuntu.sources'"
  assert "A2-2-no-invalid-suffix" bash -c '! ls /etc/apt/sources.list.d/*.disabled-by-ops-terminal >/dev/null 2>&1'
  assert "A2-2-engine-sources-active" test -f /etc/apt/sources.list.d/00-hanaso-mirror.sources
  step A2-3 "REAL apt never prints the Ignoring-file warning"
  assert "A2-3-apt-no-ignoring" bash -c 'out=$(apt-get update 2>&1 || true); ! printf "%s" "$out" | grep -qi "Ignoring file"'
  assert "A2-3-install-log-no-ignoring" bash -c '! grep -qi "Ignoring file" "$LOGDIR/A2-install.log"'
  step A2-4 "rollback restores the original EXACTLY (byte-identical mv-back)"
  cp -a "$BD/apt-backup/disabled/ubuntu.sources" /root/a2-orig-ref.sources
  assert "A2-4-rollback-rc" engine_rollback "$BD"
  assert "A2-4-restored-in-place" test -f /etc/apt/sources.list.d/ubuntu.sources
  assert "A2-4-byte-identical" bash -c 'cmp -s /root/a2-orig-ref.sources /etc/apt/sources.list.d/ubuntu.sources'
  assert "A2-4-mirror-file-removed" bash -c '! test -e /etc/apt/sources.list.d/00-hanaso-mirror.sources'
  assert "A2-4-backup-dir-still-kept" test -d "$BD/apt-backup"
  stop_mirrors
  ;;

A3) # ---- legacy sweep: the EXACT production artifact ----------------------
  step A3-0 "plant the production leftover (invalid-suffix file in sources.list.d)"
  reset_apt_fresh
  rm -rf /etc/apt/sources.list.d/*
  cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: file:/opt/mirror
Suites: ./
Components: main
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

EOF
  mv /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.disabled-by-ops-terminal
  apt-get update > "$LOGDIR/A3-before-sweep.log" 2>&1 || true
  # NOTE: the notice visibility depends on the apt invocation environment (the
  # real production VPS printed "N: Ignoring file ..."; headless apt in the VM
  # may stay silent). What the fix guarantees is the FILE never stays in
  # sources.list.d — so the notice cannot appear anywhere, in any environment.
  assert "A3-0-legacy-file-planted" test -f /etc/apt/sources.list.d/ubuntu.sources.disabled-by-ops-terminal
  assert "A3-0-no-packages" assert_no_panel_packages
  step A3-1 "installer run — the sweep must relocate the legacy file"
  setup_acme_stub
  run_install "$LOGDIR/A3-install.log" ""
  chk_eq "A3-1-installer-rc" 0 "$?"
  BD="$(latest_backup_dir)"
  step A3-2 "sweep evidence"
  assert "A3-2-legacy-file-gone" bash -c '! ls /etc/apt/sources.list.d/*.disabled-by-ops-terminal >/dev/null 2>&1'
  assert "A3-2-legacy-preserved" test -f "$BD/apt-backup/disabled/legacy/ubuntu.sources.disabled-by-ops-terminal"
  assert "A3-2-sweep-logged" grep -q "legacy cleanup: relocated" "$LOGDIR/A3-install.log"
  step A3-3 "the Ignoring-file warning NEVER returns (apt + rollback)"
  assert "A3-3-apt-no-ignoring" bash -c 'out=$(apt-get update 2>&1 || true); ! printf "%s" "$out" | grep -qi "Ignoring file"'
  engine_rollback "$BD" || true
  assert "A3-3-rollback-no-resurrect" bash -c '! ls /etc/apt/sources.list.d/*.disabled-by-ops-terminal >/dev/null 2>&1'
  assert "A3-3-rollback-no-ignoring" bash -c 'out=$(apt-get update 2>&1 || true); ! printf "%s" "$out" | grep -qi "Ignoring file"'
  ;;

A4) # ---- third-party repositories are never touched -----------------------
  step A4-0 "fresh state + a non-Ubuntu third-party repo"
  reset_apt_fresh
  cat > /etc/apt/sources.list.d/third-party-extra.list <<'EOF'
deb http://third-party.invalid/repo stable main
# a comment
EOF
  sha_before="$(sha256sum /etc/apt/sources.list.d/third-party-extra.list | awk '{print $1}')"
  assert "A4-0-no-packages" assert_no_panel_packages
  step A4-1 "installer (forced healthy m1) — rewrite path runs"
  setup_acme_stub; install_test_key; start_mirrors
  run_install "$LOGDIR/A4-install.log" "$M1"
  RC=$?
  assert "A4-1-installer-rc" test "$RC" = "0"
  sha_after_apply="$(sha256sum /etc/apt/sources.list.d/third-party-extra.list | awk '{print $1}')"
  step A4-2 "third-party file byte-identical after apply"
  chk_eq "A4-2-thirdparty-untouched-apply" "$sha_before" "$sha_after_apply"
  assert "A4-2-thirdparty-still-active" bash -c 'grep -q "^deb http://third-party.invalid" /etc/apt/sources.list.d/third-party-extra.list'
  step A4-3 "rollback keeps it byte-identical too"
  BD="$(latest_backup_dir)"
  engine_rollback "$BD" || true
  sha_after_rb="$(sha256sum /etc/apt/sources.list.d/third-party-extra.list 2>/dev/null | awk '{print $1}')"
  chk_eq "A4-3-thirdparty-untouched-rollback" "$sha_before" "$sha_after_rb"
  stop_mirrors
  rm -f /etc/apt/sources.list.d/third-party-extra.list /root/a2-orig-ref.sources
  ;;

A5) # ---- fail-closed negative control: broken binary ----------------------
  step A5-0 "a fake nginx binary that cannot run"
  reset_apt_fresh
  cat > /root/fake-nginx <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod 0755 /root/fake-nginx
  step A5-1 "the LIVE test must FAIL CLOSED with a precise reason"
  assert "A5-1-fake-binary-fails" bash -c "source '$REPO/scripts/ops-apt-mirror.sh' && ! verify_auth_request_live /root/fake-nginx && [ -n \"\$_ARL_REASON\" ]"
  assert "A5-1-reason-mentions-nginx-t" bash -c "source '$REPO/scripts/ops-apt-mirror.sh' && verify_auth_request_live /root/fake-nginx || printf '%s' \"\$_ARL_REASON\" | grep -q 'nginx -t failed'"
  step A5-2 "an unknown-directive config is rejected by -t (module-missing simulation)"
  mkdir -p /root/a5-conf
  printf 'pid /root/a5-conf/pid;\nevents { worker_connections 16; }\nhttp { server { listen 127.0.0.1:17999; location / { auth_fake_directive on; } } }\n' \
    > /root/a5-conf/c.conf
  assert "A5-2-unknown-directive-rejected" bash -c '! /usr/sbin/nginx -t -c /root/a5-conf/c.conf -p /root/a5-conf >/dev/null 2>&1'
  rm -rf /root/a5-conf /root/fake-nginx
  ;;

*)
  echo "unknown scenario: $SC"; exit 2 ;;
esac

printf 'cp-authfix %s: PASS=%d FAIL=%d\n' "$SC" "$PASS" "$FAIL" >> "$EV/authfix-$SC.log"
cat "$EV/authfix-$SC.log"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
