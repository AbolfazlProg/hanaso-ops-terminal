#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Service-restart persistence test (sandbox semantics = production
KillMode=process semantics): a long command keeps running while ttyd is
killed and restarted (tmux server survives outside the service process);
after restart the same session is re-attached and the late output arrives.
Also verifies the login cookie survives a gateway restart."""
import importlib.util
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("e2e_test",
                                              os.path.join(HERE, "..", "scripts", "e2e-test.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

BASE = os.environ.get("OPS_TEST_BASE", "https://ops.hanaso.ir:8443")
IP = os.environ.get("OPS_TEST_IP", "127.0.0.1")
PW = os.environ["OPS_TEST_PW"]
USER = os.environ.get("OPS_TEST_USER", "ops-admin")
CTL = os.path.join(HERE, "sandbox-ctl.sh")


def get_conn_cls():
    import http.client

    class Conn(http.client.HTTPSConnection):
        def __init__(self, host, port, ip, timeout=10):
            import ssl
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            super().__init__(host, port, context=ctx, timeout=timeout)
            self._ip = ip

        def connect(self):
            import socket
            raw = socket.create_connection((self._ip, self.port), timeout=self.timeout)
            self.sock = self._context.wrap_socket(raw, server_hostname=self.host)
    return Conn


def login_and_ws():
    m = re.match(r"https://([^/:]+)(?::(\d+))?", BASE)
    host, port = m.group(1), int(m.group(2) or 443)
    Conn = get_conn_cls()
    jar = mod.CookieJar()
    c = Conn(host, port, IP)
    c.request("GET", "/login")
    r = c.getresponse(); body = r.read().decode()
    jar.absorb(r); c.close()
    csrf = re.search(r'name="csrf" value="([^"]+)"', body).group(1)
    form = ("csrf=%s&username=%s&password=%s" % (csrf, USER, PW)).encode()
    c = Conn(host, port, IP)
    c.request("POST", "/login", body=form, headers={
        "Content-Type": "application/x-www-form-urlencoded",
        "Cookie": "; ".join("%s=%s" % kv for kv in jar.items())})
    r = c.getresponse(); r.read(); jar.absorb(r); c.close()
    assert r.status == 302, "login failed: %d" % r.status
    origin = "https://%s%s" % (host, (":%d" % port) if port not in (80, 443) else "")
    ws = mod.WSClient(host, port, IP, "/ws", True, jar, origin, timeout=15)
    ws.handshake(101)
    ws.send_init("")
    ws.wait_for(lambda out: "$" in out or "#" in out or "~" in out, 10)
    return Conn, jar


def main():
    fails = 0

    print("== 1. cookie survives gateway restart (stateless HMAC sessions) ==")
    Conn, jar = login_and_ws()
    subprocess.run(["bash", CTL, "restart", "gateway"], check=True)
    time.sleep(1.5)
    m = re.match(r"https://([^/:]+)(?::(\d+))?", BASE)
    host, port = m.group(1), int(m.group(2) or 443)
    c = Conn(host, port, IP)
    c.request("GET", "/", headers={"Cookie": "; ".join("%s=%s" % kv for kv in jar.items())})
    r = c.getresponse(); r.read(); c.close()
    if r.status == 200:
        print("  [PASS] session cookie still valid after gateway restart (GET / -> 200)")
    else:
        print("  [FAIL] GET / after gateway restart: %d" % r.status); fails += 1

    print("== 2. long command survives ttyd kill+restart (tmux server) ==")
    Conn, jar = login_and_ws()
    marker = "RESTART%s" % os.urandom(3).hex()
    ws = None
    # open a websocket, start the long command, then close ws
    m = re.match(r"https://([^/:]+)(?::(\d+))?", BASE)
    host, port = m.group(1), int(m.group(2) or 443)
    origin = "https://%s%s" % (host, (":%d" % port) if port not in (80, 443) else "")
    ws = mod.WSClient(host, port, IP, "/ws", True, jar, origin, timeout=15)
    ws.handshake(101)
    ws.send_init("")
    ws.wait_for(lambda out: "$" in out or "#" in out or "~" in out, 10)
    ws.send_input("sleep 12; echo %s\n" % marker)
    time.sleep(1.0)
    ws.close()
    # kill + restart ttyd WHILE the command is running
    subprocess.run(["bash", CTL, "restart", "ttyd"], check=True)
    time.sleep(1.0)
    # reconnect through the fresh ttyd to the SAME tmux session
    ws2 = mod.WSClient(host, port, IP, "/ws", True, jar, origin, timeout=15)
    ws2.handshake(101)
    ws2.send_init("")
    ws2.wait_for(lambda out: "$" in out or "#" in out or "~" in out, 10)
    if ws2.wait_for(lambda out: marker in out, 20):
        print("  [PASS] command output arrived after ttyd restart (tmux re-attach, %s)" % marker)
    else:
        print("  [FAIL] marker never arrived after ttyd restart: %r" % ws2.output[-150:])
        fails += 1
    ws2.close()

    print("== 3. panel reachable after nginx stop/start ==")
    subprocess.run(["bash", CTL, "restart", "nginx"], check=True)
    time.sleep(1.0)
    c = Conn(host, port, IP)
    c.request("GET", "/login")
    r = c.getresponse(); r.read(); c.close()
    if r.status == 200:
        print("  [PASS] nginx restarted -> login page 200")
    else:
        print("  [FAIL] nginx restart: %d" % r.status); fails += 1

    print("RESTART TEST RESULT: %s" % ("PASS" if fails == 0 else "FAIL"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
