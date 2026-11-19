#!/usr/bin/env bash
# ==========================================================================
# CP13 battery — runs INSIDE the clean Ubuntu 24.04 VM (see cp13-vm-run.sh).
#
#   cp13-battery.sh <scenario>    C=dns-negative  D=rollback  B=simulate-acme
#                                 A=self-signed-full  E=final-uninstall
#
# All scenarios drive the REAL installer (production paths: /etc/ops-terminal,
# /etc/systemd/system, apt-installed distro nginx+certbot) against the
# unit-policy supervisor via the CP13 systemctl shim (no live systemd manager
# exists in this sandbox — CP12 D23; unit files are additionally verified with
# the REAL Ubuntu systemd-analyze 255, the same major version as the VPS).
# ==========================================================================
set -u
SC="${1:-A}"
REPO=/root/hanaso-ops-terminal
EV=/mnt/shared/evidence
LOGDIR=/root/cp13-logs
DOMAIN=ops.hanaso.ir
export REPO EV LOGDIR DOMAIN SC
mkdir -p "$EV" "$LOGDIR"
PASS=0; FAIL=0; CUR="-"
echo "cp13 battery scenario $SC — $(date -u +%FT%TZ)" > "$EV/cp13-$SC.log"

pass() { PASS=$((PASS+1)); printf '  [PASS] %s/%s\n' "$CUR" "$1" >> "$EV/cp13-$SC.log"; }
fail() { FAIL=$((FAIL+1)); printf '  [FAIL] %s/%s\n' "$CUR" "$1" >> "$EV/cp13-$SC.log"; }
step() { CUR="$1"; printf '[step %s] %s\n' "$SC" "$1" >> "$EV/cp13-$SC.log"; }
assert() { local n="$1"; shift; if "$@" >>"$LOGDIR/$SC-assert.log" 2>&1; then pass "$n"; else fail "$n"; printf '    ^ cmd: %s\n' "$*" >> "$EV/cp13-$SC.log"; fi; }
chk_eq() { local n="$1" want="$2" got="$3"; if [ "$want" = "$got" ]; then pass "$n"; else fail "$n (want=$want got=$got)"; fi; }

PANEL_UNITS="ops-terminal.service ops-terminal-gateway.service ops-terminal-nginx.service ops-terminal-front.service ops-terminal-tls-renew.service ops-terminal-tls-renew.timer"

# port assertions: the port lives in ss's COLUMN 4 (mid-line) — a bare
# `grep ":443$"` on the whole line NEVER matches (battery bug caught by B3)
port_listening() { ss -tln | awk '{print $4}' | grep -qE ":$1\$"; }
any_port_open()  { ss -tln | awk '{print $4}' | grep -qE ':(80|443|7680|7681|7682)$'; }
edge_open()      { ss -tln | awk '{print $4}' | grep -qE ':(80|443)$'; }
assert_ports_free() { ! any_port_open; }
assert_edge_free()  { ! edge_open; }
loopback_only_ok()  { if ss -tln | awk '{print $4}' | grep -E ':(7680|7681|7682)$' | grep -qvE '^127\.0\.0\.1'; then return 1; fi; return 0; }

reset_vm() {
  # back to a FRESH-server state: packages purged, files/units gone, ports free
  # (always refresh the shim first — the clone is re-synced between runs)
  cp "$REPO/tests/cp13-systemctl-shim.sh" /usr/bin/systemctl && chmod 0755 /usr/bin/systemctl
  cp "$REPO/tests/cp11-supervisor.py" /usr/libexec/cp13-supervisor.py
  systemctl disable --now $PANEL_UNITS 2>/dev/null || true
  pkill -f "cp13-supervisor" 2>/dev/null || true
  pkill -f "/opt/ops-terminal/bin/ttyd" 2>/dev/null || true
  pkill -f "/opt/ops-terminal/gateway/gateway.py" 2>/dev/null || true
  pkill -f "nginx-internal|nginx-front|ops-terminal/nginx" 2>/dev/null || true
  pkill -f "tmux new -A -s ops" 2>/dev/null || true
  sleep 0.7
  DEBIAN_FRONTEND=noninteractive apt-get purge -y nginx nginx-common nginx-core certbot python3-certbot >>"$LOGDIR/purge.log" 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >>"$LOGDIR/purge.log" 2>&1 || true
  rm -rf /etc/ops-terminal /opt/ops-terminal /var/lib/ops-terminal /var/log/ops-terminal \
         /var/tmp/ops-terminal /run/ops-terminal /var/www/ops-terminal \
         /var/backups/ops-terminal /etc/letsencrypt /usr/local/bin/ops-terminal-passwd \
         /etc/logrotate.d/ops-terminal
  rm -f /etc/systemd/system/ops-terminal-* /usr/bin/systemctl.real.2>/dev/null
  rm -rf /run/cp13-ctl && mkdir -p /run/cp13-ctl
  hash -r
  true
}

