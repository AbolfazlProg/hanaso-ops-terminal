#!/usr/bin/env bash
# CP v1.3.1 — REAL browser proof orchestration (sandbox side).
# VM session (install.sh --tls-mode self-signed via shim + services + inner
# relay) runs INSIDE the VM netns; this script runs the OUTER relay and the
# Playwright browser against the real TLS listener.
set -u
cd /home/z/my-project/work/hanaso-ops-terminal
EV=/home/z/my-project/vm-cp13/shared/evidence
ROOTFS=/home/z/my-project/vm-cp13/rootfs
PORT=8443

echo "[orch] 1. boot VM session (idempotent reinstall + services + inner relay)"
tests/cp13-vm-run.sh tests/cp13-vm-session.sh > /tmp/cp-session.log 2>&1 &
SESS_PID=$!

echo "[orch] 2. outer relay FIRST (it unlinks the socket path — starting it before the inner relay avoids the unlink race)"
python3 tests/cp13-fwd.py outer $PORT /home/z/my-project/vm-cp13/shared/cp13.sock > /tmp/cp-outer.log 2>&1 &
OUTER_PID=$!

echo "[orch] 3. wait for the inner relay socket (created by the VM session)"
for i in $(seq 1 60); do
  [ -S /home/z/my-project/vm-cp13/shared/cp13.sock ] && grep -q "starting inner relay" /tmp/cp-session.log 2>/dev/null && break
  sleep 2
done
[ -S /home/z/my-project/vm-cp13/shared/cp13.sock ] || { echo "FATAL: relay socket never appeared"; cat /tmp/cp-session.log; kill $OUTER_PID $SESS_PID 2>/dev/null; exit 1; }
echo "[orch] inner relay socket present"

echo "[orch] 4. REAL browser (Playwright/Chromium) -> https://127.0.0.1:$PORT"
# password from the VM's one-time file (rootfs is visible from the sandbox)
PWFILE=/tmp/cp-browser-pw.txt
cp "$ROOTFS/root/cp13-pw.txt" "$PWFILE" && chmod 0600 "$PWFILE"
node tests/browser-test.js \
  --url "https://127.0.0.1:$PORT" \
  --map-host ops.hanaso.ir \
  --username ops-admin \
  --password-file "$PWFILE" \
  --expect-uid 0 \
  --file-root "$ROOTFS" \
  --out "$EV/browser-shots" 2>&1 | tee "$EV/browser-cp.log"
RC=${PIPESTATUS[0]}
rm -f "$PWFILE"

echo "[orch] 5. cleanup"
kill $OUTER_PID 2>/dev/null
kill $SESS_PID 2>/dev/null
pkill -f "cp13-fwd.py outer" 2>/dev/null
sleep 1
echo "[orch] browser proof rc=$RC"
exit $RC
