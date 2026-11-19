#!/usr/bin/env bash
# ==========================================================================
# HANASO OPS Web Terminal — safe env-file serialization + strict parser
#
# WHY THIS EXISTS (incident 2026-11-16):
#   /tmp/ops-preflight.env was written with UNQUOTED values. A value that
#   contains spaces (e.g. PREFLIGHT_HOST_IPS="87.107.129.210 172.18.0.1",
#   public IP + docker bridge gateway) is two words when the file is
#   `source`d: bash assigns the first word and EXECUTES the second:
#       /tmp/ops-preflight.env: line 22: 172.18.0.1: command not found
#   -> install FATAL -> premature rollback.
#
# RULES (both sides):
#   * WRITER: every value is single-quoted with `'\''` escaping; values
#     containing newlines are REJECTED (line-based format).
#   * READER: never `source`s, never `eval`s. Line-by-line KEY='VALUE'
#     parse, per-key whitelist validation, unknown keys are FATAL.
#   * A correctly written file is ALSO inert when sourced by a legacy
#     consumer (quoted shell assignment), but install.sh itself never
#     sources it.
#   * EMPTY VALUES: legal for keys whose regex ends in `*` (e.g.
#     PREFLIGHT_CERT_PATH='' — the "no covering certificate yet" state that
#     routes install.sh to the certbot issuance branch). The validator
#     feeds the value to grep WITH a trailing newline so an empty value is
#     still one (empty) LINE for the anchored regex — an empty stdin would
#     produce zero lines and grep would reject EVERYTHING (CP10 incident
#     2026-11-17). Regexes with `+`/literals still reject empty.
# ==========================================================================

# --------------------------------------------------------------------------
# ops_env_quote VALUE -> prints the shell-safe quoted form '...'
# --------------------------------------------------------------------------
ops_env_quote() {
  local v="${1-}"
  case "$v" in
    *$'\n'*|*$'\r'*)
      printf '%s\n' "ops-env: refusing to serialize multi-line value" >&2
      return 1
      ;;
  esac
  printf "'%s'" "${v//\'/\'\\\'\'}"
}

# --------------------------------------------------------------------------
# ops_env_kv KEY VALUE [FILE]  — append KEY='VALUE' to FILE (default $OPS_ENV_OUT)
# --------------------------------------------------------------------------
ops_env_kv() {
  local key="$1" val="${2-}" file="${3:-${OPS_ENV_OUT:-/dev/null}}"
  case "$key" in
    [A-Z_][A-Z0-9_]*) ;;
    *) printf '%s\n' "ops-env: invalid key: $key" >&2; return 1 ;;
  esac
  local quoted
  quoted="$(ops_env_quote "$val")" || return 1
  printf '%s=%s\n' "$key" "$quoted" >> "$file"
}

# --------------------------------------------------------------------------
# ops_env_unquote RAW -> prints the plain value (accepts quoted or bare form)
# --------------------------------------------------------------------------
ops_env_unquote() {
  local v="${1-}"
  case "$v" in
    "'"*"'")
      v="${v#\'}"        # strip leading quote
      v="${v%\'}"        # strip trailing quote
      v="${v//\'\\\'\'/\'}"   # unescape '\'' -> '
      ;;
  esac
  printf '%s' "$v"
}