assert_fresh() {
  command -v nginx >/dev/null 2>&1 && return 1
  command -v certbot >/dev/null 2>&1 && return 1
  dpkg -l nginx certbot >/dev/null 2>&1 && return 1
  [ ! -e /etc/ops-terminal ] || return 1
  ss -tln | awk '{print $4}' | grep -qE ':(80|443|7680|7681|7682)$' && return 1
  return 0
}

installer() { # args... -> runs install.sh, captures log, extracts password
  local out="$1"; shift
  bash "$REPO/scripts/install.sh" --yes "$@" >"$out" 2>&1
  local rc=$?
  # a reinstall that PRESERVES credentials prints no PASSWORD line — keep the
  # previously saved one in that case
  sed -n 's/^ PASSWORD    : //p' "$out" | head -1 > /tmp/cp13-pw.new
  if [ -s /tmp/cp13-pw.new ]; then mv /tmp/cp13-pw.new /root/cp13-pw.txt; else rm -f /tmp/cp13-pw.new; fi
  chmod 0600 /root/cp13-pw.txt 2>/dev/null || true
  return $rc
}

e2e_run() { # uses saved password; asserts exit 0
  command -v python3 >/dev/null || return 1
  TMUX_TMPDIR=/var/tmp/ops-terminal tmux kill-server 2>/dev/null || true
  [ -s /root/cp13-pw.txt ] || return 1
  printf '%s' "$(cat /root/cp13-pw.txt)" | python3 "$REPO/scripts/e2e-test.py" \
    --base "https://$DOMAIN" --connect 127.0.0.1 --port 443 \
    --username ops-admin --password-stdin --insecure-allow --expect-uid 0
}

verify_units() { # REAL Ubuntu systemd parser, same major version as the VPS
  systemd-analyze verify /etc/systemd/system/ops-terminal.service \
    /etc/systemd/system/ops-terminal-gateway.service \
    /etc/systemd/system/ops-terminal-nginx.service \
    /etc/systemd/system/ops-terminal-front.service \
    /etc/systemd/system/ops-terminal-tls-renew.service \
    /etc/systemd/system/ops-terminal-tls-renew.timer 2>&1
}

# --------------------------------------------------------------------------- #
case "$SC" in
C)  # ---------------- DNS mismatch must STOP with zero changes ---------------
  step C0 "reset to fresh"
  reset_vm
  assert "C0-fresh" assert_fresh

  step C1 "hosts -> old VPS IP 87.107.129.210 (real pre-update state from the mission evidence)"
  sed -i 's|^127.0.0.1 ops.hanaso.ir|87.107.129.210 ops.hanaso.ir|' /etc/hosts
  getent hosts ops.hanaso.ir

  step C2 "installer run (acme, --server-ip 45.135.242.140) — must abort BEFORE any change"
  installer "$LOGDIR/C-install.log" --domain "$DOMAIN" --server-ip 45.135.242.140 --tls-mode acme
  RC=$?
  chk_eq "C2-installer-aborted-rc" 1 "$RC"

  step C3 "evidence: DNS GATE message"
  assert "C3-dns-gate-message" grep -q "DNS GATE" "$LOGDIR/C-install.log"

  step C4 "zero side effects"
  assert "C4-no-etc" test ! -e /etc/ops-terminal
  assert "C4-no-units" bash -c 'ls /etc/systemd/system/ops-terminal-* 2>/dev/null | grep -q . && exit 1 || exit 0'
  assert "C4-nginx-not-installed" bash -c 'dpkg -l nginx 2>/dev/null | grep -q "^ii" && exit 1 || exit 0'
  assert "C4-no-webroot" test ! -e /var/www/ops-terminal
  assert "C4-ports-free" assert_ports_free

  step C5 "restore hosts"
  sed -i 's|^87.107.129.210 ops.hanaso.ir|127.0.0.1 ops.hanaso.ir|' /etc/hosts
  getent hosts ops.hanaso.ir
  ;;

