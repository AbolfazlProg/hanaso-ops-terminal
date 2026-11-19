#!/usr/bin/env bash
# ==========================================================================
# CP13 — boot the clean Ubuntu 24.04 test VM (userns + chroot) and run a
# command inside it. Sandbox-side helper (test-only).
#
#   tests/cp13-vm-run.sh <script.sh>      # script must exist; copied into
#                                         # the VM as /mnt/shared/<name>
#
# Environment provided inside the VM:
#   * uid 0 (user namespace; the REAL kernel uid stays 1001 = unprivileged)
#   * own mount namespace: /proc /sys /dev /dev/pts mounted; the offline
#     apt mirror at /opt/mirror; the shared dir at /mnt/shared
#   * own PID namespace + own NET namespace with lo up (real :80/:443 binds)
#
# NOTE: no live systemd manager can run in this sandbox (read-only cgroup v1,
# see CP12 D23); the VM uses tests/cp13-systemctl-shim.sh + the unit-policy
# supervisor. Unit files are verified with the REAL Ubuntu systemd-analyze.
# ==========================================================================
set -Eeuo pipefail

BASE=/home/z/my-project/vm-cp13
ROOT="$BASE/rootfs"
SHARED="$BASE/shared"

[ -f "$BASE/BUILD_DONE" ] || { echo "FATAL: VM not built — run scripts/cp13-vm-build.sh"; exit 1; }
[ -d "$SHARED/repo.git" ] || { echo "FATAL: $SHARED/repo.git missing (run the sync step)"; exit 1; }

SRC="${1:-}"
[ -n "$SRC" ] && [ -f "$SRC" ] || { echo "usage: $0 <script-to-run-inside-the-vm>"; exit 2; }
BASENAME="$(basename "$SRC")"

# stage the script into the shared dir (bind-mounted into the VM)
if [ "$(readlink -f "$SRC")" != "$SHARED/$BASENAME" ]; then
  install -m 0755 "$SRC" "$SHARED/$BASENAME"
fi

exec unshare --user --map-root-user --mount --pid --fork --net /bin/bash -c '
  set -Eeuo pipefail
  ROOT="'$ROOT'"
  ip link set lo up
  # a global-scope address so getaddrinfo(AI_ADDRCONFIG) behaves like a real
  # server (a bare lo-only netns suppresses ahostsv4 results — VM-only quirk;
  # the real VPS has its public IP on an interface)
  ip addr add 10.0.0.1/32 dev lo label lo:0 2>/dev/null || true

  mkdir -p "$ROOT/proc" "$ROOT/sys" "$ROOT/dev/pts" "$ROOT/opt/mirror" "$ROOT/mnt/shared" "$ROOT/run"
  # NOTE: this kernel refuses FRESH proc mounts inside a userns (T1/T3 probes
  # recorded in the battery log) but allows binding the outer /proc — the VM
  # therefore sees the outer pid namespace via the bind (test-only tradeoff).
  mount --rbind /proc "$ROOT/proc"
  mount --rbind /sys "$ROOT/sys"
  mount --rbind /dev "$ROOT/dev"
  mount -t devpts devpts "$ROOT/dev/pts" 2>/dev/null || true
  mount --bind /home/z/my-project/vm-cp13/mirror "$ROOT/opt/mirror"
  mount --bind /home/z/my-project/vm-cp13/shared "$ROOT/mnt/shared"
  mount -t tmpfs tmpfs "$ROOT/run"
  mkdir -p "$ROOT/run/systemd/system" "$ROOT/run/cp13-ctl"

  exec chroot "$ROOT" /bin/bash "/mnt/shared/'$BASENAME'" '${@:2}'
' "$@"
