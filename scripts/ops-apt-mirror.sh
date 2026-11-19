#!/usr/bin/env bash
# ==========================================================================
# HANASO OPS Web Terminal — APT Mirror Discovery & Fallback Engine (CP, v1.3.1)
#
# Production incident (v1.3.0, fresh Ubuntu 24.04 VPS):
#   E: Unable to locate package nginx
#   E: Unable to locate package certbot
#   [install][FATAL] apt-get install failed for: nginx certbot
#
# Empirically reproduced on Ubuntu 24.04 (tests/cp-incident-repro.sh): when
# the configured mirror is unreachable (Iran networks among others) or the
# sources are empty, `apt-get update` prints "W: Failed to fetch ..." and
# STILL EXITS 0. The old code trusted that exit code and ran
# `apt-get install` against an EMPTY package index -> "Unable to locate
# package". Exit codes alone are NEVER a proof of a usable mirror.
#
# This engine judges every mirror by REAL apt success only:
#   1. release metadata fetch (InRelease) from the mirror,
#   2. an ISOLATED real `apt-get update` (own lists dir) — apt itself
#      validates the Release/InRelease signature via apt-secure (the Ubuntu
#      keyring; never trusted=yes, never --allow-unauthenticated),
#   3. a real candidate check for EVERY package the installer needs
#      (nginx, certbot, ...) from the freshly fetched index,
#   4. only a mirror that passes ALL steps is applied.
#
# Candidate sources (in order):
#   0. the CURRENT apt configuration (least-change option: if it passes the
#      same real-apt test, nothing is rewritten at all),
#   1. the official Ubuntu Mirror Discovery service
#      (https://mirrors.ubuntu.com/mirrors.txt, geo-sorted),
#   2. the official Launchpad mirror registry
#      (https://launchpad.net/ubuntu/+archivemirrors),
#   3. a static fallback list of OFFICIAL (Canonical-operated) and
#      launchpad-REGISTERED mirrors (verified serving noble InRelease at
#      release time) — deliberately diverse, never 1-2 hardcoded domains.
# The first candidate that passes wins; every rejection is recorded with its
# reason. If ALL candidates fail, the engine emits a full APT MIRROR REPORT
# and returns 1 — the installer then stops BEFORE installing anything.
#
# Guarantees:
#   * existing apt files are backed up before ANY change,
#   * ONLY Ubuntu-archive entries are disabled/rewritten — third-party
#     repositories (docker, nodesource, ...) are never touched,
#   * sources written by this engine carry NO trusted=yes and NO
#     --allow-unauthenticated; signatures stay enforced (apt-secure),
#   * deb822 (ubuntu.sources, Ubuntu 24.04+) AND one-line sources.list are
#     both supported,
#   * binaries (nginx etc.) are installed ONLY via apt — never curl-piped,
#   * a full report (mirrors tried / rejection reasons / selected mirror /
#     update time / package candidates) is printed and archived;
#     NO secrets are ever logged.
#
# Test-only overrides (documented, never needed on a real VPS):
#   OPS_APT_FORCE_MIRRORS="uri1 uri2 ..."  replace discovery with this list
#   OPS_APT_UPDATE_TIMEOUT=120             per apt-get update attempt (s)
#   OPS_APT_PROBE_TIMEOUT=12               per InRelease curl probe (s)
#   OPS_APT_MAX_MIRRORS=10                 candidate cap after discovery
#   OPS_APT_EXTRA_UBUNTU_HOSTS="host1 host2"  provider-custom Ubuntu mirror
#                                          hostnames that must also count as
#                                          Ubuntu OS repos (rewritten/disabled
#                                          together with the standard hosts)
# ==========================================================================

# ------------------------------------------------------------- engine knobs --
APT_UPDATE_TIMEOUT="${OPS_APT_UPDATE_TIMEOUT:-120}"
APT_PROBE_TIMEOUT="${OPS_APT_PROBE_TIMEOUT:-12}"
APT_MAX_MIRRORS="${OPS_APT_MAX_MIRRORS:-10}"
APT_MIRROR_REPORT=""        # full detail file (set at runtime)
APT_SOURCES_TOUCHED=0       # rollback flag: this engine rewrote apt sources
APT_MIRROR_REPORT_LINES=()  # report buffer (printed + archived)

_amr() { # append one line to the report (stdout + buffer)
  printf '[apt-mirror] %s\n' "$*"
  APT_MIRROR_REPORT_LINES+=("$*")
}