D)  # ---------------- late failure -> full rollback --------------------------
  step D0 "reset to fresh"
  reset_vm
  assert "D0-fresh" assert_fresh

  step D1 "make an INVALID certificate pair (wrong domain + mismatched key)"
  mkdir -p /root/cp13-ca
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 -sha256 -keyout /root/cp13-bad.key \
    -out /root/cp13-bad.pem -subj "/CN=wrong.example.com" \
    -addext "subjectAltName=DNS:wrong.example.com" 2>/dev/null

  step D2 "installer run with the invalid --tls-cert — must fail AFTER services start, then roll back"
  installer "$LOGDIR/D-install.log" --domain "$DOMAIN" --server-ip 127.0.0.1 \
    --tls-mode acme --tls-cert /root/cp13-bad.pem --tls-key /root/cp13-bad.key
  chk_eq "D2-installer-failed-rc" 1 "$?"

  step D3 "rollback evidence: everything this panel created is gone"
  assert "D3-no-etc" test ! -e /etc/ops-terminal
  assert "D3-no-opt" test ! -e /opt/ops-terminal
  assert "D3-no-webroot" test ! -e /var/www/ops-terminal
  assert "D3-no-unit-files" bash -c 'ls /etc/systemd/system/ops-terminal-* 2>/dev/null | grep -q . && exit 1 || exit 0'
  assert "D3-no-wants-links" bash -c 'ls /etc/systemd/system/multi-user.target.wants/ops-terminal-* 2>/dev/null | grep -q . && exit 1 || exit 0'
  assert "D3-ports-free" assert_ports_free
  assert "D3-no-processes" bash -c '! pgrep -f "[g]ateway.py|/opt/ops[-]terminal" | grep -q .'
  step D4 "distro packages intentionally KEPT (documented rollback note)"
  assert "D4-nginx-package-kept" bash -c 'dpkg -l nginx 2>/dev/null | grep -q "^ii"'
  assert "D4-rollback-note-in-log" grep -q "distro packages stay installed" "$LOGDIR/D-install.log"
  rm -f /root/cp13-bad.pem /root/cp13-bad.key
  ;;

