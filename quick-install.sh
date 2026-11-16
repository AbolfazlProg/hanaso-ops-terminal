#!/usr/bin/env bash
# ==========================================================================
# HANASO OPS Web Terminal — one-line remote installer (bootstrap)
#
# THE ONE-LINER (on the VPS, as root):
#   curl -fsSL https://raw.githubusercontent.com/AbolfazlProg/hanaso-ops-terminal/main/quick-install.sh \
#     | bash -s -- --domain ops.hanaso.ir --acme-email admin@hanaso.ir
#
# What this bootstrap does:
#   1. fetches the repository (git clone --depth 1 preferred; codeload
#      tarball fallback when git is not installed),
#   2. verifies the repository's SHA256SUMS integrity manifest (fail-closed),
#   3. refuses to run as non-root unless --sandbox is forwarded (test mode),
#   4. runs scripts/install.sh with every argument forwarded VERBATIM.
#
# ALL command-line arguments are forwarded to scripts/install.sh untouched —
# the bootstrap itself is configured ONLY through environment variables:
#
#   QUICK_INSTALL_REPO      git URL or OWNER/REPO slug   (default: this repo)
#   QUICK_INSTALL_REF       branch or tag to install     (default: main)
#   QUICK_INSTALL_SKIP_SHA  set to 1 to skip the SHA256SUMS check (NOT recommended)
#
# Pin a release:
#   curl -fsSL https://raw.githubusercontent.com/AbolfazlProg/hanaso-ops-terminal/main/quick-install.sh \
#     | QUICK_INSTALL_REF=v1.0.0 bash -s -- --domain ops.hanaso.ir
#
# The full flag list of the real installer (--domain, --acme-email,
# --tls-cert/--tls-key, --http-port/--https-port, --yes, --sandbox,
# --sandbox-topology haproxy, ...) is documented in scripts/install.sh.
#
# NOTE ON TRUST: piping a remote script into bash trusts GitHub + TLS.
# For a fully pinned, reviewable install, clone the repo, verify
# SHA256SUMS yourself, then run scripts/install.sh directly (see
# docs/INSTALL.md).
# ==========================================================================
set -Eeuo pipefail

die()  { printf '\n[quick-install][FATAL] %s\n' "$*" >&2; exit 1; }
note() { printf '[quick-install] %s\n' "$*"; }

REPO="${QUICK_INSTALL_REPO:-https://github.com/AbolfazlProg/hanaso-ops-terminal.git}"
REF="${QUICK_INSTALL_REF:-main}"

# ---------------------------------------------------------- sanity checks --
for cmd in bash; do command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required"; done

# The real installer needs root on a VPS; --sandbox is the unprivileged test
# harness that walks the very same code paths (see tests/run-battery.sh).
want_sandbox=0
for a in "$@"; do [ "$a" = "--sandbox" ] && want_sandbox=1; done
if [ "$(id -u)" -ne 0 ] && [ "$want_sandbox" -ne 1 ]; then
  die "must run as root on the VPS (or forward --sandbox for the unprivileged test mode)"
fi

command -v git >/dev/null 2>&1 || note "git not found — will fetch the tarball with curl"

# ------------------------------------------------------------ fetch repo ---
WORK="$(mktemp -d /tmp/ops-terminal-quick.XXXXXX)"
KEEP=0
trap '[ "$KEEP" = 1 ] || rm -rf "$WORK"' EXIT

note "repository : $REPO"
note "reference  : $REF"

SRC=""
if command -v git >/dev/null 2>&1; then
  if git clone --quiet --depth 1 --branch "$REF" "$REPO" "$WORK/repo" 2>/dev/null; then
    SRC="$WORK/repo"
  fi
fi
if [ -z "$SRC" ]; then
  # derive OWNER/REPO for the codeload tarball endpoints
  slug="$REPO"
  case "$REPO" in
    https://github.com/*|http://github.com/*) slug="${REPO#*://github.com/}" ;;
    git@github.com:*)                         slug="${REPO#git@github.com:}" ;;
  esac
  slug="${slug%.git}"
  case "$slug" in */*) ;; *) die "QUICK_INSTALL_REPO must be a git URL or OWNER/REPO (got: $REPO)";; esac
  command -v curl >/dev/null 2>&1 || die "neither git nor curl is available to fetch the repository"
  command -v tar  >/dev/null 2>&1 || die "tar is required for the tarball fallback"
  mkdir -p "$WORK/repo"
  if ! curl -fsSL "https://codeload.github.com/$slug/tar.gz/refs/heads/$REF" \
       | tar -xz --strip-components=1 -C "$WORK/repo"; then
    curl -fsSL "https://codeload.github.com/$slug/tar.gz/refs/tags/$REF" \
      | tar -xz --strip-components=1 -C "$WORK/repo" \
      || die "could not fetch '$REF' from github.com/$slug (branch nor tag)"
  fi
  SRC="$WORK/repo"
fi

VERSION="$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo "$REF (tarball)")"
note "fetched    : commit $VERSION"

# ---------------------------------------------------- integrity manifest --
[ -f "$SRC/SHA256SUMS" ] || die "integrity manifest (SHA256SUMS) missing in the fetched tree"
if [ "${QUICK_INSTALL_SKIP_SHA:-0}" = "1" ]; then
  note "WARNING: SHA256SUMS verification SKIPPED by QUICK_INSTALL_SKIP_SHA=1"
else
  command -v sha256sum >/dev/null 2>&1 \
    || die "sha256sum not available — set QUICK_INSTALL_SKIP_SHA=1 to override (not recommended)"
  note "verifying SHA256SUMS integrity manifest ..."
  if ! ( cd "$SRC" && sha256sum -c SHA256SUMS >/dev/null 2>"$WORK/sha.err" ); then
    KEEP=1
    printf '\n[quick-install][FATAL] SHA256SUMS verification FAILED — the fetched tree is not intact:\n' >&2
    grep -E 'FAILED|WARNING' "$WORK/sha.err" | sed 's/^/    /' >&2 || true
    printf '    fetched tree kept for inspection: %s\n\n' "$SRC" >&2
    exit 1
  fi
  note "SHA256SUMS: OK"
fi

[ -f "$SRC/scripts/install.sh" ] || die "scripts/install.sh missing in the fetched tree"

# ------------------------------------------------- hand stdin back to tty --
# `curl | bash` feeds this script itself on stdin; the real installer may
# want to prompt (default is an interactive confirmation). Re-attach stdin
# to the controlling terminal when one exists, else neutralise it.
if ( exec 0</dev/tty ) 2>/dev/null; then exec 0</dev/tty; else exec 0</dev/null; fi

# ------------------------------------------------------- run the installer --
note "starting installer (arguments forwarded verbatim) ..."
rc=0
bash "$SRC/scripts/install.sh" "$@" || rc=$?

if [ "$rc" -ne 0 ]; then
  KEEP=1
  printf '\n[quick-install] installer exited rc=%s\n' "$rc" >&2
  printf '[quick-install] fetched tree kept for inspection: %s\n' "$SRC" >&2
  printf '[quick-install] rollback state/logs: see installer output above (/var/backups/ops-terminal on a VPS)\n' >&2
else
  note "installer finished successfully — removing the temporary clone"
fi
exit "$rc"
