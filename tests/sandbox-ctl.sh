#!/usr/bin/env bash
# ==========================================================================
# TEST-ONLY helper: control the sandbox services (no systemd in sandbox).
# Usage: sandbox-ctl.sh {start|stop|restart|status} {ttyd|gateway|nginx|all}
# ==========================================================================
set -euo pipefail
SB="${OPS_SANDBOX_ROOT:-/home/z/ops-sandbox}"
RUN="$SB/run"; LOG="$SB/var/log"
NGINX_BIN="${OPS_SANDBOX_NGINX_BIN:-/home/z/sandbox-root/usr/sbin/nginx}"
TMUX_BIN="/home/z/sandbox-root/usr/bin/tmux"
TMUX_LD="/home/z/sandbox-root/usr/lib/x86_64-linux-gnu"
PY="/home/z/.venv/bin/python3"
ETC="$SB/etc/ops-terminal"

cmd="${1:-status}"; svc="${2:-all}"

start_ttyd() {
  nohup env TMUX_TMPDIR="$SB/var/tmp/ops-terminal" LD_LIBRARY_PATH="$TMUX_LD" \
    "$SB/opt/ops-terminal/bin/ttyd" -i 127.0.0.1 -p 7681 -W -O -m 2 \
    -T xterm-256color -w "$HOME" "$TMUX_BIN" new -A -s ops \
    >> "$LOG/ttyd.log" 2>&1 &
  echo $! > "$RUN/ttyd.pid"
}
start_gateway() {
  nohup env OPS_TERMINAL_CONF="$ETC/env" "$PY" "$SB/opt/ops-terminal/gateway/gateway.py" \
    >> "$LOG/gateway-stderr.log" 2>&1 &
  echo $! > "$RUN/gateway.pid"
}
start_nginx() {
  "$NGINX_BIN" -c "$SB/nginx/nginx.conf"
}
stop_pid() {
  local f="$1"
  if [ -f "$RUN/$f.pid" ]; then
    kill "$(cat "$RUN/$f.pid")" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$(cat "$RUN/$f.pid")" 2>/dev/null || break; sleep 0.3; done
    rm -f "$RUN/$f.pid"
  fi
}
stop_nginx() {
  if [ -f "$RUN/nginx.pid" ]; then
    "$NGINX_BIN" -c "$SB/nginx/nginx.conf" -s stop 2>/dev/null || kill "$(cat "$RUN/nginx.pid")" 2>/dev/null || true
    rm -f "$RUN/nginx.pid"
  fi
}
status_of() {
  if [ -f "$RUN/$1.pid" ] && kill -0 "$(cat "$RUN/$1.pid")" 2>/dev/null; then
    echo "  $1: RUNNING (pid $(cat "$RUN/$1.pid"))"
  else
    echo "  $1: STOPPED"
  fi
}

case "$cmd" in
  start)
    [ "$svc" = "gateway" ] || [ "$svc" = "all" ] && start_gateway
    [ "$svc" = "ttyd" ] || [ "$svc" = "all" ] && start_ttyd
    [ "$svc" = "nginx" ] || [ "$svc" = "all" ] && start_nginx
    ;;
  stop)
    [ "$svc" = "nginx" ] || [ "$svc" = "all" ] && stop_nginx
    [ "$svc" = "ttyd" ] || [ "$svc" = "all" ] && stop_pid ttyd
    [ "$svc" = "gateway" ] || [ "$svc" = "all" ] && stop_pid gateway
    ;;
  restart)
    [ "$svc" = "gateway" ] || [ "$svc" = "all" ] && { stop_pid gateway; start_gateway; }
    [ "$svc" = "ttyd" ] || [ "$svc" = "all" ] && { stop_pid ttyd; start_ttyd; }
    [ "$svc" = "nginx" ] || [ "$svc" = "all" ] && { stop_nginx; start_nginx; }
    ;;
  status) status_of gateway; status_of ttyd; status_of nginx ;;
  *) echo "usage: $0 {start|stop|restart|status} {ttyd|gateway|nginx|all}"; exit 2 ;;
esac
sleep 0.5
true