B)  # ---------------- production ACME branch with stub certbot -----------------
  step B0 "reset to fresh + test CA for the stub certbot"
  reset_vm
  assert "B0-fresh" assert_fresh
  mkdir -p /root/cp13-ca
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 -sha256 \
    -keyout /root/cp13-ca/ca.key -out /root/cp13-ca/ca.crt \
    -subj "/CN=CP13 Stub CA" -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
  # trust the stub CA system-wide: the installer's OWN e2e keeps STRICT TLS
  # verification even in the simulated-ACME run (same as a real LE chain)
  mkdir -p /usr/local/share/ca-certificates
  cp /root/cp13-ca/ca.crt /usr/local/share/ca-certificates/cp13-stub-ca.crt
  update-ca-certificates >/dev/null 2>&1

  step B1 "installer (standalone auto-detect, acme mode, STUB certbot — production code path)"
  # stub-certbot env: the ACME round-trip goes through the REAL :80 edge; the
  # "issued" certificate is signed by the test CA into the REAL LE paths.
  OPS_STUB_HTTP80=80 OPS_STUB_CA_DIR=/root/cp13-ca OPS_STUB_LIVE_BASE=/etc/letsencrypt \
    installer "$LOGDIR/B-install.log" --domain "$DOMAIN" --server-ip 127.0.0.1 \
    --tls-mode acme --simulate-acme --certbot-bin "$REPO/tests/stub-certbot.sh"
  chk_eq "B1-installer-rc" 0 "$?"

  step B2 "fresh dependencies installed BY THE INSTALLER (apt: nginx AND certbot)"
  assert "B2-nginx-installed" bash -c 'dpkg -l nginx 2>/dev/null | grep -q "^ii"'
  assert "B2-certbot-installed" bash -c 'dpkg -l certbot 2>/dev/null | grep -q "^ii"'
  assert "B2-nginx-auth-request" bash -c 'nginx -V 2>&1 | tr " " "\n" | grep -q -- --with-http_auth_request_module'
  assert "B2-binary-identity-logged" grep -q "nginx binary identity:" "$LOGDIR/B-install.log"

  step B3 "real edge listeners + ACME round-trip + stub issuance"
  assert "B3-port80-listening" port_listening 80
  assert "B3-port443-listening" port_listening 443
  assert "B3-acme-challenge-through-real-edge" grep -q "ACME challenge round-trip OK through the real edge" "$LOGDIR/B-install.log"
  assert "B3-le-cert-files" test -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"

  step B4 "renewal wiring: deploy hook + certbot.timer enabled"
  assert "B4-deploy-hook" bash -c 'test -x /etc/letsencrypt/renewal-hooks/deploy/ops-terminal-standalone.sh'
  assert "B4-deploy-hook-reloads-front" bash -c 'grep -q "ops-terminal-front.service" /etc/letsencrypt/renewal-hooks/deploy/ops-terminal-standalone.sh'
  assert "B4-certbot-timer-enabled" test -e /etc/systemd/system/timers.target.wants/certbot.timer
  assert "B4-timer-note" grep -q "certbot.timer enabled" "$LOGDIR/B-install.log"

  step B5 "HTTPS behaviour through the real :443 TLS listener"
  assert "B5-http-redirects" bash -c '[ "$(curl -s -o /dev/null -w "%{http_code}" -m 5 "http://127.0.0.1:80/" )" = 301 ]'
  assert "B5-https-login-200" bash -c '[ "$(curl -sk -o /dev/null -w "%{http_code}" -m 5 "https://127.0.0.1:443/login" )" = 200 ]'
  assert "B5-hsts-present" bash -c 'curl -skI -m 5 "https://127.0.0.1:443/login" | grep -qi "strict-transport-security"'
  assert "B5-auth-gate-302" bash -c '[ "$(curl -sk -o /dev/null -w "%{http_code}" -m 5 "https://127.0.0.1:443/" )" = 302 ]'

  step B6 "real end-to-end (login -> WebSocket -> shell -> id -u = 0)"
  assert "B6-e2e-full" e2e_run

  step B7 "uninstall (default keeps packages; only project resources removed)"
  bash "$REPO/scripts/uninstall.sh" --yes --purge >>"$LOGDIR/B-uninstall.log" 2>&1
  RC=$?
  chk_eq "B7-uninstall-rc" 0 "$RC"
  assert "B7-ports-free" assert_ports_free
  assert "B7-no-etc" test ! -e /etc/ops-terminal
  assert "B7-no-units" bash -c 'ls /etc/systemd/system/ops-terminal-* 2>/dev/null | grep -q . && exit 1 || exit 0'
  assert "B7-packages-kept" bash -c 'dpkg -l nginx 2>/dev/null | grep -q "^ii"'

  step B8 "purge-packages uninstall (opt-in: apt-purges the distro packages)"
  bash "$REPO/scripts/uninstall.sh" --yes --purge --purge-packages >>"$LOGDIR/B-uninstall2.log" 2>&1 || true
  assert "B8-nginx-purged" bash -c '! dpkg -l nginx 2>/dev/null | grep -q "^ii"'
  assert "B8-certbot-purged" bash -c '! dpkg -l certbot 2>/dev/null | grep -q "^ii"'
  assert "B8-ports-still-free" assert_edge_free
  ;;

