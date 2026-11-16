#!/usr/bin/env bash
# ==========================================================================
# HANASO OPS Web Terminal — HAProxy configuration helpers (shared lib)
#
# Read-only analysis + marker-block editing of haproxy.cfg. Every edit is
# followed by `haproxy -c` validation by the caller; managed blocks are
# delimited by BEGIN/END comments so removal is surgical (only this
# panel's lines are ever touched).
# Marker lines are ALWAYS at column 0 so `sed`/`awk` can match them safely.
# ==========================================================================

# ha_find_bind_section CFG PORT -> "name|lineno|first-bind-line"
#   Finds the first frontend/listen section that binds PORT and returns its
#   name, header line number and the first bind line containing :PORT.
ha_find_bind_section() {
  [ -r "$1" ] || return 1
  awk -v port=":$2" '
    function flush() { if (sect != "" && bind != "") {
      printf "%s|%d|%s\n", sect, sectline, bind } }
    /^[[:space:]]*(frontend|listen)[[:space:]]/ { flush(); sect=$2; sectline=NR; bind=""; next }
    /^[[:space:]]*(backend|defaults|global|peers|resolvers|mailers|caches|userlist|abeers)[[:space:]]/ { flush(); sect=""; next }
    sect != "" && /^[[:space:]]*bind[[:space:]][^#]*/ {
      line=$0
      gsub(/[[:space:]]+$/, "", line)
      # :PORT must be followed by end, whitespace or comma
      if (line ~ (port "([[:space:]]|$|,)")) { if (bind == "") bind=line }
    }
    END { flush() }
  ' "$1" 2>/dev/null
}

# ha_bind_ssl BINDLINE -> 0/1 (bind line terminates TLS itself)
ha_bind_ssl() {
  printf '%s' "$1" | tr -s '[:space:]' ' ' \
    | grep -qE '(^| )ssl( |$)' && return 0 || return 1
}

# ha_bind_crt BINDLINE -> "crt|/path" | "crt-list|/path" | "" (none)
ha_bind_crt() {
  printf '%s' "$1" | tr -s '[:space:]' ' ' | awk '{
    for (i=1;i<NF;i++) if ($i=="crt" || $i=="crt-list")
      { print $i "|" $(i+1); exit }
  }'
}

# ha_version_major BIN -> major version number (e.g. 3)
ha_version_major() {
  "$1" -v 2>/dev/null | awk '{print $3}' | awk -F. '{print $1+0; exit}'
}

# ha_haproxy_check BIN CFG -> validates config (exit code of haproxy -c)
ha_haproxy_check() {
  [ -x "$1" ] && [ -r "$2" ] || return 1
  "$1" -c -q -f "$2" >/dev/null 2>&1
}

# ha_section_text CFG NAME -> prints the body of section NAME (no header)
ha_section_text() {
  [ -r "$1" ] || return 1
  awk -v want="$2" '
    /^[[:space:]]*(frontend|listen)[[:space:]]/ { on=($2==want)?1:0; next }
    /^[[:space:]]*(backend|defaults|global|frontend|listen|peers|resolvers|mailers|caches|userlist)[[:space:]]/ { on=0 }
    on { print }
  ' "$1" 2>/dev/null
}

# ha_remove_managed CFG -> removes every BEGIN/END ops-terminal block IN PLACE.
#   Returns the number of blocks removed. Never touches anything else.
ha_remove_managed() {
  local cfg="$1" n
  n="$(grep -c '^# BEGIN ops-terminal' "$cfg" 2>/dev/null || true)"
  [ "${n:-0}" -gt 0 ] || { printf '%s' 0; return 0; }
  sed -i '/^# BEGIN ops-terminal/,/^# END ops-terminal/d' "$cfg"
  printf '%s' "$n"
}

# ha_insert_after_line CFG LINENO BLOCKFILE -> inserts block after LINENO (in place)
ha_insert_after_line() {
  local cfg="$1" lineno="$2" block="$3" tmp
  tmp="$(mktemp "${cfg}.XXXXXX")"
  head -n "$lineno" "$cfg" > "$tmp"
  cat "$block" >> "$tmp"
  tail -n +"$((lineno + 1))" "$cfg" >> "$tmp"
  # preserve permissions/ownership of the original file
  cat "$tmp" > "$cfg"
  rm -f "$tmp"
}
