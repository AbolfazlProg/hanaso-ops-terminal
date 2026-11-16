#!/usr/bin/env bash
# ==========================================================================
# HANASO OPS Web Terminal — ROOT-PROOF test (sandbox, unprivileged userns)
#
# The production systemd unit runs ttyd as REAL root (no User= line = root,
# working dir /root). This sandbox forbids real root, so the SAME code path
# is emulated with an unprivileged user namespace (unshare -Ur): the shell
# inside it reports uid 0. A REAL BROWSER (Playwright) and the WS-level e2e
# client then prove that typing in the panel executes commands as uid 0.
#
# Creates a SECOND, isolated sandbox (separate root + ports: ttyd 7781,
# gateway 7782, nginx 8090/8453) and tears it down at the end.
# NOTE: install.sh's generic orphan sweep stops other sandboxes' ttyd too
# (pattern "new -A -s ops") — run this BEFORE the final battery pass.
# ==========================================================================
set -Eeuo pipefail
REPO="${OPS_REPO:-/home/z/my-project/hanaso-ops-terminal}"
export OPS_SANDBOX_ROOT="${OPS_SANDBOX_ROOT:-$HOME/ops-sandbox-root}"
SB="$OPS_SANDBOX_ROOT"
PY=/home/z/.venv/bin/python3
NGX=/home/z/sandbox-root
OUT=/home/z/ops-sandbox-test/shots-root
PWFILE=/tmp/ops-pw-root

echo "=== rootproof: fresh sandbox install (isolated ports) ==="
rm -rf "$SB"
bash "$REPO/scripts/install.sh" --sandbox \
  --http-port 8090 --https-port 8453 --ttyd-port 7781 --gateway-port 7782 \
  --tls-cert /home/z/ops-sandbox-test/cert.pem --tls-key /home/z/ops-sandbox-test/key.pem \
  --nginx-bin "$NGX/usr/sbin/nginx" \
  --mime-types "$NGX/etc/nginx/mime.types" \
  --tmux-bin "$NGX/usr/bin/tmux" \
  --tmux-ld-path "$NGX/usr/lib/x86_64-linux-gnu" \
  --python-bin "$PY"

echo "=== rootproof: swap ttyd to a userns-root instance (uid 0) ==="
kill "$(cat "$SB/run/ttyd.pid")" 2>/dev/null || true
rm -f "$SB/run/ttyd.pid"; sleep 0.5
TMUX_TMPDIR="$SB/var/tmp/ops-terminal" LD_LIBRARY_PATH="$NGX/usr/lib/x86_64-linux-gnu" \
  "$NGX/usr/bin/tmux" kill-server 2>/dev/null || true
nohup unshare -Ur env TMUX_TMPDIR="$SB/var/tmp/ops-terminal" \
  LD_LIBRARY_PATH="$NGX/usr/lib/x86_64-linux-gnu" \
  "$SB/opt/ops-terminal/bin/ttyd" -i 127.0.0.1 -p 7781 -W -O -m 2 \
  -T xterm-256color -w "$HOME" \
  "$NGX/usr/bin/tmux" new -A -s ops \
  >> "$SB/var/log/ops-terminal/ttyd.log" 2>&1 &
echo $! > "$SB/run/ttyd.pid"
sleep 1
curl -sf -m 2 http://127.0.0.1:7781/ -o /dev/null && echo "[ok] userns ttyd up on 127.0.0.1:7781"

echo "=== rootproof: rotate password for this test ==="
export OPS_TERMINAL_CONF="$SB/etc/ops-terminal/env"
CRED="$("$PY" "$SB/opt/ops-terminal/gateway/gateway.py" passwd --generate --print-once)"
printf '%s' "$CRED" | sed -n 's/^PANEL_PASSWORD=//p' > "$PWFILE"
chmod 600 "$PWFILE"
[ -s "$PWFILE" ] && echo "[ok] password rotated (file only)"

echo "=== rootproof: WS-level e2e with --expect-uid 0 ==="
"$PY" "$REPO/scripts/e2e-test.py" --base https://ops.hanaso.ir:8453 --connect 127.0.0.1 \
     --username ops-admin --password-stdin --insecure-allow --expect-uid 0 < "$PWFILE"

echo "=== rootproof: REAL BROWSER test with --expect-uid 0 ==="
mkdir -p "$OUT"
NODE_PATH=/home/z/.npm-global/lib/node_modules node "$REPO/tests/browser-test.js" \
  --url https://ops.hanaso.ir:8453 --username ops-admin --password-file "$PWFILE" \
  --map-host ops.hanaso.ir --expect-uid 0 --out "$OUT"

echo "=== rootproof: teardown of the second sandbox ==="
bash "$REPO/scripts/uninstall.sh" --sandbox --yes
rm -f "$PWFILE"
echo "ROOTPROOF_DONE"
