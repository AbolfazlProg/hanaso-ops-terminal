#!/usr/bin/env bash
# ==========================================================================
# CP v1.3.1 — boot the clean Ubuntu 24.04 test VM (userns + chroot) and run a
# command inside it, WITH the signed mock mirrors bind-mounted at
# /opt/cp-mirrors (tests/cp-mirror-build-mocks.sh builds them).
#
# Same harness contract as tests/cp13-vm-run.sh:
#   * uid 0 inside the user namespace (real kernel uid stays 1001)
#   * own mount/pid/net namespace: lo up, /proc /sys /dev bound
#   * the CP13 offline flat mirror at /opt/mirror (pre-existing config)
#   * the CP v1.3.1 signed mock mirrors at /opt/cp-mirrors
#   * shared dir at /mnt/shared
# ==========================================================================
set -Eeuo pipefail

BASE=/home/z/my-project/vm-cp13
ROOT="$BASE/rootfs"
SHARED="$BASE/shared"
MOCKS="$BASE/cp-mirrors"

[ -f "$BASE/BUILD_DONE" ] || { echo "FATAL: VM not built"; exit 1; }
[ -d "$SHARED/repo.git" ] || { echo "FATAL: $SHARED/repo.git missing (run the sync step)"; exit 1; }
[ -d "$MOCKS/m1/ubuntu/dists/noble" ] || { echo "FATAL: mock mirrors missing — run tests/cp-mirror-build-mocks.sh"; exit 1; }

SRC="${1:-}"
[ -n "$SRC" ] && [ -f "$SRC" ] || { echo "usage: $0 <script-to-run-inside-the-vm>"; exit 2; }
BASENAME="$(basename "$SRC")"

if [ "$(readlink -f "$SRC")" != "$SHARED/$BASENAME" ]; then
  install -m 0755 "$SRC" "$SHARED/$BASENAME"
fi

exec unshare --user --map-root-user --mount --pid --fork --net /bin/bash -c '
  set -Eeuo pipefail
  ROOT="'$ROOT'"
  ip link set lo up
  ip addr add 10.0.0.1/32 dev lo label lo:0 2>/dev/null || true

  mkdir -p "$ROOT/proc" "$ROOT/sys" "$ROOT/dev/pts" "$ROOT/opt/mirror" "$ROOT/opt/cp-mirrors" "$ROOT/mnt/shared" "$ROOT/run"
  mount --rbind /proc "$ROOT/proc"
  mount --rbind /sys "$ROOT/sys"
  mount --rbind /dev "$ROOT/dev"
  mount -t devpts devpts "$ROOT/dev/pts" 2>/dev/null || true
  mount --bind /home/z/my-project/vm-cp13/mirror "$ROOT/opt/mirror"
  mount --bind /home/z/my-project/vm-cp13/cp-mirrors "$ROOT/opt/cp-mirrors"
  mount --bind /home/z/my-project/vm-cp13/shared "$ROOT/mnt/shared"
  mount -t tmpfs tmpfs "$ROOT/run"
  mkdir -p "$ROOT/run/systemd/system" "$ROOT/run/cp13-ctl"

  exec chroot "$ROOT" /bin/bash "/mnt/shared/'$BASENAME'" '${@:2}'
' "$@"
