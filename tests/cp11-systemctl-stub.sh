#!/usr/bin/env bash
# ==========================================================================
# TEST-ONLY systemctl transport stub (CP11 battery).
#
# scripts/ops-systemd.sh talks to the systemd manager through systemctl.
# This sandbox has NO systemd manager (PID 1 is tini; cgroup v1 read-only —
# see tests/cp11-supervisor.py header for the captured proof), so the battery
# drives the REAL ops-systemd.sh functions by pointing SYSTEMD_STOP_CMD at
# this stub. The stub implements exactly the verbs ops-systemd.sh uses,
# backed by the SAME process engine the rest of the battery uses
# (tests/cp11-supervisor.py running the real unit files):
#
#   systemctl disable --now <units>   -> stop each unit via the supervisor
#   systemctl is-active --quiet <u>   -> rc0 iff unit state is active/activating
#   systemctl kill --signal=X <u>     -> signal the unit MainPID
#   systemctl reset-failed <units>    -> clear failed state + NRestarts
#   systemctl daemon-reload           -> no-op (state lives in files)
#
# On the VPS the REAL systemctl handles these verbs against real units.
# ==========================================================================
set -u
SV="/home/z/.venv/bin/python3 /home/z/my-project/work/hanaso-ops-terminal/tests/cp11-supervisor.py"
STATE_DIR="${CP11_STUB_STATE_DIR:?CP11_STUB_STATE_DIR not set}"
STATE_DIR="$(cd "$STATE_DIR" 2>/dev/null && pwd || echo "$STATE_DIR")"

usage() { echo "stub-systemctl: unsupported invocation: $*" >&2; exit 1; }

# collect unit names: everything that ends in .service among the args
units=()
mode=""
sig=""
for a in "$@"; do
    case "$a" in
        disable|--now|is-active|--quiet|kill|reset-failed|daemon-reload|--signal=*) ;;
        --signal=*) sig="${a#--signal=}" ;;
        *.service) units+=("$a") ;;
        *) usage ;;
    esac
done

cmd="$1"; shift || true

sup_state() { # unit name -> state file
    printf '%s/%s.state.json' "$STATE_DIR" "$(basename "$1")"
}

unit_active() { # unit -> rc0 when active/activating
    local f; f="$(sup_state "$1")"
    [ -f "$f" ] || return 1
    /home/z/.venv/bin/python3 - "$f" <<'PY'
import json, sys, os
st = json.load(open(sys.argv[1]))
sup = st.get("supervisor_pid") or 0
alive = sup and os.path.exists("/proc/%d" % int(sup))
sys.exit(0 if alive and st.get("ActiveState") in ("active", "activating") else 1)
PY
}

case "$cmd" in
    disable)
        # `disable --now UNITS` -> stop every named unit through the supervisor
        for u in "${units[@]:-}"; do
            [ -n "$u" ] || continue
            if unit_active "$u"; then
                "$SV" stop "$u" --state-dir "$STATE_DIR" >/dev/null 2>&1 || true
            fi
        done
        exit 0
        ;;
    is-active)
        for u in "${units[@]:-}"; do
            [ -n "$u" ] || continue
            unit_active "$u" || exit 3   # systemctl exits 3 for inactive
        done
        exit 0
        ;;
    kill)
        for u in "${units[@]:-}"; do
            [ -n "$u" ] || continue
            f="$(sup_state "$u")"
            [ -f "$f" ] || continue
            pid="$(/home/z/.venv/bin/python3 -c "import json,sys;print(json.load(open('$f')).get('MainPID') or 0)")"
            [ "$pid" != "0" ] || continue
            case "$sig" in
                SIGTERM|TERM) kill -TERM "$pid" 2>/dev/null || true ;;
                SIGKILL|KILL) kill -KILL "$pid" 2>/dev/null || true ;;
                *) kill -TERM "$pid" 2>/dev/null || true ;;
            esac
        done
        exit 0
        ;;
    reset-failed)
        for u in "${units[@]:-}"; do
            [ -n "$u" ] || continue
            "$SV" reset-failed "$u" --state-dir "$STATE_DIR" >/dev/null 2>&1 || true
        done
        exit 0
        ;;
    daemon-reload)
        exit 0
        ;;
    *)
        usage
        ;;
esac
