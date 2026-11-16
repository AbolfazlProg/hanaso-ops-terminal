#!/usr/bin/env bash
# ==========================================================================
# TEST-ONLY: (re)build the unprivileged sandbox toolchain for the batteries.
#
# This container is recycled between sessions: /home/z/sandbox-root and the
# test assets under /home/z/ops-sandbox-test disappear. The batteries need:
#   * nginx (Debian trixie build)            -> /home/z/sandbox-root
#   * haproxy 3.x + tmux 3.x + shared libs    -> /home/z/sandbox-root
#   * an Ubuntu jammy nginx-core 1.18 build whose compiled-in error log path
#     is /var/log/nginx/error.log (the build class the production VPS runs —
#     needed by tests/cp11-battery.sh to reproduce the REAL Finding-2 alert)
#   * test certificates (hanaso.pem = shared site, ops-panel.* = panel)
#
# Everything is extracted with dpkg -x into per-prefix trees and runs with
# LD_LIBRARY_PATH — no root, no system packages touched.
# ==========================================================================
set -euo pipefail
DEBS=/home/z/debs
SR=/home/z/sandbox-root
UB=/home/z/sandbox-root-ub
TEST=/home/z/ops-sandbox-test
LIBREL="usr/lib/x86_64-linux-gnu"

mkdir -p "$DEBS" "$SR" "$UB" "$TEST"
cd "$DEBS"

fetch() { # fetch <url> <outfile>
  [ -s "$2" ] && { echo "cached: $2"; return 0; }
  curl -fsSO --max-time 120 "$1"
  echo "fetched: $2"
}

# ---- Debian trixie toolchain (nginx 1.26, haproxy 3.0, tmux 3.5) ----------
apt-get download nginx nginx-common haproxy tmux libcrypt1 libpcre2-8-0 \
  libssl3t64 zlib1g libevent-core-2.1-7t64 libopentracing-c-wrapper0t64 \
  libopentracing1 libjemalloc2 liblua5.4-0 >/dev/null 2>&1 || true
for f in *.deb; do
  case "$f" in
    nginx_1.22*|nginx-core_*) continue ;;   # keep other-distro nginx out of SR
  esac
  dpkg -x "$f" "$SR/"
done

# ---- Ubuntu jammy nginx-core 1.18 (compiled-in /var/log/nginx/error.log) ---
fetch "http://archive.ubuntu.com/ubuntu/pool/main/n/nginx/nginx-core_1.18.0-6ubuntu14.22_amd64.deb" \
      "nginx-core_1.18.0-6ubuntu14.22_amd64.deb" || true
fetch "http://archive.ubuntu.com/ubuntu/pool/main/p/pcre3/libpcre3_8.39-9ubuntu0.1_amd64.deb" \
      "libpcre3_8.39-9ubuntu0.1_amd64.deb" || true
dpkg -x nginx-core_1.18.0-6ubuntu14.22_amd64.deb "$UB/"
dpkg -x libpcre3_8.39-9ubuntu0.1_amd64.deb       "$UB/" 2>/dev/null || true

# ---- shared-library sanity ------------------------------------------------
export LD_LIBRARY_PATH="$SR/$LIBREL:$SR/lib/x86_64-linux-gnu:$UB/$LIBREL:$UB/lib/x86_64-linux-gnu"
ok_all=1
for pair in "$SR/usr/sbin/nginx" "$SR/usr/sbin/haproxy" "$SR/usr/bin/tmux" "$UB/usr/sbin/nginx"; do
  if ldd "$pair" 2>/dev/null | grep -q "not found"; then
    echo "MISSING LIBS for $pair:"; ldd "$pair" | grep "not found"; ok_all=0
  fi
done
[ "$ok_all" = "1" ] || { echo "toolchain incomplete — see above"; exit 1; }

# ---- test certificates ----------------------------------------------------
if [ ! -s "$TEST/hanaso.pem" ]; then
  openssl req -x509 -newkey rsa:2048 -keyout "$TEST/shared.key" -out "$TEST/shared.crt" \
    -days 30 -nodes -subj "/CN=kotodama.ir" \
    -addext "subjectAltName=DNS:kotodama.ir,DNS:hanaso.ir" 2>/dev/null
  cat "$TEST/shared.crt" "$TEST/shared.key" > "$TEST/hanaso.pem"
  chmod 600 "$TEST/shared.key"
fi
if [ ! -s "$TEST/ops-panel.fullchain.pem" ] || [ ! -s "$TEST/ops-panel.key" ]; then
  openssl req -x509 -newkey rsa:2048 -keyout "$TEST/ops-panel.key" \
    -out "$TEST/ops-panel.fullchain.pem" -days 30 -nodes \
    -subj "/CN=ops.hanaso.ir" -addext "subjectAltName=DNS:ops.hanaso.ir" 2>/dev/null
  chmod 600 "$TEST/ops-panel.key"
fi

echo "== toolchain ready =="
"$SR/usr/sbin/nginx" -v 2>&1
"$SR/usr/sbin/haproxy" -v 2>&1 | head -1
"$SR/usr/bin/tmux" -V
"$UB/usr/sbin/nginx" -V 2>&1 | grep -oE "error-log-path=[^ ]+" | sed 's/^/ubuntu-nginx /'
ls -la "$TEST"/*.pem "$TEST/ops-panel.key" | sed 's/^/  /'