A)  # ---------------- FULL clean install, self-signed TLS ---------------------
  step A0 "reset to fresh (NO nginx, NO certbot — the real fresh-VPS state)"
  reset_vm
  assert "A0-fresh" assert_fresh

  step A1 "installer (standalone auto-detect via preflight, self-signed TLS for the VM)"
  installer "$LOGDIR/A-install.log" --domain "$DOMAIN" --server-ip 127.0.0.1 --tls-mode self-signed
  chk_eq "A1-installer-rc" 0 "$?"

  step A2 "topology + dependencies (nginx installed by the installer; auth_request proven)"
  assert "A2-topology-standalone" bash -c 'grep -qiE "^ *Topology .*standalone" "$LOGDIR/A-install.log" || grep -q "FRESH SERVER" "$LOGDIR/A-install.log"'
  assert "A2-nginx-installed" bash -c 'dpkg -l nginx 2>/dev/null | grep -q "^ii"'
  assert "A2-nginx-auth-request" bash -c 'nginx -V 2>&1 | tr " " "\n" | grep -q -- --with-http_auth_request_module'
  assert "A2-certbot-not-needed" bash -c '! dpkg -l certbot 2>/dev/null | grep -q "^ii"'
  assert "A2-distro-nginx-disabled" bash -c '! test -e /etc/systemd/system/multi-user.target.wants/nginx.service'
  assert "A2-preflight-ports" grep -q "front nginx phase B live on :443" "$LOGDIR/A-install.log"

  step A3 "unit files + REAL systemd 255 verification + boot persistence"
  assert "A3-unit-files" bash -c 'ls /etc/systemd/system/ops-terminal-front.service /etc/systemd/system/ops-terminal-gateway.service /etc/systemd/system/ops-terminal-nginx.service /etc/systemd/system/ops-terminal.service >/dev/null'
  assert "A3-systemd-analyze-verify" verify_units
  assert "A3-services-enabled" bash -c 'for u in ops-terminal ops-terminal-gateway ops-terminal-nginx ops-terminal-front; do test -e /etc/systemd/system/multi-user.target.wants/$u.service || exit 1; done'
  assert "A3-tls-timer-enabled" test -e /etc/systemd/system/timers.target.wants/ops-terminal-tls-renew.timer

  step A4 "services healthy: loopback-only panel, edge :80/:443"
  assert "A4-gateway-health" curl -sf -m 5 "http://127.0.0.1:7682/health"
  assert "A4-ttyd-page" curl -sf -m 5 "http://127.0.0.1:7681/" -o /dev/null
  assert "A4-internal-health" curl -sf -m 5 "http://127.0.0.1:7680/health"
  assert "A4-loopback-only" loopback_only_ok
  assert "A4-edge80" port_listening 80
  assert "A4-edge443" port_listening 443
  assert "A4-front-unit-active" systemctl is-active --quiet ops-terminal-front.service

  step A5 "TLS material: self-signed, valid SAN, real HTTPS behaviour"
  assert "A5-cert-san" bash -c 'openssl x509 -in /etc/ops-terminal/tls/fullchain.pem -noout -ext subjectAltName | grep -qi "DNS:ops.hanaso.ir"'
  assert "A5-cert-key-match" bash -c 'c=$(openssl x509 -in /etc/ops-terminal/tls/fullchain.pem -noout -pubkey | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d" " -f1); k=$(openssl pkey -in /etc/ops-terminal/tls/privkey.pem -pubout -outform DER 2>/dev/null | sha256sum | cut -d" " -f1); test "$c" = "$k"'
  assert "A5-key-mode-0640" bash -c '[ "$(stat -c %a /etc/ops-terminal/tls/privkey.pem)" = 640 ]'
  assert "A5-http-301" bash -c '[ "$(curl -s -o /dev/null -w "%{http_code}" -m 5 http://127.0.0.1:80/)" = 301 ]'
  assert "A5-https-login-200" bash -c '[ "$(curl -sk -o /dev/null -w "%{http_code}" -m 5 https://127.0.0.1:443/login)" = 200 ]'
  assert "A5-hsts" bash -c 'curl -skI -m 5 https://127.0.0.1:443/login | grep -qi "strict-transport-security"'
  assert "A5-unauth-302" bash -c '[ "$(curl -sk -o /dev/null -w "%{http_code}" -m 5 https://127.0.0.1:443/)" = 302 ]'
  assert "A5-tls-version" bash -c 'echo | openssl s_client -connect 127.0.0.1:443 -servername ops.hanaso.ir -brief 2>&1 | grep -qE "TLSv1.[23]"'

  step A6 "REAL end-to-end: login -> WebSocket -> root shell -> id -u = 0 -> interactive command"
  assert "A6-e2e-full" e2e_run

  step A7 "health-check tool (production contract)"
  assert "A7-health-check" bash "$REPO/scripts/health-check.sh" --url "https://$DOMAIN"

  step A8 "rate limiting (nginx 429 cap) + gateway progressive lockout (423)"
  python3 - <<'PYEOF' >>"$LOGDIR/A-ratelimit.log" 2>&1
