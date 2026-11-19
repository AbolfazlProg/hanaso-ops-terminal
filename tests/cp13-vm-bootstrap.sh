#!/usr/bin/env bash
# ==========================================================================
# CP13 — VM-side bootstrap (runs INSIDE the clean VM as uid 0).
#
# The build script (scripts/cp13-vm-build.sh) already:
#   * extracted the base set with `dpkg -x` (no chown — the userns cannot
#     apply setgid group ownership, dpkg --unpack fails with EINVAL there),
#   * merged the usr-merge legacy dirs (/bin /sbin /lib -> /usr/* symlinks),
#   * seeded /var/lib/dpkg/status (base packages -> install ok installed).
# The INSTALLER's packages (nginx, certbot — no special-permission files,
# verified by the build scan) install through the REAL apt/dpkg path later.
#
# This script only: verifies the base, warms apt, installs the systemctl
# shim (no live manager in this sandbox) and clones the test snapshot repo.
# ==========================================================================
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# VM-only identity artifact: this sandbox's user namespace maps exactly ONE
# uid/gid (0 -> the unprivileged host uid 1001). chown() to ANY other uid/gid
# fails with EINVAL, so the ops-gw service identity is pre-created here as
# uid/gid 0 (nologin). The real installer still verifies `id ops-gw` and
# skips its useradd; the ownership CONTRACT (root:ops-gw dirs, 0750/0640
# modes, nologin shell, unit User=ops-gw) is asserted by the battery. On a
# REAL VPS ops-gw gets its own unmapped-to-nothing uid/gid as usual.
if ! id ops-gw >/dev/null 2>&1; then
  groupadd -o -g 0 ops-gw 2>/dev/null || true
  useradd -o -u 0 -g 0 -M -d /var/lib/ops-terminal -s /usr/sbin/nologin ops-gw
  echo "[bootstrap] ops-gw pre-created (VM uid-map artifact: uid/gid 0, nologin)"
fi

DONE=/root/.cp13-bootstrap-done
if [ -f "$DONE" ]; then
  echo "[bootstrap] already done"
  exit 0
fi

echo "[bootstrap] 1/4 base identity check (fresh server: NO nginx, NO certbot)..."
dpkg -l base-files 2>/dev/null | grep -q "^ii" \
  || { echo "FATAL: dpkg status seeding failed"; exit 1; }
nginx --version >/dev/null 2>&1 && { echo "FATAL: nginx must NOT be preinstalled in the fresh VM"; exit 1; } || echo "  nginx: absent (correct)"
certbot --version >/dev/null 2>&1 && { echo "FATAL: certbot must NOT be preinstalled in the fresh VM"; exit 1; } || echo "  certbot: absent (correct)"
ldconfig
python3 -V
tmux -V
git --version
systemd-analyze --version | head -1
[ -e /bin/bash ] || { echo "FATAL: /bin/bash missing (usr-merge broken)"; exit 1; }

echo "[bootstrap] 2/4 apt update (offline flat mirror)..."
apt-get update

echo "[bootstrap] 3/4 apt sanity (dpkg/apt consistent, nothing broken)..."
apt-get check

echo "[bootstrap] 4/4 systemctl shim + runtime dirs..."
# clone the snapshot repo first (shim + supervisor come from it)
if [ ! -d /root/hanaso-ops-terminal/.git ]; then
  git clone -q /mnt/shared/repo.git /root/hanaso-ops-terminal
fi
# replace the real systemctl with the CP13 shim (no live manager possible
# inside this sandbox; see tests/cp13-systemctl-shim.sh header)
if [ ! -f /usr/bin/systemctl.real ]; then
  mv /usr/bin/systemctl /usr/bin/systemctl.real
fi
cp /root/hanaso-ops-terminal/tests/cp13-systemctl-shim.sh /usr/bin/systemctl
chmod 0755 /usr/bin/systemctl
mkdir -p /usr/libexec /run/systemd/system /run/cp13-ctl /mnt/shared/evidence
cp /root/hanaso-ops-terminal/tests/cp11-supervisor.py /usr/libexec/cp13-supervisor.py
chmod 0755 /usr/libexec/cp13-supervisor.py

# record the VM identity for the report
cat > /root/.cp13-identity.txt <<EOF
os: $(. /etc/os-release && echo "$PRETTY_NAME")
arch: $(uname -m)
python: $(python3 -V 2>&1)
tmux: $(tmux -V 2>&1)
git: $(git --version 2>&1)
systemd: $(systemd-analyze --version 2>/dev/null | head -1)
kernel-uid: 0-inside-userns (real host uid 1001, unprivileged)
EOF
cat /root/.cp13-identity.txt

touch "$DONE"
echo "[bootstrap] VM_BOOTSTRAP_DONE"
