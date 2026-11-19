#!/usr/bin/env bash
# CP13: PERSISTENT VM session for the browser test — boots the clean VM,
# starts all panel services through the shim (files persist, supervisor
# state does not), runs the transport-only inner relay, then stays alive
# while the OUTER browser automation runs against the REAL :443 TLS listener.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
echo "[session] idempotent reinstall (re-renders configs from the CURRENT repo)..."
bash /root/hanaso-ops-terminal/scripts/install.sh --yes --domain ops.hanaso.ir \
  --server-ip 127.0.0.1 --tls-mode self-signed > /mnt/shared/evidence/session-reinstall.log 2>&1 \
  && echo "[session] reinstall OK" || { echo "[session] REINSTALL FAILED"; tail -20 /mnt/shared/evidence/session-reinstall.log; }
# the one-time password (if this run generated one) -> shared evidence (0600)
sed -n 's/^ PASSWORD    : //p' /mnt/shared/evidence/session-reinstall.log | head -1 \
  > /mnt/shared/evidence/.cp-session-pw.txt
chmod 0600 /mnt/shared/evidence/.cp-session-pw.txt 2>/dev/null || true
echo "[session] starting panel services..."
systemctl enable --now ops-terminal-gateway.service ops-terminal.service \
  ops-terminal-nginx.service ops-terminal-front.service 2>/dev/null || true
sleep 1.5
systemctl is-active --quiet ops-terminal-front.service && echo "[session] front ACTIVE" || echo "[session] front NOT active"
curl -sk -o /dev/null -w "[session] https :443 -> %{http_code}\n" -m 5 https://127.0.0.1:443/login
echo "[session] starting inner relay..."
python3 /root/hanaso-ops-terminal/tests/cp13-fwd.py inner /mnt/shared/cp13.sock 127.0.0.1 443 &
FWD=$!
sleep 150
echo "[session] capturing evidence + killing relay + services (session end)"
for f in /run/cp13-ctl/*.log; do
  [ -f "$f" ] && cp "$f" "/mnt/shared/evidence/sessionlog-$(basename "$f")" 2>/dev/null
done
cp /var/log/ops-terminal/gateway.log /mnt/shared/evidence/sessionlog-gateway.log 2>/dev/null
tail -30 /var/log/ops-terminal/nginx-front.access.log > /mnt/shared/evidence/sessionlog-front-access.log 2>/dev/null
kill $FWD 2>/dev/null
systemctl disable --now ops-terminal-gateway.service ops-terminal.service \
  ops-terminal-nginx.service ops-terminal-front.service 2>/dev/null || true
echo "[session] SESSION_DONE"