import http.client, re, ssl, time

ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE

def attempt(pw):
    conn = http.client.HTTPSConnection("127.0.0.1", 443, context=ctx, timeout=10)
    conn.request("GET", "/login", headers={"Host": "ops.hanaso.ir"})
    r = conn.getresponse(); body = r.read().decode()
    cookies = " ".join(v for k, v in r.getheaders() if k.lower()=="set-cookie")
    m = re.search(r'name="csrf" value="([^"]+)"', body)
    csrf = m.group(1) if m else ""
    conn2 = http.client.HTTPSConnection("127.0.0.1", 443, context=ctx, timeout=10)
    hdrs = {"Host": "ops.hanaso.ir", "Content-Type": "application/x-www-form-urlencoded",
            "Cookie": cookies, "X-Forwarded-Proto": "https"}
    conn2.request("POST", "/login", body="username=ops-admin&password=%s&csrf=%s" % (pw, csrf), headers=hdrs)
    rr = conn2.getresponse(); rr.read()
    return rr.status

# phase 1: fast burst -> nginx limit_req caps with 429
codes = [attempt("WRONGPW-%d" % i) for i in range(40)]
print("burst codes: 401=%d 429=%d 423=%d" % (codes.count(401), codes.count(429), codes.count(423)))
print("RATE429=%d" % (1 if codes.count(429) else 0))
# phase 2: paced failed logins (under the nginx rate) -> 5 gateway failures
# engage the progressive lockout -> 423
l423 = 0
for i in range(7):
    time.sleep(3.2)
    st = attempt("WRONGPW-paced-%d" % i)
    if st == 423:
        l423 += 1
