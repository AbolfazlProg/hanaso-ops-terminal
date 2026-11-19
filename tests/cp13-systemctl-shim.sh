#!/usr/bin/env bash
# ==========================================================================
# TEST-ONLY systemctl shim for the CP13 clean-VM battery.
#
# This sandbox CANNOT run a live systemd manager (PID1=tini, cgroup v1
# read-only — captured proof in tests/cp11-supervisor.py header and CP12
# decision D23). The VM therefore talks to systemd units through THIS shim:
#
#   * unit FILES are the real, final files (written by the real installer)
#   * they are parsed and executed VERBATIM (ExecStart/ExecStartPre/
#     ExecReload, Restart=, RestartSec=, StartLimit*, Environment=) by the
#     unit-policy supervisor (tests/cp11-supervisor.py, reused from CP11)
#   * enable/disable create/remove the REAL wants symlinks
#     (multi-user.target.wants / timers.target.wants) — boot persistence is
#     provable from the filesystem
#   * Type=oneshot units run their ExecStart synchronously (like systemd)
#   * the unit files themselves are additionally verified with the REAL
#     Ubuntu `systemd-analyze verify` (same major version 255 as the VPS)
#
# On a REAL VPS the real systemd does all of this natively; this shim exists
# only because the test platform cannot host a manager. Every invocation is
# logged to /run/cp13-ctl/shim.log (auditable).
# ==========================================================================
set -u

STATE=/run/cp13-ctl
UNIT_DIRS="/etc/systemd/system /lib/systemd/system /usr/lib/systemd/system"
SUP="python3 /usr/libexec/cp13-supervisor.py"
LOG="$STATE/shim.log"

mkdir -p "$STATE"

log() { printf '[shim] %s\n' "$*" >> "$LOG"; }
log "ARGS: $*"

find_unit() { # name -> path or ""
  local n="$1" d
  case "$n" in *.service|*.timer|*.target) ;; *) n="$n.service" ;; esac
  for d in $UNIT_DIRS; do
    if [ -f "$d/$n" ]; then printf '%s' "$d/$n"; return 0; fi
  done
  return 1
}

state_file() { printf '%s/%s.state.json' "$STATE" "$(basename "$1")"; }

unit_type() { # path -> simple|oneshot|...
  sed -n '/^\[Service\]/,/^\[/s/^Type=//p' "$1" | head -n1 | tr -d ' '
}

wants_link() { # name -> path
  case "$1" in
    *.timer) printf '/etc/systemd/system/timers.target.wants/%s' "$1" ;;
    *)       printf '/etc/systemd/system/multi-user.target.wants/%s' "$1" ;;
  esac
}

is_active() { # name -> rc
  local f; f="$(state_file "$1")"
  [ -f "$f" ] || return 3
  python3 - "$f" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
sup = st.get("supervisor_pid") or 0
alive = False
try:
    import os
    os.kill(int(sup), 0)   # pid-namespace-safe liveness (VM binds the OUTER /proc)
    alive = True
except (OSError, ValueError, TypeError):
    alive = False
sys.exit(0 if alive and st.get("ActiveState") in ("active", "activating") else 3)
PY
}

sup_do() { # supervisor action + unit NAME (resolved to the unit file path)
  local action="$1" u="$2" p
  p="$(find_unit "$u")" || return 1
  # explicit --log: without it the supervisor joins state_dir with the unit's
  # ABSOLUTE path (os.path.join quirk) and logs would land in /etc/systemd/system
  $SUP "$action" "$p" --state-dir "$STATE" --log "$STATE/$(basename "$u").log" >/dev/null 2>&1
}

oneshot_run() { # unit path -> run ExecStart synchronously
  local u="$1" path="$2" rc=0 envs argv
  envs=()
  while IFS= read -r line; do envs+=("$line"); done < \
    <(sed -n '/^\[Service\]/,/^\[/s/^Environment=//p' "$path" | tr -d '"')
  argv="$(sed -n '/^\[Service\]/,/^\[/s/^ExecStart=//p' "$path" | head -n1)"
  [ -n "$argv" ] || { log "oneshot $u: no ExecStart"; return 1; }
  log "oneshot $u: running: $argv"
  if [ "${#envs[@]}" -gt 0 ]; then
    env "${envs[@]}" bash -c "$argv" >> "$STATE/$(basename "$u").oneshot.log" 2>&1 || rc=$?
  else
    bash -c "$argv" >> "$STATE/$(basename "$u").oneshot.log" 2>&1 || rc=$?
  fi
  python3 - "$u" "$rc" <<'PY'
import json, sys, os
name, rc = sys.argv[1], int(sys.argv[2])
st = {"unit": name, "ActiveState": "inactive" if rc == 0 else "failed",
      "SubState": "dead" if rc == 0 else "failed",
      "Result": "success" if rc == 0 else "exit-code",
      "ExecMainStatus": rc, "supervisor_pid": 0, "MainPID": 0}
json.dump(st, open("/run/cp13-ctl/%s.state.json" % name, "w"))
sys.exit(0 if rc == 0 else 1)
PY
  return $rc
}