# --------------------------------------------------------------------------
# per-key validation (whitelist). Unknown keys are FATAL (fail closed so the
# writer and reader of this repo always ship as a pair).
# --------------------------------------------------------------------------
ops_env_validate() {
  local key="$1" val="$2"
  local re
  case "$key" in
    PREFLIGHT_DOMAIN)                    re='^[A-Za-z0-9.-]+$' ;;
    PREFLIGHT_OS)                        re='^[a-z]+$' ;;
    PREFLIGHT_OS_VERSION)                re='^[0-9.]+$' ;;
    PREFLIGHT_TOPOLOGY)                  re='^(nginx-direct|haproxy-front|haproxy-tcp-passthrough|standalone|unknown)$' ;;
    PREFLIGHT_HAPROXY_VERSION)           re='^[0-9.]+$' ;;
    PREFLIGHT_HAPROXY_BIND_MODE)         re='^(ssl-term|tcp-passthrough|unknown)$' ;;
    PREFLIGHT_HAPROXY_CRT_STYLE)         re='^(dir|file|crt-list|none)$' ;;
    PREFLIGHT_HAPROXY_CRT_PATH)          re='^[A-Za-z0-9_./-]*$' ;;
    PREFLIGHT_HAPROXY_FRONTEND)          re='^[A-Za-z0-9_.-]*$' ;;
    PREFLIGHT_HAPROXY_RELOAD)            re='^(systemd|pidfile|none)$' ;;
    PREFLIGHT_HAPROXY_ACME_ROUTED)       re='^[01]$' ;;
    PREFLIGHT_HAPROXY_HTTP80)             re='^[01]$' ;;
    PREFLIGHT_HAPROXY_OPS_CERT_EXISTS)   re='^[01]$' ;;
    PREFLIGHT_NGINX_BIN|PREFLIGHT_HAPROXY_CFG|PREFLIGHT_CERTBOT| \
    PREFLIGHT_PYTHON|PREFLIGHT_TMUX|PREFLIGHT_NGINX_VHOST_DIR| \
    PREFLIGHT_NGINX_ENABLE_DIR|PREFLIGHT_CERT_PATH|PREFLIGHT_CERT_KEY)
                                          re='^[A-Za-z0-9_./-]*$' ;;
    PREFLIGHT_IS_ROOT|PREFLIGHT_SYSTEMD|PREFLIGHT_NGINX_AUTH_REQUEST| \
    PREFLIGHT_NGINX_PRESENT|PREFLIGHT_APT_OK| \
    PREFLIGHT_PYTHON_OK|PREFLIGHT_CURL|PREFLIGHT_EXISTING_VHOST| \
    PREFLIGHT_EXISTING_INSTALL|PREFLIGHT_DNS_MATCH|PREFLIGHT_BBB| \
    PREFLIGHT_PORT_80_FREE|PREFLIGHT_PORT_443_FREE| \
    PREFLIGHT_PORT_7681_FREE|PREFLIGHT_PORT_7682_FREE|PREFLIGHT_PORT_7680_FREE)
                                          re='^[01]$' ;;
    PREFLIGHT_ARCH)                       re='^[A-Za-z0-9_-]*$' ;;
    PREFLIGHT_DNS_IPS|PREFLIGHT_HOST_IPS)  re='^([0-9]{1,3}\.){3}[0-9]{1,3}( ([0-9]{1,3}\.){3}[0-9]{1,3})* *$|^(ipv6:)?[0-9A-Fa-f:]*$' ;;
    *) printf '%s\n' "ops-env: unknown key (fail closed): $key" >&2; return 1 ;;
  esac
  # CP10: append a newline so an EMPTY value is one empty line for grep.
  # `printf '%s' '' | grep -qE ...` sees ZERO lines and rejects everything,
  # even patterns whose `*` explicitly allows empty (the CP10 incident).
  if ! printf '%s\n' "$val" | grep -qE -- "$re"; then
    printf '%s\n' "ops-env: value for $key rejected by validation (re: $re)" >&2
    return 1
  fi
  return 0
}

# --------------------------------------------------------------------------
# ops_env_read FILE — strict parse into the CALLER's environment.
# No sourcing, no eval; unknown/invalid lines are FATAL.
# --------------------------------------------------------------------------
ops_env_read() {
  local file="$1" line key raw val
  [ -r "$file" ] || { printf '%s\n' "ops-env: cannot read $file" >&2; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    key="${line%%=*}"
    if [ "$key" = "$line" ]; then
      printf '%s\n' "ops-env: line without '=' ( refusing to execute ): ${line:0:60}" >&2
      return 1
    fi
    raw="${line#*=}"
    val="$(ops_env_unquote "$raw")"
    ops_env_validate "$key" "$val" || return 1
    printf -v "$key" '%s' "$val"
  done < "$file"
  return 0
}