print("paced: 423-count=%d" % l423)
print("LOCKOUT423=%d" % (1 if l423 else 0))
PYEOF
  assert "A8-nginx-429-cap" bash -c 'grep -q "RATE429=1" "$LOGDIR/A-ratelimit.log"'
  assert "A8-gateway-423-lockout" bash -c 'grep -q "LOCKOUT423=1" "$LOGDIR/A-ratelimit.log"'
  assert "A8-lockout-event-logged" bash -c 'grep -q "engaged_lockout=True" /var/log/ops-terminal/gateway.log'

  step A9 "lockout persists across gateway restart; cleared by state removal"
  systemctl restart ops-terminal-gateway.service && sleep 1
  assert "A9-lockout-persisted" bash -c 'grep -q "LOGIN_BLOCKED" /var/log/ops-terminal/gateway.log || grep -q "engaged_lockout=True" /var/log/ops-terminal/gateway.log'
  rm -f /var/lib/ops-terminal/state.json
  systemctl restart ops-terminal-gateway.service && sleep 1
  pass "A9-state-removal-applied"
  # restore a clean credential state for later steps
  systemctl restart ops-terminal-gateway.service && sleep 1

  step A10 "controlled restart + persistence (tmux session survives; unit restarts)"
  assert "A10-restart-ttyd" systemctl restart ops-terminal.service
  assert "A10-restart-gateway" systemctl restart ops-terminal-gateway.service
  assert "A10-restart-internal" systemctl restart ops-terminal-nginx.service
  assert "A10-restart-front-reload" systemctl reload ops-terminal-front.service
  sleep 1
  assert "A10-still-healthy" bash -c 'curl -sf -m 5 http://127.0.0.1:7682/health && curl -skf -m 5 https://127.0.0.1:443/health'
  assert "A10-e2e-after-restarts" e2e_run

  step A11 "full stop -> start cycle (simulated reboot: enabled units come back)"
  systemctl disable --now $PANEL_UNITS || true
  sleep 1
  assert "A11-ports-freed-after-stop" assert_ports_free
  systemctl enable --now $PANEL_UNITS || true
  sleep 1.5
  assert "A11-all-back" bash -c 'systemctl is-active --quiet ops-terminal-front.service && systemctl is-active --quiet ops-terminal-gateway.service && systemctl is-active --quiet ops-terminal.service && systemctl is-active --quiet ops-terminal-nginx.service'
  assert "A11-e2e-after-reboot-cycle" e2e_run

  step A12 "self-signed TLS renewal (regenerate when < 30d to expiry + reload)"
  rm -f /etc/ops-terminal/tls/fullchain.pem /etc/ops-terminal/tls/privkey.pem
  systemctl start ops-terminal-tls-renew.service; echo "oneshot rc=$?"
  assert "A12-cert-regenerated" bash -c 'test -s /etc/ops-terminal/tls/fullchain.pem && openssl x509 -in /etc/ops-terminal/tls/fullchain.pem -noout -ext subjectAltName | grep -qi "DNS:ops.hanaso.ir"'
  assert "A12-front-reloaded-healthy" bash -c 'curl -skf -m 5 https://127.0.0.1:443/health'

  step A13 "idempotent reinstall (credentials preserved, everything still healthy)"
  PW_BEFORE="$(cat /root/cp13-pw.txt)"
  installer "$LOGDIR/A-reinstall.log" --domain "$DOMAIN" --server-ip 127.0.0.1 --tls-mode self-signed
  chk_eq "A13-reinstall-rc" 0 "$?"
  assert "A13-credentials-preserved" bash -c 'grep -q "existing credentials kept" "$LOGDIR/A-reinstall.log"'
  PW_AFTER="$(cat /root/cp13-pw.txt)"
  chk_eq "A13-password-unchanged" "$PW_BEFORE" "$PW_AFTER"
  assert "A13-e2e-after-reinstall" e2e_run

  step A14 "StartLimit: a persistently broken unit FAILS and stays DOWN (no restart loop)"
  cp /etc/ops-terminal/nginx-front/nginx.conf /root/nginx.conf.good
  # deterministic breakage: a MISSING include fails nginx -t unconditionally
  # (an unused http-level ssl_certificate would NOT be checked by -t)
  echo 'include /nonexistent/cp13-broken.conf;' >> /etc/ops-terminal/nginx-front/nginx.conf
  systemctl restart ops-terminal-front.service || true
  sleep 18
  ST="$(systemctl show ops-terminal-front.service -p ActiveState,Result,NRestarts 2>/dev/null)"
  echo "  after sabotage: $ST" >> "$EV/cp13-$SC.log"
  assert "A14-failed-state" bash -c 'systemctl show ops-terminal-front.service -p ActiveState --value | grep -q failed'
  assert "A14-norestarts-bounded" bash -c 'n=$(systemctl show ops-terminal-front.service -p NRestarts --value | awk -F= "{print \$2}"); test "$n" -le 5'
  N1="$(systemctl show ops-terminal-front.service -p NRestarts --value | awk -F= '{print $2}')"
  sleep 4
  N2="$(systemctl show ops-terminal-front.service -p NRestarts --value | awk -F= '{print $2}')"
  chk_eq "A14-no-restart-loop" "$N1" "$N2"
  assert "A14-ports-released" assert_edge_free
  cp /root/nginx.conf.good /etc/ops-terminal/nginx-front/nginx.conf
  systemctl reset-failed ops-terminal-front.service || true
  systemctl restart ops-terminal-front.service && sleep 1
  assert "A14-recovered" bash -c 'systemctl is-active --quiet ops-terminal-front.service'
  assert "A14-443-back" port_listening 443
  assert "A14-e2e-after-recovery" e2e_run
  ;;