# ---------------------------------------------------------- parse invocation --
CMD="${1:-}"; shift || true
QUIET=0; NOW=0; SIG=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=1 ;;
    --now) NOW=1 ;;
    --signal=*) SIG="${1#--signal=}" ;;
    --*) ;;                       # ignore other flags leniently (logged)
    *) ARGS+=("$1") ;;
  esac
  shift
done

do_enable() {
  local u rc=0
  for u in "${ARGS[@]:-}"; do
    [ -n "$u" ] || continue
    p="$(find_unit "$u")" || { echo "Unit $u not found" >&2; rc=1; continue; }
    u="$(basename "$p")"
    mkdir -p "$(dirname "$(wants_link "$u")")"
    ln -sfn "$p" "$(wants_link "$u")"
    log "enable $u -> $(wants_link "$u")"
    [ "$NOW" = "1" ] && do_start_unit "$u"
  done
  return $rc
}

do_disable() {
  local u rc=0
  for u in "${ARGS[@]:-}"; do
    [ -n "$u" ] || continue
    p="$(find_unit "$u")" || { rc=0; continue; }   # disable on missing unit: ok
    u="$(basename "$p")"
    rm -f "$(wants_link "$u")"
    log "disable $u (wants link removed)"
    [ "$NOW" = "1" ] && do_stop_unit "$u"
  done
  return $rc
}

do_start_unit() { # NAME (with suffix)
  local u="$1" p
  p="$(find_unit "$u")" || { echo "Unit $u not found" >&2; return 1; }
  u="$(basename "$p")"
  case "$(unit_type "$p")" in
    oneshot) oneshot_run "$u" "$p"; return $? ;;
  esac
  case "$u" in
    *.timer) log "start $u: timer (no live manager) — wants symlink is the persistence proof"; return 0 ;;
  esac
  if is_active "$u" 2>/dev/null; then log "start $u: already active"; return 0; fi
  sup_do start "$u" || { log "start $u: supervisor failed"; return 1; }
  sleep 0.3
  is_active "$u" && return 0
  log "start $u: did not reach active state"
  return 1
}

do_stop_unit() {
  local u="$1" p
  p="$(find_unit "$u")" || return 0
  u="$(basename "$p")"
  case "$(unit_type "$p")" in oneshot)
    python3 -c "
import json; st=json.load(open('$STATE/$u.state.json'))
st['ActiveState']='inactive'; st['SubState']='dead'; st['Result']='success'
json.dump(st, open('$STATE/$u.state.json','w'))" 2>/dev/null || true
    return 0 ;;
  esac
  case "$u" in *.timer) return 0 ;; esac
  sup_do stop "$u"
  return 0
}

