#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
HANASO OPS Web Terminal — CP11 unit-policy supervisor (TEST-ONLY).

WHY THIS EXISTS
---------------
The CP11 battery must exercise the systemd unit semantics (Restart=,
RestartSec=, StartLimitIntervalSec=, StartLimitBurst=, ExecStartPre/Start/
Reload, Type=simple MainPID tracking) on a container that has systemd 257
binaries but NO systemd manager: PID 1 is tini, /sys/fs/cgroup is a
read-only cgroup v1 mount (real captured failure: "Failed to create
/k8s.io/.../init.scope control group: Read-only file system") and neither
mount namespaces nor root are available. A real systemd manager therefore
cannot run here — not a property of the panel, but of the platform.

This supervisor is NOT systemd. It is a small, auditable process supervisor
that reads the REAL unit file and applies the REAL policy lines from it:

  * [Unit] StartLimitIntervalSec / StartLimitBurst  (start-attempt window;
    burst exceeded -> unit enters "failed" and stays down, like systemd)
  * [Service] Restart= (always | on-failure | no), RestartSec=
  * Type=simple: MainPID = the ExecStart process; active while it lives
  * ExecStartPre runs first; its failure fails the start attempt
  * ExecReload runs the reload command without touching MainPID
  * KillMode=process behaviour on stop (TERM/kill the MainPID only)
  * NRestarts counter preserved across automatic restarts, reset by an
    explicit reset-failed (like systemctl reset-failed)

Everything it runs comes VERBATIM from the unit's Exec* lines (shlex-split,
no shell). Identity note: the production units declare User=ops-gw; a
user-space supervisor cannot setuid, so the battery runs it as the
unprivileged sandbox identity and ASSERTS the unit's User=/Group= fields
for evidence instead (see the battery).
"""
import json
import os
import shlex
import signal
import subprocess
import sys
import time

PANEL_UNITS = (
    "ops-terminal.service",
    "ops-terminal-gateway.service",
    "ops-terminal-nginx.service",
)


def log(msg):
    sys.stderr.write("[cp11-supervisor] %s\n" % msg)
    sys.stderr.flush()


def parse_unit(path):
    """Minimal systemd unit parser: sections + per-key lists, comments kept."""
    unit = {"path": path, "name": os.path.basename(path), "_raw": open(path).read()}
    section = None
    for line in unit["_raw"].splitlines():
        s = line.strip()
        if not s or s.startswith(("#", ";")):
            continue
        if s.startswith("[") and s.endswith("]"):
            section = s[1:-1]
            unit.setdefault(section, {})
            continue
        if section is None or "=" not in s:
            continue
        key, _, val = s.partition("=")
        unit[section].setdefault(key.strip(), []).append(val.strip())
    return unit


def unit_first(unit, section, key, default=""):
    vals = unit.get(section, {}).get(key, [])
    return vals[0] if vals else default


class UnitRuntime:
    def __init__(self, unit_path, state_dir, log_path, unit_override=None):
        self.unit = parse_unit(unit_path)
        if unit_override:  # sandbox path translation (exec lines only)
            for a, b in unit_override.items():
                for sec in ("Service",):
                    for k in list(self.unit.get(sec, {}).keys()):
                        self.unit[sec][k] = [v.replace(a, b) for v in self.unit[sec][k]]
        self.name = self.unit["name"]
        self.state_dir = state_dir
        self.state_file = os.path.join(state_dir, self.name + ".state.json")
        self.log_path = log_path
        self.restart = unit_first(self.unit, "Service", "Restart", "no").lower()
        self.restart_sec = float(unit_first(self.unit, "Service", "RestartSec", "0.1") or 0.1)
        self.interval = float(unit_first(self.unit, "Unit", "StartLimitIntervalSec", "0") or 0)
        self.burst = int(unit_first(self.unit, "Unit", "StartLimitBurst", "0") or 0)
        self.exec_pre = unit_first(self.unit, "Service", "ExecStartPre", "")
        self.exec_start = unit_first(self.unit, "Service", "ExecStart", "")
        self.exec_reload = unit_first(self.unit, "Service", "ExecReload", "")
        self.unit_user = unit_first(self.unit, "Service", "User", "")
        self.unit_group = unit_first(self.unit, "Service", "Group", "")
        if not self.exec_start:
            raise SystemExit("unit %s has no ExecStart" % self.name)

    # ---------------- state ----------------
    def _read(self):
        try:
            with open(self.state_file) as fh:
                return json.load(fh)
        except (OSError, ValueError):
            return {}

    def _write(self, st):
        os.makedirs(self.state_dir, exist_ok=True)
        tmp = self.state_file + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(st, fh)
        os.replace(tmp, self.state_file)

    # ---------------- daemon (foreground when --foreground) ----------------
    def run_forever(self):
        st = self._read()
        st.update({
            "unit": self.name, "supervisor_pid": os.getpid(),
            "NRestarts": st.get("NRestarts", 0),
            "attempts": st.get("attempts", []),
            "ActiveState": "inactive", "SubState": "dead",
            "MainPID": 0, "Result": "success", "log": self.log_path,
            "unit_user": self.unit_user, "unit_group": self.unit_group,
        })
        st.pop("__stopping", None)
        self._write(st)
        signal.signal(signal.SIGTERM, self._on_term)

        while True:
            st = self._read()
            if st.get("__stopping") or not os.path.exists(self.state_file):
                return  # intentional stop request -> deactivate and exit
            now = time.time()
            # start-limit: count start attempts inside the interval window
            if self.burst > 0 and self.interval > 0:
                st["attempts"] = [t for t in st["attempts"] if now - t < self.interval]
                if len(st["attempts"]) >= self.burst:
                    st["ActiveState"] = "failed"
                    st["SubState"] = "failed"
                    st["Result"] = "start-limit-hit"
                    self._write(st)
                    log("%s: StartLimitBurst=%s hit within %.0fs -> unit FAILED, staying down"
                        % (self.name, self.burst, self.interval))
                    # systemd keeps the unit failed until reset-failed/restart-job;
                    # we wait for a stop command (supervisor SIGTERM) and exit.
                    while True:
                        time.sleep(0.3)
                        st = self._read()
                        if st.get("__stopping") or not os.path.exists(self.state_file):
                            return
                    return
            st["attempts"].append(now)

            st["ActiveState"] = "activating"
            st["SubState"] = "start-pre"
            self._write(st)

            pre_rc = 0
            if self.exec_pre:
                pre_rc = self._spawn_stage(shlex.split(self.exec_pre), st, stage="pre")
            main_pid = 0
            if pre_rc == 0:
                self._main_proc = self._spawn_main(shlex.split(self.exec_start), st)
                main_pid = self._main_proc.pid if self._main_proc else 0
            if main_pid <= 0 or pre_rc != 0:
                st["ActiveState"] = "failed"
                st["SubState"] = "failed"
                st["Result"] = "exit-code" if pre_rc != 0 else "spawn-error"
                st["MainPID"] = 0
                self._write(st)
                if self.restart in ("on-failure", "always"):
                    st["NRestarts"] = st.get("NRestarts", 0) + 1
                    self._write(st)
                    log("%s: start failed (pre_rc=%s) -> restart #%s in %.1fs"
                        % (self.name, pre_rc, st["NRestarts"], self.restart_sec))
                    time.sleep(self.restart_sec)
                continue

            # main process alive -> Type=simple: active immediately
            st["ActiveState"] = "active"
            st["SubState"] = "running"
            st["MainPID"] = main_pid
            st["Result"] = "success"
            self._write(st)

            # reap loop while the main process lives (poll() reaps the child:
            # kill -0 would succeed forever on an unreaped zombie)
            exit_rc = None
            while True:
                time.sleep(0.25)
                st = self._read()
                if st.get("__stopping") or not os.path.exists(self.state_file):
                    break
                exit_rc = self._main_proc.poll() if self._main_proc else 0
                if exit_rc is not None:
                    break
            if st.get("__stopping") or not os.path.exists(self.state_file):
                # intentional stop: terminate main like KillMode=process
                self._sig(main_pid, signal.SIGTERM)
                for _ in range(20):
                    time.sleep(0.2)
                    if self._main_proc and self._main_proc.poll() is not None:
                        break
                    try:
                        os.kill(main_pid, 0)
                    except OSError:
                        break
                else:
                    self._sig(main_pid, signal.SIGKILL)
                st = self._read()
                st["ActiveState"] = "inactive"
                st["SubState"] = "dead"
                st["MainPID"] = 0
                st["Result"] = "success"
                st.pop("__stopping", None)
                self._write(st)
                log("%s: stopped (intentional)" % self.name)
                return

            # main died on its own -> failure path
            st["MainPID"] = 0
            st["ActiveState"] = "failed"
            st["SubState"] = "failed"
            st["Result"] = "signal" if (exit_rc or 0) < 0 else "exit-code"
            self._write(st)
            if self.restart == "no":
                return
            st["NRestarts"] = st.get("NRestarts", 0) + 1
            self._write(st)
            log("%s: main process died (rc=%s) -> restart #%s in %.1fs"
                % (self.name, exit_rc, st["NRestarts"], self.restart_sec))
            time.sleep(self.restart_sec)

    def _on_term(self, _sig, _frm):
        # graceful: mark the stop request in the state file; the loop picks it up
        st = self._read()
        st["__stopping"] = 1
        st["ActiveState"] = "deactivating"
        self._write(st)

    def _spawn_main(self, argv, st):
        """Spawn the (foreground) main process; keep the Popen for poll()."""
        env = dict(os.environ)
        for kv in self.unit.get("Service", {}).get("Environment", []):
            k, _, v = kv.partition("=")
            env[k.strip()] = v.strip()
        logfile = open(self.log_path, "a")
        try:
            return subprocess.Popen(argv, env=env, stdout=logfile, stderr=logfile,
                                    stdin=subprocess.DEVNULL)
        except OSError as exc:
            log("spawn failed for %s: %s" % (argv[0], exc))
            return None

    def _spawn_stage(self, argv, st, stage="main"):
        env = dict(os.environ)
        for kv in self.unit.get("Service", {}).get("Environment", []):
            k, _, v = kv.partition("=")
            env[k.strip()] = v.strip()
        logfile = open(self.log_path, "a")
        try:
            p = subprocess.Popen(argv, env=env, stdout=logfile, stderr=logfile,
                                 stdin=subprocess.DEVNULL)
            if stage == "main":
                return p.pid
            rc = p.wait()
            return 0 if rc == 0 else rc
        except OSError as exc:
            log("spawn failed for %s: %s" % (argv[0], exc))
            return -1

    @staticmethod
    def _sig(pid, sig):
        try:
            os.kill(pid, sig)
        except OSError:
            pass

    # ---------------- control commands ----------------
    def reload(self):
        """ExecReload semantics: run the reload command, keep MainPID."""
        st = self._read()
        if st.get("ActiveState") != "active" or not self.exec_reload:
            return 1
        rc = self._spawn_stage(shlex.split(self.exec_reload), st, stage="pre")
        st["LastReloadRC"] = rc
        self._write(st)
        return rc

    def reset_failed(self):
        st = self._read()
        st["NRestarts"] = 0
        st["attempts"] = []
        st["Result"] = "success"
        if st.get("ActiveState") == "failed":
            st["ActiveState"] = "inactive"
            st["SubState"] = "dead"
        self._write(st)

    def stop_and_wait(self):
        st = self._read()
        sup = st.get("supervisor_pid")
        if not sup:
            return
        try:
            os.kill(sup, signal.SIGTERM)
        except OSError:
            return
        for _ in range(60):
            time.sleep(0.2)
            st = self._read()
            if st.get("ActiveState") in ("inactive",) or not os.path.exists(
                    "/proc/%s" % sup):
                break
        st = self._read()
        st["supervisor_pid"] = 0
        self._write(st)


def main():
    import argparse
    ap = argparse.ArgumentParser(description="CP11 unit-policy supervisor (test-only)")
    ap.add_argument("action", choices=[
        "start", "status", "stop", "restart", "reload", "reset-failed"])
    ap.add_argument("unit")
    ap.add_argument("--state-dir", required=True)
    ap.add_argument("--log", default="")
    ap.add_argument("--translate", action="append", default=[],
                    help="path substitution OLD=NEW applied to Exec* lines")
    ap.add_argument("--foreground", action="store_true",
                    help="run the supervisor loop in the foreground (for nohup)")
    args = ap.parse_args()

    override = {}
    for t in args.translate:
        a, _, b = t.partition("=")
        override[a] = b

    rt = UnitRuntime(args.unit, args.state_dir, args.log or
                     os.path.join(args.state_dir, args.unit + ".log"), override)
    name = rt.name

    if args.action == "start":
        st = rt._read()
        if st.get("supervisor_pid") and os.path.exists("/proc/%s" % st["supervisor_pid"]):
            print("%s already running (supervisor pid %s)" % (name, st["supervisor_pid"]))
            return 0
        if args.foreground:
            rt.run_forever()
            return 0
        # daemonize: double-fork so the battery can fire-and-forget like systemctl
        pid = os.fork()
        if pid == 0:
            os.setsid()
            pid2 = os.fork()
            if pid2 == 0:
                devnull = os.open(os.devnull, os.O_RDONLY)
                os.dup2(devnull, 0)
                logfd = os.open(rt.log_path + ".supervisor.log",
                                os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
                os.dup2(logfd, 1)
                os.dup2(logfd, 2)
                rt.run_forever()
                os._exit(0)
            os._exit(0)
        os.waitpid(pid, 0)
        return 0

    if args.action == "status":
        st = rt._read()
        print(json.dumps(st, indent=2))
        return 0

    if args.action == "stop":
        rt.stop_and_wait()
        return 0

    if args.action == "restart":
        rt.stop_and_wait()
        rt.reset_failed()  # a manual restart job resets the limit window
        return main_start_background(rt)

    if args.action == "reload":
        return rt.reload()

    if args.action == "reset-failed":
        rt.reset_failed()
        return 0
    return 2


def main_start_background(rt):
    pid = os.fork()
    if pid == 0:
        os.setsid()
        pid2 = os.fork()
        if pid2 == 0:
            devnull = os.open(os.devnull, os.O_RDONLY)
            os.dup2(devnull, 0)
            logfd = os.open(rt.log_path + ".supervisor.log",
                            os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
            os.dup2(logfd, 1)
            os.dup2(logfd, 2)
            rt.run_forever()
            os._exit(0)
        os._exit(0)
    os.waitpid(pid, 0)
    return 0


if __name__ == "__main__":
    sys.exit(main())