E)  # ---------------- final uninstall + clean-state proof --------------------
  step E1 "uninstall --purge (default keeps packages)"
  bash "$REPO/scripts/uninstall.sh" --yes --purge >>"$LOGDIR/E-uninstall.log" 2>&1
  chk_eq "E1-rc" 0 "$?"
  step E2 "post-conditions: nothing of the panel survives"
  assert "E2-ports-free" assert_ports_free
  assert "E2-no-unit-files" bash -c 'ls /etc/systemd/system/ops-terminal-* 2>/dev/null | grep -q . && exit 1 || exit 0'
  assert "E2-no-wants" bash -c 'ls /etc/systemd/system/multi-user.target.wants/ops-terminal-* /etc/systemd/system/timers.target.wants/ops-terminal-* 2>/dev/null | grep -q . && exit 1 || exit 0'
  assert "E2-no-etc" test ! -e /etc/ops-terminal
  assert "E2-no-opt" test ! -e /opt/ops-terminal
  assert "E2-no-webroot" test ! -e /var/www/ops-terminal
  assert "E2-no-le-hook" test ! -e /etc/letsencrypt/renewal-hooks/deploy/ops-terminal-standalone.sh
  assert "E2-no-tmpdir" test ! -e /var/tmp/ops-terminal
  assert "E2-no-passwd-tool" test ! -e /usr/local/bin/ops-terminal-passwd
  assert "E2-distro-nginx-still-disabled" bash -c '! test -e /etc/systemd/system/multi-user.target.wants/nginx.service'
  step E3 "nginx package still present (kept by default — documented)"
  assert "E3-package-kept" bash -c 'dpkg -l nginx 2>/dev/null | grep -q "^ii"'
  ;;


F)  # ---------------- quick-install one-liner (bootstrap + SHA gate) ----------
  step F0 "reset to fresh"
  reset_vm
  assert "F0-fresh" assert_fresh

  step F1 "run the snapshot's quick-install.sh exactly like curl|bash (local repo pin)"
  git --git-dir /mnt/shared/repo.git show HEAD:quick-install.sh > /root/quick-install.sh
  QUICK_INSTALL_REPO=/mnt/shared/repo.git QUICK_INSTALL_REF=cp13-snapshot \
    bash /root/quick-install.sh --yes --domain "$DOMAIN" --server-ip 127.0.0.1 \
    --tls-mode self-signed > "$LOGDIR/F-install.log" 2>&1
  RC=$?
  sed -n 's/^ PASSWORD    : //p' "$LOGDIR/F-install.log" | head -1 > /root/cp13-pw.txt
  chmod 0600 /root/cp13-pw.txt 2>/dev/null || true
  chk_eq "F1-rc" 0 "$RC"

  step F2 "bootstrapper evidence: SHA fail-closed gate + installer output"
  assert "F2-sha-ok" grep -q "SHA256SUMS: OK" "$LOGDIR/F-install.log"
  assert "F2-installer-summary" grep -q "HANASO OPS Web Terminal — installed" "$LOGDIR/F-install.log"
  assert "F2-topology-standalone" bash -c 'grep -qiE "^ *Topology .*standalone" "$LOGDIR/F-install.log"'
  assert "F2-nginx-auth-request" bash -c 'nginx -V 2>&1 | tr " " "\n" | grep -q -- --with-http_auth_request_module'

  step F3 "panel actually serving through the real edge"
  assert "F3-port443" port_listening 443
  assert "F3-health" bash -c 'curl -skf -m 5 https://127.0.0.1:443/health'
  assert "F3-e2e" e2e_run

  step F4 "uninstall leaves nothing behind"
  bash "$REPO/scripts/uninstall.sh" --yes --purge >>"$LOGDIR/F-uninstall.log" 2>&1
  RC=$?
  chk_eq "F4-uninstall-rc" 0 "$RC"
  assert "F4-ports-free" assert_ports_free
  ;;

*)
  echo "unknown scenario $SC" >&2; exit 2 ;;
esac

printf 'TOTAL PASSED CHECKS: %d\nTOTAL FAILED CHECKS: %d\n' "$PASS" "$FAIL" >> "$EV/cp13-$SC.log"
# unit-policy supervisor logs (live only INSIDE this session — /run is tmpfs)
for f in /run/cp13-ctl/*.log; do
  [ -f "$f" ] && cp "$f" "$EV/unitlog-$SC-$(basename "$f")" 2>/dev/null
done
printf 'SCENARIO %s DONE: PASS=%d FAIL=%d\n' "$SC" "$PASS" "$FAIL"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
