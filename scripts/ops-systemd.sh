#!/usr/bin/env bash
# ==========================================================================
# HANASO OPS Web Terminal — systemd unit lifecycle helpers (CP11)
#
# Used by scripts/install.sh (rollback path) and scripts/uninstall.sh to stop
# ONLY the three systemd units that belong to this panel, to break any
# restart loop they may be stuck in, and to remove the unit files. Shared
# services (nginx, haproxy, KOTODAMA/HANASO panels) are NEVER touched here.
#
# Battery reuse: the CP11 battery sources this exact file and drives it
# against a real systemd user manager by overriding SYSTEMD_STOP_CMD /
# SYSTEMD_UNIT_DIR — the production default values below are used unchanged
# on the VPS.
# ==========================================================================

# systemd_stop_panel_units
#   SYSTEMD_STOP_CMD  command used to talk to the manager (default: systemctl)
#   SYSTEMD_UNIT_DIR  dir the unit files live in   (default: /etc/systemd/system)
#   OPS_UNIT_NAMES    unit names (default: the three panel units)
systemd_stop_panel_units() {
    local cmd="${SYSTEMD_STOP_CMD:-systemctl}"
    local dir="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
    local units="${OPS_UNIT_NAMES:-ops-terminal.service ops-terminal-gateway.service ops-terminal-nginx.service}"
    local u

    # 1) disable + stop (a unit that is crash-looping or start-limited stops too)
    # shellcheck disable=SC2086
    $cmd disable --now $units 2>/dev/null || true

    # 2) break any restart loop hard: if a unit is still active (mid
    #    RestartSec back-off), TERM it, then KILL it — bounded, ours only.
    for u in $units; do
        if $cmd is-active --quiet "$u" 2>/dev/null; then
            $cmd kill --signal=SIGTERM "$u" 2>/dev/null || true
            sleep 1
            if $cmd is-active --quiet "$u" 2>/dev/null; then
                $cmd kill --signal=SIGKILL "$u" 2>/dev/null || true
                sleep 0.5
            fi
        fi
        # 3) clear the failed state left by an exhausted StartLimit so nothing
        #    restarts the units after the unit files are gone
        $cmd reset-failed "$u" 2>/dev/null || true
    done

    # 4) remove ONLY this panel's unit files and refresh the manager state
    for u in $units; do rm -f "$dir/$u"; done
    $cmd daemon-reload 2>/dev/null || true
}

# systemd_panel_units_stopped -> rc 0 when every panel unit is inactive/failed
#   (used by the rollback for a post-condition assertion and by the battery)
systemd_panel_units_stopped() {
    local cmd="${SYSTEMD_STOP_CMD:-systemctl}"
    local units="${OPS_UNIT_NAMES:-ops-terminal.service ops-terminal-gateway.service ops-terminal-nginx.service}"
    local u
    for u in $units; do
        # active (or activating) means NOT stopped -> failure
        if $cmd is-active --quiet "$u" 2>/dev/null; then
            return 1
        fi
    done
    return 0
}
