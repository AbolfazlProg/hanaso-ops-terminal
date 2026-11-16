#!/usr/bin/env bash
# CP12 final acceptance: REAL one-line install from the GitHub TAG v1.2.3.
set -u
REPO=/home/z/my-project/work/hanaso-ops-terminal
TEST=/home/z/ops-sandbox-test
HAP=/home/z/sandbox-root/usr/sbin/haproxy
NGX=/home/z/sandbox-root/usr/sbin/nginx
PY=/home/z/.venv/bin/python3
LIBDIR=/home/z/sandbox-root/usr/lib/x86_64-linux-gnu
# the sandbox toolchain binaries (haproxy/nginx/tmux) live under sandbox-root;
# quick-install and the installer run in CHILD processes, so the library path
# must be exported (on a VPS the distro binaries need none of this)
export LD_LIBRARY_PATH="$LIBDIR:/home/z/sandbox-root/lib/x86_64-linux-gnu"
QISB=/home/z/ops-sandbox-cp12-qi
DOMAIN=ops.hanaso.ir; SHARED_DOMAIN=kotodama.ir
QEDGE=8444; QHTTP=8081; QSHARED=9091
QTTYD=17781; QGW=17782; QPANEL=17780
QCFG="$QISB/etc/haproxy/haproxy.cfg"
LOG=/tmp/cp12-qi-real.log

# clean room: kill anything from previous runs on these ports/paths
pkill -f "$QISB" 2>/dev/null || true
pkill -f "shared-server-qi-real" 2>/dev/null || true
sleep 1
rm -rf "$QISB"
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
sed 's/9090/'"$QSHARED"'/' "$TEST/shared-server.py" > "$TEST/shared-server-qi-real.py"
nohup "$PY" "$TEST/shared-server-qi-real.py" > "$TEST/shared-server-qi-real.log" 2>&1 &
STUBPID=$!
nohup "$HAP" -W -db -f "$QCFG" -p "$QISB/haproxy-test/haproxy.pid" > "$QISB/var/log/haproxy.log" 2>&1 &
sleep 1.5

echo "== REAL one-line install from GitHub tag v1.2.3 =="
QUICK_INSTALL_REF=v1.2.3 OPS_SANDBOX_ROOT="$QISB" \
  bash "$REPO/quick-install.sh" --sandbox --sandbox-topology haproxy --yes \
    --haproxy-cfg "$QCFG" --haproxy-bin "$HAP" \
    --haproxy-pidfile "$QISB/haproxy-test/haproxy.pid" \
    --https-port "$QEDGE" --http-port "$QHTTP" \
    --panel-port "$QPANEL" --ttyd-port "$QTTYD" --gateway-port "$QGW" \
    --tls-cert "$TEST/ops-panel.fullchain.pem" --tls-key "$TEST/ops-panel.key" \
    --nginx-bin "$NGX" --mime-types /home/z/sandbox-root/etc/nginx/mime.types \
    --tmux-bin /home/z/sandbox-root/usr/bin/tmux --tmux-ld-path "$LIBDIR" \
    --python-bin "$PY" > "$LOG" 2>&1
RC=$?
echo "install rc=$RC"
grep -E "quick-install|SHA256SUMS|fetched|end-to-end|PASSWORD" "$LOG" | sed 's/^ PASSWORD.*/ PASSWORD    : (one-time, not logged here)/' | head -8
grep -q "SHA256SUMS: OK" "$LOG" && echo "CHECK OK: SHA256SUMS verified from the real tag" || echo "CHECK FAIL: SHA verification missing"
grep -q "end-to-end verification PASSED" "$LOG" && echo "CHECK OK: installer e2e PASSED" || echo "CHECK FAIL: e2e missing"
H="$(curl -sk --resolve "$DOMAIN:$QEDGE:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$DOMAIN:$QEDGE/health")"
[ "$H" = "200" ] && echo "CHECK OK: panel /health 200 through its own edge" || echo "CHECK FAIL: edge health=$H"
S="$(curl -sk --resolve "$SHARED_DOMAIN:$QEDGE:127.0.0.1" "https://$SHARED_DOMAIN:$QEDGE/" 2>/dev/null)"
[ "$S" = "SHARED-SITE-OK" ] && echo "CHECK OK: shared backend intact" || echo "CHECK FAIL: shared=$S"
# committed tree lint from the REAL fetched clone already happened (SHA OK);
# verify the fetched unit had no -e: the tag content check
curl -fsSL "https://raw.githubusercontent.com/AbolfazlProg/hanaso-ops-terminal/v1.2.3/systemd/ops-terminal-nginx.service" \
  | grep -E "^Exec(Start|StartPre|Reload)=" | head -3
CLEAN=1
curl -fsSL "https://raw.githubusercontent.com/AbolfazlProg/hanaso-ops-terminal/v1.2.3/systemd/ops-terminal-nginx.service" \
  | grep -E '^Exec' | grep -q -- "-e stderr" && CLEAN=0
[ "$CLEAN" = "1" ] && echo "CHECK OK: the PUBLISHED tag unit carries NO -e" || echo "CHECK FAIL: published tag still has -e"

# clean uninstall
OPS_SANDBOX_ROOT="$QISB" bash "$REPO/scripts/uninstall.sh" --sandbox --yes \
  --haproxy-cfg "$QCFG" --haproxy-bin "$HAP" \
  --haproxy-pidfile "$QISB/haproxy-test/haproxy.pid" > /tmp/cp12-qi-uninstall.log 2>&1
URC=$?
echo "uninstall rc=$URC"
kill "$STUBPID" 2>/dev/null; pkill -f "$QCFG" 2>/dev/null || true
rm -rf "$QISB" "$TEST/shared-server-qi-real.py"
[ "$RC" = "0" ] && exit 0 || exit 1
