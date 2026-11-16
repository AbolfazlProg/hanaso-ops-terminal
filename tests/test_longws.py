#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Long-lived websocket session test: keeps the terminal WS open for N
seconds (handling server pings), runs a long command mid-way and asserts
the output arrives over the SAME connection."""
import base64
import json
import os
import socket
import ssl
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)) + "/../scripts")
import importlib.util
spec = importlib.util.spec_from_file_location(
    "e2e_test", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "..", "scripts", "e2e-test.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

BASE = os.environ.get("OPS_TEST_BASE", "https://ops.hanaso.ir:8443")
IP = os.environ.get("OPS_TEST_IP", "127.0.0.1")
PW = os.environ["OPS_TEST_PW"]
USER = os.environ.get("OPS_TEST_USER", "ops-admin")
HOLD_SECONDS = int(os.environ.get("OPS_HOLD_SECONDS", "62"))


def main():
    import re
    import http.client

    class Conn(http.client.HTTPSConnection):
        def __init__(self, host, port, ip, timeout=10):
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            super().__init__(host, port, context=ctx, timeout=timeout)
            self._ip = ip

        def connect(self):
            raw = socket.create_connection((self._ip, self.port), timeout=self.timeout)
            self.sock = self._context.wrap_socket(raw, server_hostname=self.host)

    m = re.match(r"https://([^/:]+)(?::(\d+))?", BASE)
    host, port = m.group(1), int(m.group(2) or 443)

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
    if r.status != 302:
        print("[FAIL] login status %d" % r.status)
        return 1

    origin = "https://%s%s" % (host, (":%d" % port) if port not in (80, 443) else "")
    ws = mod.WSClient(host, port, IP, "/ws", True, jar, origin, timeout=15)
    ws.handshake(101)
    ws.send_init("")
    ws.wait_for(lambda out: "$" in out or "#" in out or "~" in out, 10)

    marker = "LONGWS%s" % os.urandom(3).hex()
    t0 = time.time()
    ws.send_input("sleep %d; echo %s\n" % (HOLD_SECONDS - 10, marker))
    frames = 0
    pings = 0
    saw_marker = False
    print("holding websocket open for %d seconds..." % HOLD_SECONDS)
    while time.time() - t0 < HOLD_SECONDS:
        try:
            ws.sock.settimeout(2)
            op, data = ws.recv_frame()
            frames += 1
            if op == 0x9:
                pings += 1
                ws.send_frame(0xA, data)
            else:
                ws._consume(op, data)
                if marker in ws.output:
                    saw_marker = True
        except (socket.timeout, TimeoutError):
            pass
    print("  frames received : %d" % frames)
    print("  ws pings handled: %d" % pings)
    print("  marker seen     : %s" % saw_marker)
    ws.close()
    okflag = saw_marker and frames > 0
    print("LONGWS RESULT: %s" % ("PASS" if okflag else "FAIL"))
    return 0 if okflag else 1


if __name__ == "__main__":
    sys.exit(main())