_apt_mirror_save_report() {
  [ -n "${BACKUP_DIR:-}" ] || return 0
  mkdir -p "$BACKUP_DIR" 2>/dev/null || true
  APT_MIRROR_REPORT="$BACKUP_DIR/apt-mirror-report.txt"
  printf '%s\n' "${APT_MIRROR_REPORT_LINES[@]}" > "$APT_MIRROR_REPORT" 2>/dev/null || true
}

_apt_codename() {
  local cn=""
  [ -r /etc/os-release ] && cn="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | head -n1)"
  [ -n "$cn" ] || cn="$(lsb_release -cs 2>/dev/null || true)"
  printf '%s' "$cn"
}

_apt_arch() { dpkg --print-architecture 2>/dev/null || uname -m; }

# ----------------------------------------------------------- URI helpers --
_apt_trim_slash() { printf '%s' "${1%/}"; }

_apt_is_ubuntu_archive_uri() {
  # TRUE only for Ubuntu OS repository URIs (Canonical-operated archive
  # domains, file:/copy: local mirrors, and hosts the operator explicitly
  # declared via OPS_APT_EXTRA_UBUNTU_HOSTS — provider-custom Ubuntu mirrors).
  # Third-party repos (docker, nodesource, ...) NEVER match.
  local u; u="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  case "$u" in
    http://*archive.ubuntu.com/*|https://*archive.ubuntu.com/*|\
    http://*archive.ubuntu.com|https://*archive.ubuntu.com|\
    http://security.ubuntu.com/*|https://security.ubuntu.com/*|\
    http://security.ubuntu.com|https://security.ubuntu.com|\
    file:/*|copy:/*) return 0 ;;
  esac
  if [ -n "${APT_UBUNTU_EXTRA_HOST_RES:-}" ]; then
    # shellcheck disable=SC2086
    local h
    for h in ${APT_UBUNTU_EXTRA_HOST_RES}; do
      case "$u" in *"$h"*) return 0 ;; esac
    done
  fi
  return 1
}

# ------------------------------------------------- current-config parsing --
# Active "deb" entries of the CURRENT configuration (one-line + deb822).
# Prints "uri|suite|components" lines (suites/components space-separated).
_apt_parse_list_file() { # <file>
  awk '
    /^[[:space:]]*deb(-src)?[[:space:]]/ && $0 !~ /^[[:space:]]*#/ {
      if ($1 == "deb-src") next
      i=2
      if ($i ~ /^\[/) { while (i <= NF && $i !~ /\]$/) i++; i++ }
      uri=$i; suite=$(i+1); comps=""
      for (j=i+2; j<=NF; j++) comps=(comps (comps?" ":"") $j)
      if (uri != "" && suite != "") print uri "|" suite "|" comps
    }' "$1" 2>/dev/null
}

_apt_parse_sources_file() { # <file> deb822
  awk '
    BEGIN { types=""; uris=""; suites=""; comps="" }
    /^[[:space:]]*$/ || /^[[:space:]]*#/ {
      if (types ~ /deb/ && uris != "" && suites != "")
        print uris "|" suites "|" comps
      types=""; uris=""; suites=""; comps=""; next }
    {
      k=$1; sub(/:$/, "", k)
      if (k == "Types")      types=$2
      else if (k == "URIs")  { $1=""; sub(/^ /,""); uris=$0 }
      else if (k == "Suites"){ $1=""; sub(/^ /,""); suites=$0 }
      else if (k == "Components"){ $1=""; sub(/^ /,""); comps=$0 }
    }
    END {
      if (types ~ /deb/ && uris != "" && suites != "")
        print uris "|" suites "|" comps
    }' "$1" 2>/dev/null
}

_apt_current_entries() { # prints "uri|suite|components" for ACTIVE entries
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [ -r "$f" ] || continue
    _apt_parse_list_file "$f"
  done
  for f in /etc/apt/sources.list.d/*.sources; do
    [ -r "$f" ] || continue
    _apt_parse_sources_file "$f"
  done
}

# ------------------------------------------------------- candidate checks --
_apt_candidate_of() { # <pkg> [apt-cache -o overrides...]
  local p="$1"; shift
  apt-cache "$@" policy "$p" 2>/dev/null | awk '/^  Candidate:/{print $2; exit}' || true
}

# _apt_all_candidates_ok <pkg...> [apt-cache -o overrides...] -> 0 when EVERY
# package has a real candidate version (mission: judge by REAL apt success).
_apt_all_candidates_ok() {
  local pkgs=() a=() p v
  while [ $# -gt 0 ]; do
    case "$1" in
      -o) a+=("$1" "$2"); shift 2 ;;
      *) pkgs+=("$1"); shift ;;
    esac
  done
  for p in "${pkgs[@]}"; do
    v="$(_apt_candidate_of "$p" ${a[@]+"${a[@]}"})"
    [ -n "$v" ] && [ "$v" != "(none)" ] || return 1
  done
  return 0
}

# _apt_candidates_line <pkg...> [apt-cache -o overrides...] -> "nginx=1.2.3 certbot=..."
_apt_candidates_line() {
  local pkgs=() a=() p v out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -o) a+=("$1" "$2"); shift 2 ;;
      *) pkgs+=("$1"); shift ;;
    esac
  done
  for p in "${pkgs[@]}"; do
    v="$(_apt_candidate_of "$p" ${a[@]+"${a[@]}"})"
    out="$out $p=${v:-(none)}"
  done
  printf '%s' "${out# }"
}

# ------------------------------------------------------------ probe stage --
_apt_probe_release() { # <uri> <suite> -> 0 when InRelease fetches and looks Ubuntu
  local uri="$1" suite="$2" tmp rc
  case "$uri" in
    http://*|https://*)
      tmp="$(mktemp)" || return 1
      if curl -fsS -m "$APT_PROBE_TIMEOUT" "$uri/dists/$suite/InRelease" > "$tmp" 2>/dev/null; then
        rc=0
      else
        rc=$?
      fi
      if [ "$rc" = "0" ] && grep -q "^Origin: Ubuntu" "$tmp"; then
        rm -f "$tmp"; return 0
      fi
      rm -f "$tmp"
      case "$rc" in
        60) _APT_PROBE_REASON="TLS certificate verification failed (untrusted/expired cert)" ;;
        6)  _APT_PROBE_REASON="DNS resolution failed" ;;
        7)  _APT_PROBE_REASON="connection failed (unreachable/refused)" ;;
        28) _APT_PROBE_REASON="timed out after ${APT_PROBE_TIMEOUT}s" ;;
        22) _APT_PROBE_REASON="HTTP error (release metadata missing, e.g. 404)" ;;
        *)  _APT_PROBE_REASON="release metadata fetch failed (curl rc=$rc)" ;;
      esac
      return 1 ;;
    file:/*|copy:/*) return 0 ;;   # local mirrors: validated by apt itself below
    *) _APT_PROBE_REASON="unsupported scheme"; return 1 ;;
  esac
}

_apt_update_reason() { # <log-file> -> short failure reason
  local r
  r="$(grep -m1 -E '^(W:|E:|Err:)' "$1" 2>/dev/null | head -c 160 | tr '\n' ' ' || true)"
  [ -n "$r" ] || r="apt-get update failed (see isolated log)"
  printf '%s' "$r"
}

# ------------------------------------------------------------ discovery --
_apt_discover_candidates() { # fills APT_MIRROR_CANDIDATES (triples uri|suite|comps)
  local uris n u t
  APT_MIRROR_CANDIDATES=()
  APT_MIRROR_SRC_NOTE=()

  if [ -n "${OPS_APT_FORCE_MIRRORS:-}" ]; then
    # Test-only override (battery scenarios). Documented in the file header.
    # Entries are plain URIs; they get the system codename + main universe.
    local _f=() _c
    read -r -a _f <<< "${OPS_APT_FORCE_MIRRORS}" || true
    for _c in "${_f[@]}"; do
      APT_MIRROR_CANDIDATES+=("$(_apt_trim_slash "$_c")|${APT_DISC_SUITE:-}|${APT_DISC_COMPS:-main universe}")
    done
    APT_MIRROR_SRC_NOTE+=("forced-list(${#_f[@]} uris — test override)")
    return 0
  fi

  # source 1: official Mirror Discovery service (geo-sorted for this server)
  uris="$(curl -fsS -m 15 https://mirrors.ubuntu.com/mirrors.txt 2>/dev/null | tr -d '\r' | grep -E '^https?://' | head -20 || true)"
  if [ -n "$uris" ]; then
    n=0
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      APT_MIRROR_CANDIDATES+=("$(_apt_trim_slash "$u")|${APT_DISC_SUITE:-}|${APT_DISC_COMPS:-main universe}"); n=$((n+1))
      [ "$n" -ge 12 ] && break
    done <<< "$uris"
    APT_MIRROR_SRC_NOTE+=("mirrors.ubuntu.com(mirror-discovery, $n uris)")
  else
    APT_MIRROR_SRC_NOTE+=("mirrors.ubuntu.com(UNREACHABLE from this server — fallback used)")
  fi

  # source 2: official Launchpad mirror registry
  uris="$(curl -fsS -m 20 https://launchpad.net/ubuntu/+archivemirrors 2>/dev/null \
        | grep -oE 'https?://[a-zA-Z0-9._-]+/ubuntu/?' \
        | grep -vE 'launchpad\.net' | sort -u | head -20 || true)"
  if [ -n "$uris" ]; then
    n=0
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      APT_MIRROR_CANDIDATES+=("$(_apt_trim_slash "$u")|${APT_DISC_SUITE:-}|${APT_DISC_COMPS:-main universe}"); n=$((n+1))
      [ "$n" -ge 15 ] && break
    done <<< "$uris"
    APT_MIRROR_SRC_NOTE+=("launchpad-registry($n uris)")
  else
    APT_MIRROR_SRC_NOTE+=("launchpad-registry(UNREACHABLE from this server — fallback used)")
  fi

  # source 3: static fallback — official Canonical-operated geo mirrors +
  # launchpad-registered community mirrors (each verified serving
  # dists/noble/InRelease at release time; list is deliberately diverse).
  local D_S="${APT_DISC_SUITE:-}" D_C="${APT_DISC_COMPS:-main universe}"
  APT_MIRROR_CANDIDATES+=(
    "http://archive.ubuntu.com/ubuntu|$D_S|$D_C"
    "http://security.ubuntu.com/ubuntu|$D_S|$D_C"
    "http://ir.archive.ubuntu.com/ubuntu|$D_S|$D_C"
    "http://de.archive.ubuntu.com/ubuntu|$D_S|$D_C"
    "http://fr.archive.ubuntu.com/ubuntu|$D_S|$D_C"
    "http://uk.archive.ubuntu.com/ubuntu|$D_S|$D_C"
    "http://us.archive.ubuntu.com/ubuntu|$D_S|$D_C"
    "http://jp.archive.ubuntu.com/ubuntu|$D_S|$D_C"
    "http://mirrors.us.kernel.org/ubuntu|$D_S|$D_C"
    "http://mirror.us.leaseweb.net/ubuntu|$D_S|$D_C"
    "http://mirror.nl.leaseweb.net/ubuntu|$D_S|$D_C"
    "http://ubuntu.osuosl.org/ubuntu|$D_S|$D_C"
    "http://mirrors.tuna.tsinghua.edu.cn/ubuntu|$D_S|$D_C"
    "http://mirror.yandex.ru/ubuntu|$D_S|$D_C"
    "http://mirrors.cat.pdx.edu/ubuntu|$D_S|$D_C"
  )
  APT_MIRROR_SRC_NOTE+=("static-fallback(15 uris)")
}

# -------------------------------------------------------------- apply stage --
apt_mirror_rollback_sources() {
  # Called by the installer's rollback(): restores the pre-engine apt sources.
  [ "$APT_SOURCES_TOUCHED" = "1" ] || return 0
  local bd="${BACKUP_DIR:-}/apt-backup"
  [ -d "$bd" ] || return 0
  printf '[install][ROLLBACK] restoring apt sources from %s\n' "$bd" >&2
  if [ -f "$bd/sources.list" ]; then cp -a "$bd/sources.list" /etc/apt/sources.list; fi
  if [ -d "$bd/sources.list.d" ]; then
    local f
    while IFS= read -r f; do
      local base; base="$(basename "$f")"
      case "$base" in
        *.disabled-by-ops-terminal)
          mv "$bd/sources.list.d/$base" "/etc/apt/sources.list.d/${base%.disabled-by-ops-terminal}" ;;
        *) cp -a "$bd/sources.list.d/$base" "/etc/apt/sources.list.d/$base" 2>/dev/null ;;
      esac
    done < <(ls -A "$bd/sources.list.d" 2>/dev/null)
  fi
  rm -f /etc/apt/sources.list.d/00-hanaso-mirror.sources /etc/apt/sources.list.d/00-hanaso-mirror.list
  timeout "$APT_UPDATE_TIMEOUT" apt-get update >/dev/null 2>&1 || true
  APT_SOURCES_TOUCHED=0
}

_apt_apply_selected() { # <uri> <suite> <comps> -> 0 on success
  local uri="$1" suite="$2" comps="$3"
  local bd="${BACKUP_DIR:-}/apt-backup"
  mkdir -p "$bd/sources.list.d" /etc/apt/sources.list.d

  # ---- backup EVERYTHING we may touch (mission requirement) ----
  [ -f /etc/apt/sources.list ] && cp -a /etc/apt/sources.list "$bd/sources.list"
  local f
  while IFS= read -r f; do
    cp -a "/etc/apt/sources.list.d/$f" "$bd/sources.list.d/$f" || true
  done < <(ls -A /etc/apt/sources.list.d 2>/dev/null || true)

  # ---- disable ONLY Ubuntu-archive entries (single awk pass, surgical) ----
  # Third-party repositories (docker, nodesource, ...) NEVER match and stay
  # fully active. file:/copy: local Ubuntu mirrors count as Ubuntu repos.
  _apt_disable_ubuntu_lines() {
    awk '
      {
        line = $0
        if (line ~ /^[[:space:]]*deb(-src)?[[:space:]]/) {
          probe = line
          sub(/^[[:space:]]*deb(-src)?[[:space:]]+/, "", probe)
          gsub(/^\[[^]]*\][[:space:]]*/, "", probe)   # strip [options]
          split(probe, f, /[[:space:]]+/)
          uri = tolower(f[1])
          if (uri ~ /archive\.ubuntu\.com/ || uri ~ /security\.ubuntu\.com/ ||
              uri ~ /^file:/ || uri ~ /^copy:/ || uri ~ /'"$APT_UBUNTU_AWK_RE"'/) {
            print "# disabled-by-ops-terminal: " line
            next
          }
        }
        print line
      }' "$1"
  }
  if [ -f /etc/apt/sources.list ]; then
    local tmpf; tmpf="$(mktemp)" || return 1
    if _apt_disable_ubuntu_lines /etc/apt/sources.list > "$tmpf"; then
      mv "$tmpf" /etc/apt/sources.list
    else
      rm -f "$tmpf"; return 1
    fi
  fi
  for f in /etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] || continue
    if grep -qE '^[[:space:]]*deb(-src)?[[:space:]]' "$f" && \
       grep -qiE "(archive\.ubuntu\.com|security\.ubuntu\.com${APT_UBUNTU_GREP_ALT}|^[[:space:]]*deb[[:space:]].*(file:|copy:))" "$f"; then
      local tmpf2; tmpf2="$(mktemp)" || return 1
      if _apt_disable_ubuntu_lines "$f" > "$tmpf2"; then
        mv "$tmpf2" "$f"
      else
        rm -f "$tmpf2"; return 1
      fi
    fi
  done

  # deb822 files: disable whole file ONLY if it carries Ubuntu-archive URIs
  for f in /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] || continue
    if grep -qiE "(archive\.ubuntu\.com|security\.ubuntu\.com${APT_UBUNTU_GREP_ALT})" "$f" || grep -qiE '^URIs:.*(file:|copy:)' "$f"; then
      mv "$f" "$f.disabled-by-ops-terminal"
    fi
  done

  # ---- write the selected mirror (deb822 when the system used deb822) ----
  local style="list"
  if ls /etc/apt/sources.list.d/*.sources.disabled-by-ops-terminal >/dev/null 2>&1; then style="deb822"; fi
  if [ "$style" = "deb822" ]; then
    cat > /etc/apt/sources.list.d/00-hanaso-mirror.sources <<EOF
## Managed by hanaso-ops-terminal v1.3.1 APT mirror engine.
## Selected after a REAL apt validation (isolated apt-get update with full
## apt-secure signature enforcement + package candidate check).
## Original sources backed up in: $bd
Types: deb
URIs: $uri
Suites: $suite $suite-updates $suite-backports $suite-security
Components: $comps
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

EOF
  else
    cat > /etc/apt/sources.list.d/00-hanaso-mirror.list <<EOF
## Managed by hanaso-ops-terminal v1.3.1 APT mirror engine.
## Selected after a REAL apt validation (isolated apt-get update with full
## apt-secure signature enforcement + package candidate check).
## Original sources backed up in: $bd
deb $uri $suite $comps

EOF
  fi
  APT_SOURCES_TOUCHED=1
  _amr "sources rewritten: $style -> /etc/apt/sources.list.d/00-hanaso-mirror.$([ "$style" = "deb822" ] && echo sources || echo list) (backup: $bd)"
  return 0
}

# ----------------------------------------------------------- live checks --
verify_auth_request_live() { # <nginx-binary> -> REAL functional proof
  local ngx="$1" base try_ok=0 tmp conf p1 p2
  for base in 17691 27691 37691; do
    p1="$base"; p2=$((base+1))
    ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":$p1$" && continue
    ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":$p2$" && continue
    try_ok=1; break
  done
  [ "$try_ok" = "1" ] || return 1
  tmp="$(mktemp -d /tmp/ops-authreq.XXXXXX)" || return 1
  conf="$tmp/test.conf"
  # the protected location must do REAL content-phase work (a static file):
  # 'return' runs in the rewrite phase BEFORE the access phase and would make
  # auth_request a no-op (401-stub would wrongly answer 200).
  mkdir -p "$tmp/htdocs"
  printf 'AUTHREQ-LIVE-OK\n' > "$tmp/htdocs/protected"
  cat > "$conf" <<EOF
pid $tmp/nginx.pid;
error_log $tmp/error.log error;
worker_processes 1;
events { worker_connections 16; }
http {
  access_log off;
  server {
    listen 127.0.0.1:$p1;
    location = /_auth { return 401; }
    location = /protected { auth_request /_auth; root $tmp/htdocs; }
  }
  server {
    listen 127.0.0.1:$p2;
    location = /_auth { return 200; }
    location = /protected { auth_request /_auth; root $tmp/htdocs; }
  }
}
EOF
  # if the module were missing, THIS nginx -t fails ("unknown directive")
  "$ngx" -t -c "$conf" -p "$tmp" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  "$ngx" -c "$conf" -p "$tmp" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  local ok=1 c1 c2
  for _ in 1 2 3 4 5; do
    c1="$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$p1/protected" 2>/dev/null || true)"
    [ "$c1" = "401" ] && break
    sleep 0.3
  done
  c1="$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$p1/protected" 2>/dev/null || true)"
  c2="$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$p2/protected" 2>/dev/null || true)"
  [ "$c1" = "401" ] || ok=0
  [ "$c2" = "200" ] || ok=0
  "$ngx" -c "$conf" -p "$tmp" -s quit >/dev/null 2>&1 || true
  rm -rf "$tmp"
  [ "$ok" = "1" ] || return 1
  return 0
}

# ============================================================ MAIN ENTRY ====
# apt_mirror_engine <pkg...> — selects a healthy mirror by REAL apt success
# and leaves the system ready for `apt-get install <pkg...>`.
# Returns 1 (fail-closed, NOTHING installed, sources restored-able) when no
# mirror passes.
apt_mirror_engine() {
  local want=("$@")
  [ "${#want[@]}" -gt 0 ] || return 0
  local suite codename comps comps_probe arch
  codename="$(_apt_codename)"
  arch="$(_apt_arch)"
  if [ -z "$codename" ]; then
    _amr "FATAL: could not determine the Ubuntu codename (/etc/os-release)"
    return 1
  fi
  suite="$codename"
  comps_probe="main universe"
  APT_DISC_SUITE="$codename"      # discovery candidates use the system codename
  APT_DISC_COMPS="main universe"
  # operator-declared custom Ubuntu mirror hosts (provider images)
  APT_UBUNTU_EXTRA_HOST_RES=""
  APT_UBUNTU_AWK_RE="___never___"      # NEVER an empty regex (would match all)
  APT_UBUNTU_GREP_ALT=""
  if [ -n "${OPS_APT_EXTRA_UBUNTU_HOSTS:-}" ]; then
    APT_UBUNTU_EXTRA_HOST_RES="$(printf '%s\n' ${OPS_APT_EXTRA_UBUNTU_HOSTS} | tr 'A-Z' 'a-z' | tr '\n' ' ' | sed 's/  */ /g;s/^ //;s/ $//')"
    APT_UBUNTU_AWK_RE="$(printf '%s' "$APT_UBUNTU_EXTRA_HOST_RES" | sed 's/ /|/g')"
    APT_UBUNTU_GREP_ALT="|$APT_UBUNTU_AWK_RE"
    _amr "extra-ubuntu-hosts: ${APT_UBUNTU_EXTRA_HOST_RES}"
  fi

  _amr "================ APT MIRROR REPORT ================"
  _amr "codename=$codename arch=$arch packages=${want[*]}"
  _amr "policy: mirrors judged by REAL apt success only (InRelease fetch + isolated apt-get update with apt-secure signature enforcement + package candidate check)"

  # ---- current components (union), ensure main+universe for the rewrite ----
  local comps_union="" e c s u
  while IFS='|' read -r e s u; do
    [ -n "$u" ] || continue
    comps_union="$comps_union $u"
  done < <(_apt_current_entries)
  comps_union="$(printf '%s ' $comps_union | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/  */ /g;s/^ //;s/ $//')"
  comps="$comps_union"
  case " $comps " in *" main "*) ;; *) comps="main${comps:+ $comps}";; esac
  case " $comps " in *" universe "*) ;; *) comps="${comps:+$comps }universe";; esac
  _amr "rewrite-components: ${comps:-(none seen)} (probe components: $comps_probe)"

  # ---- stage 0: candidates ----
  # cur_uris: plain URIs (selection bookkeeping); cur_triples: "uri|suite|comps"
  # probed with their OWN suite/components — a flat './' local mirror is NOT
  # the codename suite.
  local cur_uris=() cur_triples=() seen=" " cands=() u e s c
  while IFS='|' read -r e s c; do
    for u in $e; do
      u="$(_apt_trim_slash "$u")"
      cur_uris+=("$u")
      cur_triples+=("$u|$s|$c")
    done
  done < <(_apt_current_entries)
  [ "${#cur_uris[@]}" -gt 0 ] && _amr "candidate-source current-config: ${#cur_uris[@]} uri(s)"

  _apt_discover_candidates
  local note
  for note in "${APT_MIRROR_SRC_NOTE[@]}"; do
    _amr "candidate-source $note"
  done

  # dedupe (by URI): current-config first, then discovery order; cap APT_MAX_MIRRORS
  # every candidate is a TRIPLE "uri|suite|comps" — current-config entries are
  # probed with their OWN suite/components (a flat ./ mirror is NOT noble)
  cands=()
  for t in "${cur_triples[@]}"; do
    u="${t%%|*}"
    case "$seen" in *" $u "*) ;; *) cands+=("$t"); seen="$seen$u " ;; esac
  done
  for t in "${APT_MIRROR_CANDIDATES[@]:-}"; do
    [ "${#cands[@]}" -ge "$APT_MAX_MIRRORS" ] && break
    [ -n "$t" ] || continue
    u="${t%%|*}"
    case "$seen" in *" $u "*) ;; *) cands+=("$t"); seen="$seen$u " ;; esac
  done
  _amr "probe queue (${#cands[@]}): $(printf '%s ' "${cands[@]}" | sed 's/|[^|]*|[^|]*//g;s/  */ /g')"

  # ---- probe loop: REAL apt decides ----
  local sel="" sel_suite="" sel_comps="" start dur logf reason cand_ver
  local c_u c_suite c_comps
  for t in "${cands[@]}"; do
    IFS='|' read -r c_u c_suite c_comps <<< "$t"
    start="$(date +%s)"
    if ! _apt_probe_release "$c_u" "${c_suite:-$suite}"; then
      reason="${_APT_PROBE_REASON:-release metadata fetch failed}"
      _amr "TEST $c_u -> REJECT reason=$reason"
      continue
    fi
    logf="$(mktemp /tmp/ops-aptup.XXXXXX)"
    local probe_list probe_lists
    probe_list="$(mktemp /tmp/ops-aptlist.XXXXXX)"
    probe_lists="$(mktemp -d /tmp/ops-aptlists.XXXXXX)"
    if [ -n "${c_comps:-}" ]; then
      printf 'deb %s %s %s\n' "$c_u" "${c_suite:-$suite}" "$c_comps" > "$probe_list"
    else
      printf 'deb %s %s\n' "$c_u" "${c_suite:-$suite}" > "$probe_list"
    fi
    mkdir -p "$probe_lists/partial"
    if timeout "$APT_UPDATE_TIMEOUT" apt-get update \
         -o Dir::Etc::sourcelist="$probe_list" \
         -o Dir::Etc::sourceparts=/dev/null \
         -o Dir::State::lists="$probe_lists" \
         > "$logf" 2>&1; then
      if _apt_all_candidates_ok "${want[@]}" \
           -o Dir::State::lists="$probe_lists" \
           -o Dir::Etc::sourcelist="$probe_list" \
           -o Dir::Etc::sourceparts=/dev/null; then
        dur=$(( $(date +%s) - start ))
        _amr "TEST $c_u -> PASS (apt-get update OK in ${dur}s, signatures verified by apt-secure, all ${#want[@]} package(s) present)"
        cand_ver="$(_apt_candidates_line "${want[@]}" \
                      -o Dir::State::lists="$probe_lists" \
                      -o Dir::Etc::sourcelist="$probe_list" \
                      -o Dir::Etc::sourceparts=/dev/null)"
        _amr "candidates($c_u): $cand_ver"
        sel="$c_u"; sel_suite="${c_suite:-$suite}"; sel_comps="${c_comps:-$comps_probe}"
        rm -f "$logf" "$probe_list"; rm -rf "$probe_lists"
        break
      fi
      reason="apt-get update OK but package candidate(s) MISSING/INCOMPLETE: $(_apt_candidates_line "${want[@]}" -o Dir::State::lists="$probe_lists" -o Dir::Etc::sourcelist="$probe_list" -o Dir::Etc::sourceparts=/dev/null 2>/dev/null || echo '?')"
      _amr "TEST $c_u -> REJECT reason=$reason"
    else
      reason="apt-get update failed after signature/candidate validation attempt: $(_apt_update_reason "$logf")"
      _amr "TEST $c_u -> REJECT reason=$reason"
    fi
    rm -f "$logf" "$probe_list"; rm -rf "$probe_lists"
  done

  if [ -z "$sel" ]; then
    _amr "RESULT: NO healthy mirror found — fail-closed, NOTHING will be installed"
    _amr "===================================================="
    _apt_mirror_save_report
    return 1
  fi

  # ---- apply: backup + rewrite ONLY Ubuntu entries (unless current passed) ----
  local is_current=0
  for u in "${cur_uris[@]}"; do [ "$u" = "$sel" ] && is_current=1; done
  if [ "$is_current" = "1" ]; then
    # the current configuration passed the REAL apt test — zero changes
    _amr "selected mirror: $sel (CURRENT CONFIG passed — no rewrite needed)"
  else
    # the rewrite ALWAYS writes the standard OS suites (codename, updates,
    # backports, security) with the merged components — even when the probed
    # entry used a narrower suite (e.g. a provider flat mirror)
    _apt_apply_selected "$sel" "$suite" "$comps" || {
      _amr "FATAL: rewriting apt sources failed — fail-closed"
      _amr "===================================================="
      _apt_mirror_save_report
      return 1
    }
    _amr "selected mirror: $sel (rewritten into apt sources)"
  fi

  # ---- final REAL update on the live configuration + candidate proof ----
  start="$(date +%s)"
  local finrc=1 fin_try
  for fin_try in 1 2; do
    if timeout "$APT_UPDATE_TIMEOUT" apt-get update > /tmp/ops-apt-final-update.log 2>&1; then finrc=0; break; fi
    sleep 1
  done
  dur=$(( $(date +%s) - start ))
  if [ "$finrc" != "0" ]; then
    # a broken THIRD-PARTY source must not kill the install when the selected
    # Ubuntu mirror really delivered its index — the candidate check decides.
    _amr "WARN: final apt-get update rc!=0 after ${dur}s (some source failed): $(_apt_update_reason /tmp/ops-apt-final-update.log)"
    if ! _apt_all_candidates_ok "${want[@]}"; then
      _amr "FATAL: candidate check failed on live sources: $(_apt_candidates_line "${want[@]}")"
      _amr "===================================================="
      _apt_mirror_save_report
      return 1
    fi
    _amr "candidates(live): $(_apt_candidates_line "${want[@]}") — PROVEN despite the partial update failure"
  else
    _amr "final apt-get update OK in ${dur}s (live sources)"
    if ! _apt_all_candidates_ok "${want[@]}"; then
      _amr "FATAL: candidate check failed on live sources: $(_apt_candidates_line "${want[@]}")"
      _amr "===================================================="
      _apt_mirror_save_report
      return 1
    fi
    _amr "candidates(live): $(_apt_candidates_line "${want[@]}")"
  fi
  _amr "===================================================="
  _apt_mirror_save_report
  return 0
}