case "$CMD" in
  daemon-reload)
    log "daemon-reload (no live manager — unit files on disk are the state)"
    exit 0 ;;

  enable)
    # parse: [enable] [--now] units...
    do_enable
    exit $? ;;

  disable)
    do_disable
    exit $? ;;

  start)
    rc=0
    for u in "${ARGS[@]:-}"; do [ -n "$u" ] || continue; do_start_unit "$u" || rc=1; done
    exit $rc ;;

  stop)
    rc=0
    for u in "${ARGS[@]:-}"; do [ -n "$u" ] || continue; do_stop_unit "$u" || rc=1; done
    exit $rc ;;

  restart)
    rc=0
    for u in "${ARGS[@]:-}"; do
      [ -n "$u" ] || continue
      do_stop_unit "$u"
      sup_do reset-failed "$u" || true
      do_start_unit "$u" || rc=1
    done
    exit $rc ;;

  reload)
    rc=0
    for u in "${ARGS[@]:-}"; do
      [ -n "$u" ] || continue
      p="$(find_unit "$u")" || { echo "Unit $u not found" >&2; rc=1; continue; }
      u="$(basename "$p")"
      sup_do reload "$u" || { log "reload $u FAILED"; rc=1; }
    done
    exit $rc ;;

  is-active)
    rc=0
    for u in "${ARGS[@]:-}"; do
      [ -n "$u" ] || continue
      p="$(find_unit "$u")" || { [ "$QUIET" = "1" ] || echo "Unit $u not found"; rc=3; continue; }
      u="$(basename "$p")"
      is_active "$u" || rc=3
    done
    if [ "$QUIET" != "1" ]; then
      for u in "${ARGS[@]:-}"; do
        p="$(find_unit "$u")" 2>/dev/null && {
          st="$(python3 -c "import json;print(json.load(open('$STATE/$(basename "$p").state.json')).get('ActiveState','inactive'))" 2>/dev/null || echo inactive)"
          echo "$(basename "$p") $st"
        }
      done
    fi
    exit $rc ;;

  is-enabled)
    rc=0
    out=""
    for u in "${ARGS[@]:-}"; do
      [ -n "$u" ] || continue
      p="$(find_unit "$u")" || { [ "$QUIET" != "1" ] && echo "Unit $u not found" >&2; rc=4; continue; }
      u="$(basename "$p")"
      if [ -e "$(wants_link "$u")" ]; then st=enabled; [ "$rc" = "4" ] && rc=0
      else st=disabled; [ "$rc" = "0" ] && rc=1; fi
      out="$out$u $st"$'\n'
    done
    [ "$QUIET" != "1" ] && printf '%s' "$out"
    exit $rc ;;

  kill)
    rc=0
    for u in "${ARGS[@]:-}"; do
      [ -n "$u" ] || continue
      f="$(state_file "$u")"
      [ -f "$f" ] || continue
      pid="$(python3 -c "import json,sys;print(json.load(open('$f')).get('MainPID') or 0)")"
      [ "$pid" != "0" ] || continue
      case "$SIG" in
        SIGTERM|TERM) kill -TERM "$pid" 2>/dev/null || true ;;
        SIGKILL|KILL) kill -KILL "$pid" 2>/dev/null || true ;;
        *) kill -TERM "$pid" 2>/dev/null || true ;;
      esac
    done
    exit $rc ;;

  reset-failed)
    for u in "${ARGS[@]:-}"; do
      [ -n "$u" ] || continue
      p="$(find_unit "$u")" || continue
      sup_do reset-failed "$(basename "$p")" || true
    done
    exit 0 ;;

  list-unit-files)
    # print ONLY existing unit files (grep -q nginx.service pattern works)
    for pat in "${ARGS[@]:-}"; do
      for d in $UNIT_DIRS; do
        for f in "$d"/$pat; do
          [ -f "$f" ] || continue
          u="$(basename "$f")"
          [ -e "$(wants_link "$u")" ] && st=enabled || st=disabled
          echo "$u $st $d/$u"
        done
      done
    done 2>/dev/null
    exit 0 ;;

  cat)
    p="$(find_unit "${ARGS[0]:-}")" || exit 1
    cat "$p"
    exit 0 ;;

  status)
    p="$(find_unit "${ARGS[0]:-}")" || { echo "Unit ${ARGS[0]} not found" >&2; exit 4; }
    u="$(basename "$p")"
    if is_active "$u"; then
      echo "● $u - active (supervised by the CP13 unit-policy shim)"
      exit 0
    fi
    echo "○ $u - inactive/failed"
    exit 3 ;;

  show)
    # minimal: `show UNIT -p PROP [--value]` -> value from the state json;
    # comma-separated multi-props print key=value lines
    u=""; prop=""
    for a in "${ARGS[@]:-}"; do
      case "$a" in
        -p) : ;;
        --value) : ;;
        *.service|*.timer) u="$a" ;;
        *) prop="$a" ;;
      esac
    done
    p="$(find_unit "$u")" || { echo "Unit $u not found" >&2; exit 1; }
    f="$(state_file "$u")"
    python3 -c "
import json
st = json.load(open('$f'))
for pr in '$prop'.split(','):
    if pr:
        print('%s=%s' % (pr, st.get(pr, '')))" 2>/dev/null
    exit 0 ;;

  *)
    # lenient for dpkg maintainer scripts (logged): unknown verb -> 0
    log "UNKNOWN verb '$CMD' — lenient exit 0 (maintainer-script compatibility)"
    exit 0 ;;
esac
